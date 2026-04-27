import Foundation

// Mirrors android-app/.../orchestration/TraceRecorder.kt — append-only JSONL
// span recorder for debugging the orchestration loop. Each `phase()` call
// emits a {kind, name, durationMs, ok, error?} line to a per-run file under
// Documents/claw-traces/<runId>.jsonl.

public actor TraceRecorder {
    public let runId: String
    public let enabled: Bool
    private let url: URL?
    /// In-memory event log. Always populated when `enabled`, regardless of
    /// whether on-disk writes succeed — lets tests assert telemetry without
    /// touching the filesystem.
    private var inMemory: [[String: Any]] = []

    public init(runId: String = UUID().uuidString, enabled: Bool = true) {
        self.runId = runId
        self.enabled = enabled
        guard enabled else {
            self.url = nil
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let dir = docs?.appendingPathComponent("claw-traces", isDirectory: true)
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        self.url = dir?.appendingPathComponent("\(runId).jsonl")
    }

    public func phase<T>(kind: String, name: String, _ block: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await block() }
        let start = DispatchTime.now()
        do {
            let value = try await block()
            emit(kind: kind, name: name, start: start, ok: true, error: nil)
            return value
        } catch {
            emit(kind: kind, name: name, start: start, ok: false, error: "\(error)")
            throw error
        }
    }

    public func event(kind: String, name: String, payload: [String: String] = [:]) async {
        guard enabled else { return }
        var record: [String: Any] = [
            "ts": Date().timeIntervalSince1970, "kind": kind, "name": name,
        ]
        for (k, v) in payload { record[k] = v }
        write(record)
    }

    /// Snapshot of recorded entries. Used by tests; ordering matches emission.
    public func recordedEvents() -> [[String: Any]] { inMemory }

    private func emit(kind: String, name: String, start: DispatchTime, ok: Bool, error: String?) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        var record: [String: Any] = [
            "ts": Date().timeIntervalSince1970, "kind": kind, "name": name,
            "duration_ms": elapsed, "ok": ok,
        ]
        if let error { record["error"] = error }
        write(record)
    }

    private func write(_ record: [String: Any]) {
        inMemory.append(record)
        guard let url else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8) else { return }
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: payload)
                try? handle.close()
            }
        } else {
            try? payload.write(to: url)
        }
    }
}
