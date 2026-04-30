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

    // MARK: - Health-summarize chain (health-summarize-001 regression)

    func testInferSkillsForHealthSummarize() {
        // "summarize my activity" → read-health then summarize so the
        // synthesis step has data to operate on. Without the chain the
        // regex-fallback would emit just `read-health` and the formatter
        // would produce "(no result)" because the planner can't synthesize
        // from raw HealthKit JSON without an LLM-only step.
        XCTAssertEqual(
            Planner.inferSkillsFromGoal("Summarize my activity from the last 7 days."),
            ["read-health", "summarize"])
        XCTAssertEqual(
            Planner.inferSkillsFromGoal("Give me a summary of my workouts this week"),
            ["read-health", "summarize"])
    }

    func testInferSkillsForHealthQueryWithoutSummarizeStaysSingleStep() {
        // No summary keyword → single read-health step is fine; the
        // formatter already handles a single read-health output.
        XCTAssertEqual(
            Planner.inferSkillsFromGoal("How many steps have I taken today?"),
            ["read-health"])
        XCTAssertEqual(
            Planner.inferSkillsFromGoal("What is my latest heart rate reading?"),
            ["read-health"])
    }

    func testInferredStepsChainHealthSummarize() {
        let steps = Planner.inferredSteps(
            goal: "Summarize my activity from the last 7 days.")
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].skillName, "read-health")
        XCTAssertEqual(steps[0].toolArgs["windowDays"], "7")
        XCTAssertEqual(steps[1].skillName, "summarize")
        XCTAssertEqual(steps[1].dependsOn, ["s1"])
        // Synthesis step references the upstream output via the
        // `Output from s1` placeholder so StepArgRescue can substitute.
        XCTAssertEqual(steps[1].toolArgs["text"], "Output from s1")
        XCTAssertNotNil(steps[1].toolArgs["instruction"])
    }

    func testRegexFallbackUsesGoalHeuristicWhenNoKeysFound() {
        // Raw output has a goal-shaped substring but is not valid JSON
        // and has no skill-shaped key — heuristic kicks in. The QR rule
        // emits scan-barcode alone (its built-in scanRecentLibrary
        // walks 30 recent photos, more reliable than chaining off
        // search-photos's 10-photo fallback).
        let raw = #"""
        thinking out loud: "goal":"Find the QR code photo and scan it" but I'm not sure how
        """#
        let r = planner.parsePlanWithStatus(raw, defaultGoal: "x")
        XCTAssertEqual(r.repairTier, "regex-fallback")
        XCTAssertEqual(r.plan.steps.map { $0.skillName }, ["scan-barcode"])
    }

    // MARK: - dependsOn normalization (composite-directions-share-001 regression)

    func testCanonicalStepIdCollapsesVariants() {
        // All of these reference "step 1" in the LLM's head.
        XCTAssertEqual(Planner.canonicalStepId("s1"), "1")
        XCTAssertEqual(Planner.canonicalStepId("s_1"), "1")
        XCTAssertEqual(Planner.canonicalStepId("step_1"), "1")
        XCTAssertEqual(Planner.canonicalStepId("step1"), "1")
        XCTAssertEqual(Planner.canonicalStepId("Step 1"), "1")
        XCTAssertEqual(Planner.canonicalStepId("STEP_01"), "01")
        // Non-numeric ids reduce to alphanumeric form (no special "s"
        // stripping when the rest isn't numeric — would corrupt e.g.
        // "search" into "earch").
        XCTAssertEqual(Planner.canonicalStepId("search-step"), "searchstep")
    }

    func testParsePlanRewritesDependsOnToMatchStepIds() {
        // Planner emitted `dependsOn:["step_1"]` while step ids are "s1"
        // — without normalization the executor's strict priorResults
        // lookup would skip s2 with `dependency unmet`. After the fix,
        // dependsOn must be rewritten to ["s1"].
        let json = #"""
        {
          "goal": "use s1 then s2",
          "reasoning": "test",
          "steps": [
            {"id": "s1", "description": "first", "skillName": "search-web", "toolArgs": {"query": "x"}, "dependsOn": []},
            {"id": "s2", "description": "second", "skillName": "compose", "toolArgs": {"text": "Output from step_1"}, "dependsOn": ["step_1"]}
          ]
        }
        """#
        let r = planner.parsePlanWithStatus(json, defaultGoal: "x")
        XCTAssertEqual(r.plan.steps.count, 2)
        XCTAssertEqual(r.plan.steps[1].dependsOn, ["s1"],
                       "dependsOn must be normalized to match the step's id field")
    }

    func testParsePlanDropsDependsOnReferencesThatHaveNoStepMatch() {
        // LLM hallucinates `dependsOn:["s99"]` referencing a step that
        // doesn't exist. Drop the reference rather than skipping the
        // step forever — running it is a better failure mode than
        // permanent SKIPPED.
        let json = #"""
        {
          "goal": "x",
          "reasoning": "r",
          "steps": [
            {"id": "s1", "description": "first", "skillName": "calculator", "toolArgs": {}, "dependsOn": []},
            {"id": "s2", "description": "second", "skillName": "compose", "toolArgs": {}, "dependsOn": ["s99"]}
          ]
        }
        """#
        let r = planner.parsePlanWithStatus(json, defaultGoal: "x")
        XCTAssertEqual(r.plan.steps[1].dependsOn, [],
                       "Hallucinated dep references must be dropped")
    }

    func testNormalizeDependsOnPreservesAlreadyValidIds() {
        // No-op when dependsOn entries already match step ids verbatim.
        let steps = [
            PlanStep(id: "s1", description: "x", skillName: "calculator"),
            PlanStep(id: "s2", description: "y", skillName: "compose",
                     toolArgs: [:], dependsOn: ["s1"]),
        ]
        let normalized = Planner.normalizeDependsOn(steps)
        XCTAssertEqual(normalized[1].dependsOn, ["s1"])
    }

    func testNormalizeDependsOnHandlesMixedVariants() {
        // 4-step plan where each dep entry uses a different id shape —
        // the kind of mess the planner sometimes emits when iterating
        // its own output. All must collapse to the canonical "sN".
        let steps = [
            PlanStep(id: "s1", description: "a", skillName: "calc"),
            PlanStep(id: "s2", description: "b", skillName: "calc",
                     toolArgs: [:], dependsOn: ["step_1"]),
            PlanStep(id: "s3", description: "c", skillName: "calc",
                     toolArgs: [:], dependsOn: ["s_1", "Step 2"]),
            PlanStep(id: "s4", description: "d", skillName: "calc",
                     toolArgs: [:], dependsOn: ["step3"]),
        ]
        let normalized = Planner.normalizeDependsOn(steps)
        XCTAssertEqual(normalized[1].dependsOn, ["s1"])
        XCTAssertEqual(normalized[2].dependsOn, ["s1", "s2"])
        XCTAssertEqual(normalized[3].dependsOn, ["s3"])
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
