import XCTest
@testable import EdgeCat

/// `agentTracesKey` must gate trace persistence — when the user disables
/// traces in Settings the orchestrator should produce zero events. Mirrors
/// android-app's `claw-trace-enabled` flag-file behavior.
///
/// Schema details (envelope, field names) are exercised by
/// `TraceSchemaTests`; this file's focus is the enabled/disabled toggle
/// + the basic shape of recorded entries.
final class TraceRecorderEnabledTests: XCTestCase {

    /// Pull the `span` dict out of an envelope `{type:"span", run_id, span:{…}}`.
    private func span(_ entry: [String: Any]) -> [String: Any]? {
        entry["span"] as? [String: Any]
    }

    func testEnabledRecorderCapturesEvents() async {
        let rec = TraceRecorder(runId: "test-enabled-\(UUID().uuidString)", enabled: true)
        await rec.event(kind: "step.start", name: "s1", payload: ["skill": "calculator"])
        await rec.event(kind: "step.end", name: "s1", payload: ["ok": "1"])

        let events = await rec.recordedEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?["type"] as? String, "span")
        let firstSpan = span(events[0])
        XCTAssertEqual(firstSpan?["kind"] as? String, "step.start")
        XCTAssertEqual(firstSpan?["name"] as? String, "s1")
        let attrs = firstSpan?["attrs"] as? [String: Any]
        XCTAssertEqual(attrs?["skill"] as? String, "calculator")
    }

    func testDisabledRecorderDropsEvents() async {
        let rec = TraceRecorder(runId: "test-disabled-\(UUID().uuidString)", enabled: false)
        await rec.event(kind: "step.start", name: "s1")
        await rec.event(kind: "step.end", name: "s1", payload: ["ok": "1"])

        let events = await rec.recordedEvents()
        XCTAssertTrue(events.isEmpty, "Disabled recorder must produce no events")
    }

    func testDisabledPhaseStillRunsBlockButRecordsNothing() async throws {
        let rec = TraceRecorder(runId: "test-phase-\(UUID().uuidString)", enabled: false)
        var ran = false
        let value = try await rec.phase(kind: "phase", name: "plan") {
            ran = true
            return 42
        }
        XCTAssertTrue(ran, "Block must still execute when traces disabled")
        XCTAssertEqual(value, 42, "Block return value must propagate")
        let events = await rec.recordedEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testEnabledPhaseRecordsDurationAndOutcome() async throws {
        let rec = TraceRecorder(runId: "test-phase-on-\(UUID().uuidString)", enabled: true)
        _ = try await rec.phase(kind: "phase", name: "plan") {
            try? await Task.sleep(nanoseconds: 5_000_000)
            return "done"
        }
        let events = await rec.recordedEvents()
        XCTAssertEqual(events.count, 1)
        let s = span(events[0])
        XCTAssertEqual(s?["kind"] as? String, "phase")
        XCTAssertEqual(s?["name"] as? String, "plan")
        // Status is now a string ("ok"/"error"), not a Bool, for Android parity.
        XCTAssertEqual(s?["status"] as? String, "ok")
        XCTAssertNotNil(s?["duration_ms"])
    }

    func testEventsIncludeThermalAndMemoryAttrs() async {
        let rec = TraceRecorder(runId: "test-attrs-\(UUID().uuidString)", enabled: true)
        await rec.event(kind: "step.start", name: "s1")
        let events = await rec.recordedEvents()
        XCTAssertEqual(events.count, 1)
        let s = span(events[0])
        // Android-compat: int thermal code + int mem_pss_mb.
        let thermal = s?["thermal"] as? Int
        XCTAssertNotNil(thermal)
        XCTAssertTrue([-1, 0, 1, 2, 3].contains(thermal ?? -2),
                      "Unexpected thermal code: \(String(describing: thermal))")
        XCTAssertNotNil(s?["mem_pss_mb"] as? Int,
                        "Resident memory should be present (may be 0)")
    }

    func testPhaseAttrsRideAlongInRecord() async throws {
        let rec = TraceRecorder(runId: "test-phase-attrs-\(UUID().uuidString)", enabled: true)
        _ = try await rec.phase(kind: "phase", name: "plan",
                                 attrs: ["iteration": 0, "thinking": true]) {
            "ok"
        }
        let events = await rec.recordedEvents()
        XCTAssertEqual(events.count, 1)
        let attrs = span(events[0])?["attrs"] as? [String: Any]
        XCTAssertEqual(attrs?["iteration"] as? Int, 0)
        XCTAssertEqual(attrs?["thinking"] as? Bool, true)
    }

    func testDisabledRecorderWritesNoFile() async {
        let runId = "test-no-file-\(UUID().uuidString)"
        let rec = TraceRecorder(runId: runId, enabled: false)
        await rec.event(kind: "x", name: "y")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let url = docs?.appendingPathComponent("claw-traces", isDirectory: true)
            .appendingPathComponent("\(runId).jsonl")
        if let url {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "No trace file should be written when disabled")
        }
    }
}
