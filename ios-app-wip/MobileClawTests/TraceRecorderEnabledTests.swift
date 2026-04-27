import XCTest
@testable import MobileClaw

/// `agentTracesKey` must gate trace persistence — when the user disables
/// traces in Settings the orchestrator should produce zero events. Mirrors
/// android-app's `claw-trace-enabled` flag-file behavior.
final class TraceRecorderEnabledTests: XCTestCase {

    func testEnabledRecorderCapturesEvents() async {
        let rec = TraceRecorder(runId: "test-enabled-\(UUID().uuidString)", enabled: true)
        await rec.event(kind: "step.start", name: "s1", payload: ["skill": "calculator"])
        await rec.event(kind: "step.end", name: "s1", payload: ["ok": "1"])

        let events = await rec.recordedEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?["kind"] as? String, "step.start")
        XCTAssertEqual(events.first?["name"] as? String, "s1")
        XCTAssertEqual(events.first?["skill"] as? String, "calculator")
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
        XCTAssertEqual(events.first?["kind"] as? String, "phase")
        XCTAssertEqual(events.first?["name"] as? String, "plan")
        XCTAssertEqual(events.first?["ok"] as? Bool, true)
        XCTAssertNotNil(events.first?["duration_ms"])
    }

    func testEventsIncludeThermalAndMemoryAttrs() async {
        let rec = TraceRecorder(runId: "test-attrs-\(UUID().uuidString)", enabled: true)
        await rec.event(kind: "step.start", name: "s1")
        let events = await rec.recordedEvents()
        XCTAssertEqual(events.count, 1)
        let thermal = events[0]["thermal_state"] as? String
        XCTAssertNotNil(thermal)
        XCTAssertTrue(["nominal", "fair", "serious", "critical", "unknown"].contains(thermal ?? ""),
                      "Unexpected thermal label: \(thermal ?? "nil")")
        XCTAssertNotNil(events[0]["memory_mb"] as? Double,
                        "Resident memory should be present (may be 0.0)")
    }

    func testPhaseAttrsRideAlongInRecord() async throws {
        let rec = TraceRecorder(runId: "test-phase-attrs-\(UUID().uuidString)", enabled: true)
        _ = try await rec.phase(kind: "phase", name: "plan",
                                 attrs: ["iteration": 0, "thinking": true]) {
            "ok"
        }
        let events = await rec.recordedEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["iteration"] as? Int, 0)
        XCTAssertEqual(events[0]["thinking"] as? Bool, true)
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
