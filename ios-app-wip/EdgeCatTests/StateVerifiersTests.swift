import XCTest
@testable import EdgeCat

/// `StateVerifiers` queries iOS frameworks (EventKit, UNUserNotificationCenter,
/// Contacts, Photos, HealthKit). On the simulator without granted
/// permissions, most return "access denied" — that's a *successful*
/// verifier execution (the verifier ran and produced a deterministic
/// answer), even though `passed=false`. These tests focus on the
/// dispatch surface: kinds get routed, unknown kinds error out, the
/// verify-complete sentinel is always emitted.
final class StateVerifiersTests: XCTestCase {

    private func recordedEvents(runId: String) async -> [[String: Any]] {
        let rec = TraceRecorder(runId: runId, enabled: true)
        return await rec.recordedEvents()
    }

    func testUnknownKindEmitsFalseResult() async {
        let runId = "verify-test-unknown-\(UUID().uuidString)"
        await StateVerifiers.runAndEmit(runId: runId, kind: "no_such_kind", params: [:])
        // Verifier writes its own TraceRecorder instance — read the on-disk
        // trace file to assert the spans.
        let url = traceFileURL(runId: runId)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return XCTFail("no trace file at \(url.path)")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = text.split(separator: "\n").compactMap { line -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        // Two spans expected: name=no_such_kind (passed=false), and
        // name=complete sentinel.
        let verifySpans = lines.compactMap { $0["span"] as? [String: Any] }
            .filter { ($0["kind"] as? String) == "verify" }
        XCTAssertEqual(verifySpans.count, 2)
        let main = verifySpans.first { ($0["name"] as? String) == "no_such_kind" }
        XCTAssertNotNil(main, "expected a span for the unknown kind")
        let attrs = main?["attrs"] as? [String: Any] ?? [:]
        XCTAssertEqual(attrs["passed"] as? String, "false")
        XCTAssertTrue(((attrs["detail"] as? String) ?? "").contains("unknown verifier kind"))

        let sentinel = verifySpans.first { ($0["name"] as? String) == "complete" }
        XCTAssertNotNil(sentinel, "verify-complete sentinel must be emitted")
    }

    func testCalendarVerifierEmitsBoolAttr() async {
        // Whether or not calendar access is granted on the test target,
        // the verifier must emit a span with a `passed` bool attribute.
        let runId = "verify-test-cal-\(UUID().uuidString)"
        await StateVerifiers.runAndEmit(runId: runId,
                                         kind: "calendar_event_exists",
                                         params: ["title_contains": "ZZZ_unlikely_title_\(UUID().uuidString)",
                                                  "hour": "14",
                                                  "day_offset": "1"])
        let url = traceFileURL(runId: runId)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let text = try? String(contentsOf: url) else {
            return XCTFail("no trace at \(url.path)")
        }
        let spans = text.split(separator: "\n").compactMap { line -> [String: Any]? in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["span"] as? [String: Any]
        }
        let main = spans.first { ($0["name"] as? String) == "calendar_event_exists" }
        XCTAssertNotNil(main, "verifier must emit a span")
        let passed = (main?["attrs"] as? [String: Any])?["passed"] as? String
        XCTAssertTrue(passed == "true" || passed == "false",
                      "passed must be 'true' or 'false', got \(String(describing: passed))")
    }

    func testTimerPendingVerifierWithNoMatchEmitsFalse() async {
        let runId = "verify-test-timer-\(UUID().uuidString)"
        // Random unlikely interval — no real notification will match.
        await StateVerifiers.runAndEmit(runId: runId,
                                         kind: "timer_pending",
                                         params: ["interval_s": "987654321"])
        let url = traceFileURL(runId: runId)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let text = try? String(contentsOf: url) else {
            return XCTFail("no trace at \(url.path)")
        }
        let spans = text.split(separator: "\n").compactMap { line -> [String: Any]? in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["span"] as? [String: Any]
        }
        let main = spans.first { ($0["name"] as? String) == "timer_pending" }
        XCTAssertNotNil(main)
        let passed = (main?["attrs"] as? [String: Any])?["passed"] as? String
        XCTAssertEqual(passed, "false")
    }

    private func traceFileURL(runId: String) -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first else {
            fatalError("no documents directory in test target")
        }
        return docs.appendingPathComponent("claw-traces", isDirectory: true)
            .appendingPathComponent("\(runId).jsonl")
    }
}
