import XCTest
@testable import MobileClaw

/// One test per repair tier. Each fixture is malformed in a way that fails
/// strict JSONSerialization but is recoverable by the targeted tier.
/// Mirrors android-app/.../PlannerTest.kt's repair-tier cases.
final class PlannerJsonRepairTests: XCTestCase {

    private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
        func generateResponse(prompt: String, enableThinking: Bool) async throws -> String { "{}" }
        func cancel() {}
    }

    private var planner: Planner {
        Planner(llm: StubLLM(), policy: ThinkingPolicy(mode: .off))
    }

    func testValidJsonReportsNoneTier() {
        let raw = """
        {"goal":"hi","reasoning":"r","steps":[]}
        """
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "fallback")
        XCTAssertEqual(r.repairTier, "none")
        XCTAssertEqual(r.plan.goal, "hi")
    }

    func testTrailingCommaRecoversAtCommasTier() {
        // iOS Foundation JSONSerialization tolerates a single trailing
        // comma after `[]` — use a double-comma which it definitely rejects.
        let raw = """
        {"goal":"x",,"reasoning":"r","steps":[]}
        """
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "fallback")
        XCTAssertEqual(r.repairTier, "commas")
        XCTAssertEqual(r.plan.goal, "x")
    }

    func testDoubleCommaRecoversAtCommasTier() {
        let raw = """
        {"goal":"x",,"reasoning":"r","steps":[]}
        """
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "fallback")
        XCTAssertEqual(r.repairTier, "commas")
        XCTAssertEqual(r.plan.goal, "x")
    }

    func testSmartQuotesRecoverAtQuotesTier() {
        // Curly quotes from a thinking-mode rewrap.
        let raw = "{\u{201C}goal\u{201D}:\u{201C}smart\u{201D},\u{201C}reasoning\u{201D}:\u{201C}r\u{201D},\u{201C}steps\u{201D}:[]}"
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "fallback")
        XCTAssertEqual(r.repairTier, "quotes")
        XCTAssertEqual(r.plan.goal, "smart")
    }

    func testUnquotedKeysRecoverAtUnquotedKeysTier() {
        let raw = """
        {goal:"unq",reasoning:"r",steps:[]}
        """
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "fallback")
        XCTAssertEqual(r.repairTier, "unquoted-keys")
        XCTAssertEqual(r.plan.goal, "unq")
    }

    func testCommentLinesStrippedAtStripCommentsTier() {
        let raw = """
        {
        // this is the plan
        "goal":"with-comments",
        # another comment
        "reasoning":"r","steps":[]
        }
        """
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "fallback")
        XCTAssertEqual(r.repairTier, "strip-comments")
        XCTAssertEqual(r.plan.goal, "with-comments")
    }

    func testTruncatedOutputRecoversAtBalanceBracesTier() {
        // Model truncated mid-array — close brace + bracket missing.
        let raw = """
        {"goal":"trunc","reasoning":"r","steps":[
        """
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "fallback")
        XCTAssertEqual(r.repairTier, "balance-braces")
        XCTAssertEqual(r.plan.goal, "trunc")
    }

    func testStackedFailuresRecoverAtFullTier() {
        // Trailing commas + unquoted keys + curly quotes in one go.
        let raw = """
        {goal:\u{201C}stacked\u{201D},reasoning:\u{201C}r\u{201D},steps:[],}
        """
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "fallback")
        XCTAssertEqual(r.repairTier, "full")
        XCTAssertEqual(r.plan.goal, "stacked")
    }

    func testHopelesslyBrokenFallsThroughToRegexFallback() {
        // Garbage with a goal-shaped substring.
        let raw = """
        I think the plan should be... "goal":"regex-rescued" but I forgot the rest
        """
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "fallback")
        XCTAssertEqual(r.repairTier, "regex-fallback")
        XCTAssertEqual(r.plan.goal, "regex-rescued")
    }

    func testRegexFallbackReturnsDefaultGoalWhenAllFails() {
        let r = planner.parsePlanWithStatus("complete nonsense, no JSON",
                                            defaultGoal: "default-goal")
        XCTAssertEqual(r.repairTier, "regex-fallback")
        XCTAssertEqual(r.plan.goal, "default-goal")
        // No skill-shaped field at all → empty steps. The controller's
        // empty-plan path surfaces "(no result)" to the user, which is
        // safer than letting an LLM hallucinate a domain-specific answer.
        XCTAssertTrue(r.plan.steps.isEmpty)
    }

    func testRegexFallbackAcceptsAlternateSkillKeys() {
        // Models occasionally use `skill_name` or `skill` instead of
        // `skillName`. Accept all three so partial JSON failures still
        // yield actionable steps. Use input that's recoverable only by
        // regex (mismatched quote types so JSON tier fails entirely).
        let raw = #"""
        plan thoughts: "skill_name": "calculator" please use this for 2+2
        """#
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "x")
        XCTAssertEqual(r.repairTier, "regex-fallback")
        XCTAssertEqual(r.plan.steps.first?.skillName, "calculator")
    }

    // MARK: - Goal-keyword heuristic (regex-fallback rescue)

    func testInferSkillsForQrPhotoGoal() {
        // QR goals route to scan-barcode alone — its built-in
        // scanRecentLibrary walks 30 photos, more reliable than
        // chaining off search-photos's 10-photo fallback.
        XCTAssertEqual(
            Planner.inferSkillsFromGoal("Find the photo named test_qr_claude in my gallery and scan it for QR codes"),
            ["scan-barcode"])
    }

    func testInferSkillsForWeatherGoal() {
        XCTAssertEqual(
            Planner.inferSkillsFromGoal("What is the weather in Tokyo today?"),
            ["search-web", "fetch-web-content"])
    }

    func testInferSkillsForCalendarGoal() {
        XCTAssertEqual(
            Planner.inferSkillsFromGoal("Add a calendar event for tomorrow at 3pm called Team Meeting"),
            ["calendar"])
    }

    func testInferSkillsReturnsEmptyForUnknownGoal() {
        XCTAssertTrue(
            Planner.inferSkillsFromGoal("frobnicate the widget mainly").isEmpty)
    }

    func testInferredStepsForQrUseSingleScanBarcode() {
        // QR rule emits scan-barcode alone with the name hint as
        // photo_id. BarcodeSkill recognizes the non-asset-id shape
        // and walks 30 recent photos via scanRecentLibrary.
        let steps = Planner.inferredSteps(
            goal: "Find the photo named test_qr_claude in my gallery and scan it for QR codes")
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].skillName, "scan-barcode")
        XCTAssertEqual(steps[0].toolArgs["photo_id"], "test_qr_claude")
    }

    func testInferredStepsChainWebSequentially() {
        let steps = Planner.inferredSteps(goal: "What is the weather in Tokyo today?")
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].skillName, "search-web")
        XCTAssertEqual(steps[1].skillName, "fetch-web-content")
        XCTAssertEqual(steps[1].dependsOn, ["s1"])
        XCTAssertEqual(steps[1].toolArgs["url"], "Output from s1")
    }

    func testRegexFallbackUsesGoalHeuristicWhenNoKeysFound() {
        // Raw output has a goal-shaped substring but is not valid JSON
        // and has no skill-shaped key — heuristic kicks in and emits
        // search-photos + scan-barcode for the QR task.
        let raw = #"""
        thinking out loud: "goal":"Find the QR code photo and scan it" but I'm not sure how
        """#
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "x")
        XCTAssertEqual(r.repairTier, "regex-fallback")
        XCTAssertEqual(r.plan.steps.map { $0.skillName }, ["search-photos", "scan-barcode"])
    }

    // MARK: - Repair tier unit checks (raw transformation)

    func testRepairCommasDropsTrailingCommas() {
        XCTAssertEqual(Planner.repairCommas("[1,2,]"), "[1,2]")
        XCTAssertEqual(Planner.repairCommas("{\"a\":1,}"), "{\"a\":1}")
    }

    func testRepairCommasCollapsesDoubleCommas() {
        XCTAssertEqual(Planner.repairCommas("[1,,2]"), "[1,2]")
    }

    func testRepairUnquotedKeysQuotesIdentifiers() {
        XCTAssertEqual(
            Planner.repairUnquotedKeys("{goal:\"x\",steps:[]}"),
            "{\"goal\":\"x\",\"steps\":[]}")
    }

    func testRepairBalanceBracesAppendsMissing() {
        XCTAssertEqual(Planner.repairBalanceBraces("{\"a\":1"), "{\"a\":1}")
        XCTAssertEqual(Planner.repairBalanceBraces("{\"a\":[1,2"), "{\"a\":[1,2]}")
    }

    func testRepairBalanceBracesReturnsUntouchedWhenBalanced() {
        let s = "{\"a\":1}"
        XCTAssertEqual(Planner.repairBalanceBraces(s), s)
    }
}
