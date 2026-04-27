import XCTest
@testable import MobileClaw

final class SelfEvaluatorTriageTests: XCTestCase {

    private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
        var called = false
        func generateResponse(prompt: String, enableThinking: Bool) async throws -> String {
            called = true
            return #"{"goalAchieved":false,"assessment":"llm-said-no","shouldReplan":true}"#
        }
        func cancel() {}
    }

    private func plan(goal: String,
                      steps: [PlanStep],
                      criteria: [String] = []) -> ExecutionPlan {
        ExecutionPlan(goal: goal, reasoning: "r", steps: steps, successCriteria: criteria)
    }

    func testHappyPathTriagesToGoalAchievedWithoutLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "calculate total cost",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "calculator")],
                     criteria: ["total cost computed"])
        let results = ["s1": StepResult(stepId: "s1", status: .completed,
                                        output: "the total cost is $42.50")]
        let result = try await evaluator.evaluate(
            userMessage: "what's the total cost", plan: p, results: results)
        XCTAssertTrue(result.goalAchieved)
        XCTAssertEqual(result.assessment, "triage-shortcut")
        XCTAssertFalse(llm.called, "Triage hit must not call the LLM evaluator")
    }

    func testFailedStepFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "fetch wikipedia",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "fetch")])
        let results = ["s1": StepResult(stepId: "s1", status: .failed,
                                        output: "", error: "network down")]
        _ = try await evaluator.evaluate(
            userMessage: "wiki this", plan: p, results: results)
        XCTAssertTrue(llm.called, "Failed step should not be triaged")
    }

    func testEmptyOutputFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "calculate something",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "calculator")])
        let results = ["s1": StepResult(stepId: "s1", status: .completed, output: "")]
        _ = try await evaluator.evaluate(
            userMessage: "x", plan: p, results: results)
        XCTAssertTrue(llm.called, "Empty output should not be triaged")
    }

    func testErrorMarkerInOutputFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "create event",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "calendar")])
        let results = ["s1": StepResult(stepId: "s1", status: .completed,
                                        output: "Error: permission denied")]
        _ = try await evaluator.evaluate(
            userMessage: "x", plan: p, results: results)
        XCTAssertTrue(llm.called, "Output containing 'error' must not be triaged")
    }

    func testGoalTokenAbsentFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "find restaurant near me",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "search")])
        // Output has nothing matching "restaurant"/"near"/"find" tokens.
        let results = ["s1": StepResult(stepId: "s1", status: .completed,
                                        output: "weather is 72 degrees")]
        _ = try await evaluator.evaluate(
            userMessage: "x", plan: p, results: results)
        XCTAssertTrue(llm.called,
                      "Output that doesn't intersect goal tokens must not be triaged")
    }

    func testEmptyPlanFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "x", steps: [])
        _ = try await evaluator.evaluate(
            userMessage: "x", plan: p, results: [:])
        XCTAssertTrue(llm.called, "Empty plan should not triage to success")
    }
}
