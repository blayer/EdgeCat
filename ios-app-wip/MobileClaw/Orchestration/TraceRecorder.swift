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

    public func phase<T>(kind: String, name: String,
                          attrs: [String: Any] = [:],
                          _ block: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await block() }
        let start = DispatchTime.now()
        do {
            let value = try await block()
            emit(kind: kind, name: name, start: start, ok: true, error: nil, attrs: attrs)
            return value
        } catch {
            emit(kind: kind, name: name, start: start, ok: false, error: "\(error)", attrs: attrs)
            throw error
        }
    }

    public func event(kind: String, name: String, payload: [String: String] = [:]) async {
        guard enabled else { return }
        var record: [String: Any] = baseRecord(kind: kind, name: name)
        for (k, v) in payload { record[k] = v }
        write(record)
    }

    /// Snapshot of recorded entries. Used by tests; ordering matches emission.
    public func recordedEvents() -> [[String: Any]] { inMemory }

    private func emit(kind: String, name: String, start: DispatchTime,
                      ok: Bool, error: String?, attrs: [String: Any]) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        var record: [String: Any] = baseRecord(kind: kind, name: name)
        record["duration_ms"] = elapsed
        record["ok"] = ok
        if let error { record["error"] = error }
        for (k, v) in attrs { record[k] = v }
        write(record)
    }

    /// Common columns: ts, kind, name + system telemetry (thermal, memory)
    /// that we want on every entry for postmortems. Mirrors Android's
    /// per-span thermal_state + memory footprint capture.
    private func baseRecord(kind: String, name: String) -> [String: Any] {
        [
            "ts": Date().timeIntervalSince1970,
            "kind": kind,
            "name": name,
            "thermal_state": Self.thermalLabel(),
            "memory_mb": Self.residentMemoryMB(),
        ]
    }

    private static func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Best-effort resident memory. Returns 0.0 if mach_task_basic_info
    /// fails — we never want telemetry to block trace writes.
    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size /
                                            MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          reboundPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576.0
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
