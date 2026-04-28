import Foundation

// Mirrors android-app/.../orchestration/TraceRecorder.kt — append-only JSONL
// span recorder for the orchestration loop. Each `phase()` call emits one
// `{type:"span", run_id, span:{kind, name, start_ms, end_ms, duration_ms,
// status, thermal, mem_pss_mb, attrs}}` line to
// `Documents/claw-traces/<runId>.jsonl`.
//
// Schema parity with Android is non-negotiable — the off-device scorers
// in `test/eval/scorers/` parse trace JSONL field-by-field. Field rename
// table (vs. the pre-eval-harness iOS shape):
//   ok: Bool                  → status: "ok"|"error"
//   memory_mb: Double         → mem_pss_mb: Int
//   thermal_state: String     → thermal: Int (0..3, -1 = unknown)
//   ts: Double (epoch sec)    → start_ms: Int64, end_ms: Int64

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

    public func phase<T>(kind: String,
                         name: String,
                         attrs: [String: Any] = [:],
                         _ block: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await block() }
        let startMs = Self.nowMs()
        let startTime = DispatchTime.now()
        do {
            let value = try await block()
            emitSpan(kind: kind, name: name, startMs: startMs, startTime: startTime,
                     outcome: .ok, attrs: attrs)
            return value
        } catch {
            emitSpan(kind: kind, name: name, startMs: startMs, startTime: startTime,
                     outcome: .error("\(error)"), attrs: attrs)
            throw error
        }
    }

    private enum Outcome {
        case ok
        case error(String)
    }

    /// Zero-duration "event" — emitted as a span with start_ms == end_ms so
    /// scorers don't need a separate code path. Payload values become
    /// span attrs.
    public func event(kind: String, name: String, payload: [String: String] = [:]) async {
        guard enabled else { return }
        let now = Self.nowMs()
        var attrs: [String: Any] = [:]
        for (key, value) in payload { attrs[key] = value }
        let span = buildSpan(kind: kind, name: name, startMs: now, endMs: now,
                             durationMs: 0.0, outcome: .ok, attrs: attrs)
        write(envelope(span: span))
    }

    /// Snapshot of recorded entries. Used by tests; ordering matches emission.
    public func recordedEvents() -> [[String: Any]] { inMemory }

    /// Append a `{"type":"run","run":{…}}` line at the end of an eval. The
    /// off-device file-stability poller treats any JSON line as "still
    /// writing"; the run-summary line + a trailing `eval-complete` event
    /// (emitted by `EvalEntryPoint`) signal end-of-write.
    public func flushRunSummary(_ summary: [String: Any]) {
        guard enabled else { return }
        write(["type": "run", "run": summary])
    }

    // MARK: - Span emission

    // swiftlint:disable:next function_parameter_count
    private func emitSpan(kind: String,
                          name: String,
                          startMs: Int64,
                          startTime: DispatchTime,
                          outcome: Outcome,
                          attrs: [String: Any]) {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
        let endMs = startMs + Int64(elapsedMs.rounded())
        let span = buildSpan(kind: kind, name: name, startMs: startMs, endMs: endMs,
                             durationMs: elapsedMs, outcome: outcome, attrs: attrs)
        write(envelope(span: span))
    }

    // swiftlint:disable:next function_parameter_count
    private func buildSpan(kind: String,
                           name: String,
                           startMs: Int64,
                           endMs: Int64,
                           durationMs: Double,
                           outcome: Outcome,
                           attrs: [String: Any]) -> [String: Any] {
        var span: [String: Any] = [
            "kind": kind,
            "name": name,
            "start_ms": startMs,
            "end_ms": endMs,
            "duration_ms": durationMs,
            "thermal": Self.thermalCode(),
            "mem_pss_mb": Self.residentMemoryMB(),
        ]
        switch outcome {
        case .ok:
            span["status"] = "ok"
        case .error(let message):
            span["status"] = "error"
            span["error"] = message
        }
        if !attrs.isEmpty { span["attrs"] = attrs }
        return span
    }

    private func envelope(span: [String: Any]) -> [String: Any] {
        ["type": "span", "run_id": runId, "span": span]
    }

    // MARK: - System telemetry

    /// 0=nominal, 1=fair, 2=serious, 3=critical, -1=unknown. Matches
    /// Android's int representation so scorers can compare directly.
    private static func thermalCode() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return -1
        }
    }

    /// Best-effort resident memory in MiB. Returns 0 if mach_task_basic_info
    /// fails — we never want telemetry to block trace writes. Cast to Int
    /// to match Android's reported integer MB.
    private static func residentMemoryMB() -> Int {
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
        return Int(Double(info.resident_size) / 1_048_576.0)
    }

    /// Wall-clock milliseconds since the unix epoch. Single source of
    /// truth for `start_ms`/`end_ms` so the off-device scorer can compute
    /// per-kind latencies by sorting on these.
    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Persistence

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
