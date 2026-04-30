import XCTest
@testable import EdgeCat

private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
    var response: String
    init(_ response: String) { self.response = response }
    func generateResponse(prompt: String, enableThinking: Bool) async throws -> String { response }
    func cancel() {}
}

final class SelfEvaluatorTests: XCTestCase {

    func testParsesGoalAchievedTrue() async throws {
        let llm = StubLLM(#"""
        {"goalAchieved": true, "assessment": "all good",
         "missingItems": [], "shouldReplan": false, "failedCriteria": []}
        """#)
        let eval = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let plan = ExecutionPlan(goal: "x", reasoning: "", steps: [])
        let result = try await eval.evaluate(userMessage: "?", plan: plan, results: [:])
        XCTAssertTrue(result.goalAchieved)
        XCTAssertFalse(result.shouldReplan)
        XCTAssertEqual(result.assessment, "all good")
    }

    func testParsesShouldReplanWithMissingItems() async throws {
        let llm = StubLLM(#"""
        Some prose first.
        {"goalAchieved": false, "assessment": "incomplete",
         "missingItems": ["weather"], "shouldReplan": true,
         "failedCriteria": ["must include weather"]}
        Trailing text.
        """#)
        let eval = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let result = try await eval.evaluate(userMessage: "?",
                                              plan: ExecutionPlan(goal: "x", reasoning: "", steps: []),
                                              results: [:])
        XCTAssertFalse(result.goalAchieved)
        XCTAssertTrue(result.shouldReplan)
        XCTAssertEqual(result.missingItems, ["weather"])
        XCTAssertEqual(result.failedCriteria, ["must include weather"])
    }

    func testGarbageRespondsAssumesGoalAchieved() async throws {
        let llm = StubLLM("the response is garbage")
        let eval = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let result = try await eval.evaluate(userMessage: "?",
                                              plan: ExecutionPlan(goal: "x", reasoning: "", steps: []),
                                              results: [:])
        // Default to optimistic when unparseable so the loop terminates.
        XCTAssertTrue(result.goalAchieved)
        XCTAssertFalse(result.shouldReplan)
    }
}

final class ResponseFormatterTests: XCTestCase {

    func testMultiStepGoesThroughLlmSynthesis() async throws {
        let llm = StubLLM("LLM-formatted answer")
        let fmt = ResponseFormatter(llm: llm, policy: ThinkingPolicy(mode: .off))
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "x", skillName: "a"),
            PlanStep(id: "s2", description: "y", skillName: "b"),
        ])
        let results: [String: StepResult] = [
            "s1": StepResult(stepId: "s1", status: .completed, output: "first"),
            "s2": StepResult(stepId: "s2", status: .completed, output: "second"),
        ]
        // Phase 4 formatter: multi-step plans always go through LLM
        // synthesis so the answer reads as one coherent message rather
        // than the last skill's raw output. Mirrors Android.
        let r = try await fmt.format(userMessage: "u", plan: plan, results: results)
        XCTAssertEqual(r.text, "LLM-formatted answer")
        XCTAssertFalse(r.isHtml)
    }

    func testFailedAndSkippedStepsStillTriggerLlmSynthesis() async throws {
        let llm = StubLLM("LLM-formatted answer")
        let fmt = ResponseFormatter(llm: llm, policy: ThinkingPolicy(mode: .off))
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "x", skillName: "a"),
            PlanStep(id: "s2", description: "y", skillName: "b"),
        ])
        let results: [String: StepResult] = [
            "s1": StepResult(stepId: "s1", status: .failed, output: "partial-1"),
            "s2": StepResult(stepId: "s2", status: .skipped, output: "partial-2"),
        ]
        let r = try await fmt.format(userMessage: "u", plan: plan, results: results)
        XCTAssertEqual(r.text, "LLM-formatted answer",
                       "When no successful step output, formatter still asks LLM to synthesize a user-facing message")
    }

    func testEmptySuccessfulOutputFallsBackToLLMSynthesis() async throws {
        let llm = StubLLM("synthesized response")
        let fmt = ResponseFormatter(llm: llm, policy: ThinkingPolicy(mode: .off))
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "x", skillName: "a"),
        ])
        let results: [String: StepResult] = [
            "s1": StepResult(stepId: "s1", status: .completed, output: ""),
        ]
        let r = try await fmt.format(userMessage: "u", plan: plan, results: results)
        XCTAssertEqual(r.text, "synthesized response")
    }
}
