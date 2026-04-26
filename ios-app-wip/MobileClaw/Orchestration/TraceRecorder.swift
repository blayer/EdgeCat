import Foundation

// Mirrors android-app/.../orchestration/TraceRecorder.kt — append-only JSONL
// span recorder for debugging the orchestration loop. Each `phase()` call
// emits a {kind, name, durationMs, ok, error?} line to a per-run file under
// Documents/claw-traces/<runId>.jsonl.

public actor TraceRecorder {
    public let runId: String
    private let url: URL?

    public init(runId: String = UUID().uuidString) {
        self.runId = runId
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let dir = docs?.appendingPathComponent("claw-traces", isDirectory: true)
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        self.url = dir?.appendingPathComponent("\(runId).jsonl")
    }

    public func phase<T>(kind: String, name: String, _ block: () async throws -> T) async rethrows -> T {
        let start = DispatchTime.now()
        do {
            let value = try await block()
            await emit(kind: kind, name: name, start: start, ok: true, error: nil)
            return value
        } catch {
            await emit(kind: kind, name: name, start: start, ok: false, error: "\(error)")
            throw error
        }
    }

    public func event(kind: String, name: String, payload: [String: String] = [:]) async {
        var record: [String: Any] = [
            "ts": Date().timeIntervalSince1970, "kind": kind, "name": name,
        ]
        for (k, v) in payload { record[k] = v }
        await write(record)
    }

    private func emit(kind: String, name: String, start: DispatchTime, ok: Bool, error: String?) async {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        var record: [String: Any] = [
            "ts": Date().timeIntervalSince1970, "kind": kind, "name": name,
            "duration_ms": elapsed, "ok": ok,
        ]
        if let error { record["error"] = error }
        await write(record)
    }

    private func write(_ record: [String: Any]) async {
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
