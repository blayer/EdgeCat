import XCTest
@testable import MobileClaw

/// Trace JSONL schema parity with android-app's `TraceRecorder` —
/// non-negotiable because the off-device scorers in `test/eval/scorers/`
/// parse this format field-by-field. If any of these tests break, the
/// Android scorers silently produce zeros on iOS traces.
final class TraceSchemaTests: XCTestCase {

    // MARK: - Span envelope

    func testEventEmittedAsSpanEnvelope() async {
        let recorder = TraceRecorder(runId: "schema-event-\(UUID().uuidString)")
        await recorder.event(kind: "step", name: "calc", payload: ["expression": "2+2"])
        let events = await recorder.recordedEvents()

        XCTAssertEqual(events.count, 1)
        let entry = events[0]
        XCTAssertEqual(entry["type"] as? String, "span")
        XCTAssertNotNil(entry["run_id"] as? String)
        let span = entry["span"] as? [String: Any]
        XCTAssertNotNil(span)
        XCTAssertEqual(span?["kind"] as? String, "step")
        XCTAssertEqual(span?["name"] as? String, "calc")
    }

    func testPhaseEmittedAsSpanEnvelope() async throws {
        let recorder = TraceRecorder(runId: "schema-phase-\(UUID().uuidString)")
        _ = try await recorder.phase(kind: "phase", name: "plan") {
            try? await Task.sleep(nanoseconds: 5_000_000)
            return 42
        }
        let events = await recorder.recordedEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"] as? String, "span")
        XCTAssertEqual((events[0]["span"] as? [String: Any])?["kind"] as? String, "phase")
    }

    // MARK: - Span field shape

    func testSpanHasAndroidCompatibleFieldNames() async throws {
        let recorder = TraceRecorder(runId: "schema-fields-\(UUID().uuidString)")
        _ = try await recorder.phase(kind: "step", name: "calc") {
            "ok"
        }
        let span = await recorder.recordedEvents()[0]["span"] as? [String: Any]
        XCTAssertNotNil(span?["start_ms"] as? Int64,
                        "Android scorers expect Int64 start_ms")
        XCTAssertNotNil(span?["end_ms"] as? Int64,
                        "Android scorers expect Int64 end_ms")
        XCTAssertNotNil(span?["duration_ms"] as? Double)
        XCTAssertEqual(span?["status"] as? String, "ok",
                        "Android uses status: 'ok'/'error', not bool ok")
        XCTAssertNotNil(span?["thermal"] as? Int,
                        "Android uses int thermal (0..3), not string")
        XCTAssertNotNil(span?["mem_pss_mb"] as? Int,
                        "Android uses int mem_pss_mb")
    }

    func testStartMsLessThanOrEqualEndMs() async throws {
        let recorder = TraceRecorder(runId: "schema-time-\(UUID().uuidString)")
        _ = try await recorder.phase(kind: "phase", name: "plan") {
            try? await Task.sleep(nanoseconds: 10_000_000)
            return ()
        }
        let span = await recorder.recordedEvents()[0]["span"] as? [String: Any]
        let startMs = span?["start_ms"] as? Int64 ?? 0
        let endMs = span?["end_ms"] as? Int64 ?? 0
        XCTAssertLessThanOrEqual(startMs, endMs)
    }

    func testFailedPhaseEmitsStatusError() async {
        let recorder = TraceRecorder(runId: "schema-err-\(UUID().uuidString)")
        do {
            _ = try await recorder.phase(kind: "phase", name: "plan") {
                throw NSError(domain: "test", code: 7)
            }
            XCTFail("phase should have rethrown")
        } catch { /* expected */ }
        let span = await recorder.recordedEvents()[0]["span"] as? [String: Any]
        XCTAssertEqual(span?["status"] as? String, "error")
        XCTAssertNotNil(span?["error"])
    }

    func testThermalCodesMatchAndroid() async {
        // Android codes: 0=NONE/nominal, 1=LIGHT/fair, 2=MODERATE/serious,
        // 3=SEVERE/critical. iOS thermalCode() must return one of these
        // ints (or -1 for unknown), never a string.
        let recorder = TraceRecorder(runId: "schema-thermal-\(UUID().uuidString)")
        await recorder.event(kind: "step", name: "x")
        let span = await recorder.recordedEvents()[0]["span"] as? [String: Any]
        let thermal = span?["thermal"] as? Int ?? -2
        XCTAssertTrue([-1, 0, 1, 2, 3].contains(thermal),
                      "thermal must be -1/0/1/2/3, got \(thermal)")
    }

    // MARK: - Run summary line

    func testFlushRunSummaryEmitsRunEnvelope() async {
        let recorder = TraceRecorder(runId: "schema-runsummary-\(UUID().uuidString)")
        let summary: [String: Any] = [
            "run_id": "test-1",
            "schema_version": 1,
            "user_message": "hi",
            "final_status": "ok",
            "final_output": "hello",
            "iteration": 0,
            "start_ms": 100 as Int64,
            "end_ms": 200 as Int64,
            "duration_ms": 100,
            "extras": ["model_name": "test", "memory_isolated": true],
            "device": ["manufacturer": "Apple"],
        ]
        await recorder.flushRunSummary(summary)
        let events = await recorder.recordedEvents()
        let runLine = events.first { ($0["type"] as? String) == "run" }
        XCTAssertNotNil(runLine, "Should emit a {type:'run', ...} line")
        let run = runLine?["run"] as? [String: Any]
        XCTAssertEqual(run?["run_id"] as? String, "test-1")
        XCTAssertEqual(run?["final_status"] as? String, "ok")
    }

    // MARK: - JSONL serializability

    func testEntriesSerializeToValidJson() async throws {
        let recorder = TraceRecorder(runId: "schema-json-\(UUID().uuidString)")
        await recorder.event(kind: "step", name: "x", payload: ["k": "v"])
        _ = try await recorder.phase(kind: "phase", name: "plan",
                                      attrs: ["prompt_chars": 100, "response_chars": 50]) { () }
        for entry in await recorder.recordedEvents() {
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: entry))
        }
    }
}
