import XCTest
@testable import MobileClaw

private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
    let response: String
    private(set) var lastPrompt: String = ""
    private(set) var lastEnableThinking: Bool = false
    init(response: String) { self.response = response }
    func generateResponse(prompt: String, enableThinking: Bool) async throws -> String {
        lastPrompt = prompt
        lastEnableThinking = enableThinking
        return response
    }
    func cancel() {}
}

final class PlannerTests: XCTestCase {

    func testParsesValidJsonPlan() async throws {
        let json = #"""
        {
          "goal": "find weather",
          "reasoning": "user wants weather",
          "steps": [
            {"id": "s1", "description": "search", "skillName": "search-web", "toolArgs": {"query": "weather"}, "dependsOn": []}
          ],
          "successCriteria": ["weather returned"]
        }
        """#
        let llm = StubLLM(response: json)
        let planner = Planner(llm: llm, policy: ThinkingPolicy(mode: .off))
        let plan = try await planner.plan(userMessage: "what's the weather",
                                          availableSkills: [SkillSummary(name: "search-web",
                                                                          description: "search")])
        XCTAssertEqual(plan.goal, "find weather")
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.id, "s1")
        XCTAssertEqual(plan.steps.first?.skillName, "search-web")
        XCTAssertEqual(plan.steps.first?.toolArgs["query"], "weather")
        XCTAssertEqual(plan.successCriteria, ["weather returned"])
    }

    func testParsesPlanEmbeddedInProse() async throws {
        let response = """
        I'll plan this out. Here's the JSON:
        {"goal":"calc","reasoning":"add","steps":[{"id":"s1","description":"compute","skillName":"calculator","toolArgs":{"expression":"2+2"}}],"successCriteria":[]}
        Then we'll be done.
        """
        let planner = Planner(llm: StubLLM(response: response),
                              policy: ThinkingPolicy(mode: .off))
        let plan = try await planner.plan(userMessage: "do math", availableSkills: [])
        XCTAssertEqual(plan.goal, "calc")
        XCTAssertEqual(plan.steps.first?.toolArgs["expression"], "2+2")
    }

    func testInvalidJsonFallsBackToDefaultGoal() async throws {
        let planner = Planner(llm: StubLLM(response: "not json at all"),
                              policy: ThinkingPolicy(mode: .off))
        let plan = try await planner.plan(userMessage: "default goal here",
                                          availableSkills: [])
        XCTAssertEqual(plan.goal, "default goal here")
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testPromptIncludesSkillCatalog() async throws {
        let llm = StubLLM(response: "{}")
        let planner = Planner(llm: llm, policy: ThinkingPolicy(mode: .off))
        _ = try await planner.plan(
            userMessage: "test",
            availableSkills: [
                SkillSummary(name: "alpha", description: "first thing"),
                SkillSummary(name: "beta", description: "second thing"),
            ])
        XCTAssertTrue(llm.lastPrompt.contains("alpha: first thing"))
        XCTAssertTrue(llm.lastPrompt.contains("beta: second thing"))
        XCTAssertTrue(llm.lastPrompt.contains("test"))
    }

    func testReplanPromptDiffersFromInitial() {
        let initial = Planner.buildPlanPrompt(userMessage: "hello", skills: [])
        let replan = Planner.buildReplanPrompt(
            userMessage: "hello", skills: [],
            context: Planner.ReplanContext(
                priorPlan: ExecutionPlan(goal: "hello", reasoning: "", steps: []),
                priorResults: [:],
                evaluation: EvaluationResult(goalAchieved: false, assessment: "x", shouldReplan: true),
                replanAttempt: 1))
        XCTAssertTrue(initial.contains("planner that turns"))
        XCTAssertTrue(replan.contains("plan that fixes the gaps"))
        XCTAssertNotEqual(initial, replan)
    }

    func testPlannerThinkingFlagDelegatesToPolicy() async throws {
        let llm = StubLLM(response: "{}")
        let planner = Planner(llm: llm, policy: ThinkingPolicy(mode: .aggressive))
        _ = try await planner.plan(userMessage: "explain", availableSkills: [])
        XCTAssertTrue(llm.lastEnableThinking,
                      "Aggressive mode → planner thinking on")
    }

    func testNumericToolArgsCoercedToString() async throws {
        let llm = StubLLM(response: #"""
        {"goal":"x","reasoning":"y","steps":[{"id":"s1","description":"a","skillName":"calc","toolArgs":{"count":3,"name":"foo"}}]}
        """#)
        let planner = Planner(llm: llm, policy: ThinkingPolicy(mode: .off))
        let plan = try await planner.plan(userMessage: "x", availableSkills: [])
        XCTAssertEqual(plan.steps.first?.toolArgs["count"], "3")
        XCTAssertEqual(plan.steps.first?.toolArgs["name"], "foo")
    }
}
