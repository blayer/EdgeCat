import XCTest
@testable import EdgeCat

private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
    let response: String
    private(set) var lastPrompt: String = ""
    private(set) var lastEnableThinking: Bool = false
    init(response: String) { self.response = response }
    func generateResponse(prompt: String, enableThinking: Bool, maxOutputTokens: Int) async throws -> String {
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
        let plan = try await planner.plan(
            userMessage: "do math",
            availableSkills: [SkillSummary(name: "calculator", description: "x")])
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

    func testHallucinatedSkillStepsAreDropped() async throws {
        // Planner emits two steps: one valid skill, one hallucinated.
        // The hallucinated step should be dropped before the executor
        // sees it, so we don't burn a failed-step + replan on it.
        let response = #"""
        {
          "goal":"trip plan",
          "reasoning":"r",
          "steps":[
            {"id":"s1","description":"search","skillName":"search-web","toolArgs":{"query":"tokyo"}},
            {"id":"s2","description":"weather","skillName":"weather-api-skill","toolArgs":{"city":"tokyo"}}
          ],
          "successCriteria":[]
        }
        """#
        let planner = Planner(llm: StubLLM(response: response),
                              policy: ThinkingPolicy(mode: .off))
        let plan = try await planner.plan(
            userMessage: "tokyo trip",
            availableSkills: [SkillSummary(name: "search-web", description: "x")])
        XCTAssertEqual(plan.steps.map(\.id), ["s1"])
    }

    func testEmptyOrNullSkillNamePreservedAsLlmStep() async throws {
        // skillName=null and "" → LLM-only step, must pass through.
        let response = #"""
        {
          "goal":"think",
          "reasoning":"r",
          "steps":[
            {"id":"s1","description":"reason","skillName":null,"toolArgs":{}},
            {"id":"s2","description":"plan","skillName":"","toolArgs":{}}
          ],
          "successCriteria":[]
        }
        """#
        let planner = Planner(llm: StubLLM(response: response),
                              policy: ThinkingPolicy(mode: .off))
        let plan = try await planner.plan(userMessage: "x", availableSkills: [])
        XCTAssertEqual(plan.steps.count, 2)
    }

    func testLlmOnlySkillNamesPreserved() async throws {
        // "summarize" and "compose" are LLM-only — the executor synthesizes
        // them, they're never dispatched to the registry, so they must
        // survive the filter even though they're not in availableSkills.
        let response = #"""
        {
          "goal":"summarize",
          "reasoning":"r",
          "steps":[
            {"id":"s1","description":"summarize","skillName":"summarize","toolArgs":{}}
          ],
          "successCriteria":[]
        }
        """#
        let planner = Planner(llm: StubLLM(response: response),
                              policy: ThinkingPolicy(mode: .off))
        let plan = try await planner.plan(userMessage: "x", availableSkills: [])
        XCTAssertEqual(plan.steps.count, 1)
    }

    func testFilterPreservesPlanWhenAllStepsAreHallucinated() {
        // If filtering would empty a non-empty plan, keep the originals.
        // Empty plan → "(no result)" final output; better to let the
        // executor fail per-step so the replan has error context.
        let plan = ExecutionPlan(
            goal: "g", reasoning: "r",
            steps: [
                PlanStep(id: "s1", description: "x", skillName: "weather-api"),
                PlanStep(id: "s2", description: "y", skillName: "query-wikipedia"),
            ])
        let filtered = Planner.filterUnknownSkills(
            plan: plan,
            available: [SkillSummary(name: "search-web", description: "x")])
        XCTAssertEqual(filtered.steps.count, 2,
                       "Empty result must fall back to originals so the executor produces useful errors")
    }

    func testFilterUnknownSkillsHandlesUnderscoreAlias() {
        // LLMs frequently emit underscore-cased names; the resolver
        // normalizes to hyphen-case, so the filter must too.
        let plan = ExecutionPlan(
            goal: "g", reasoning: "r",
            steps: [
                PlanStep(id: "s1", description: "x", skillName: "search_web"),
            ])
        let filtered = Planner.filterUnknownSkills(
            plan: plan,
            available: [SkillSummary(name: "search-web", description: "x")])
        XCTAssertEqual(filtered.steps.count, 1)
    }

    func testNumericToolArgsCoercedToString() async throws {
        let llm = StubLLM(response: #"""
        {"goal":"x","reasoning":"y","steps":[{"id":"s1","description":"a","skillName":"calc","toolArgs":{"count":3,"name":"foo"}}]}
        """#)
        let planner = Planner(llm: llm, policy: ThinkingPolicy(mode: .off))
        let plan = try await planner.plan(
            userMessage: "x",
            availableSkills: [SkillSummary(name: "calc", description: "x")])
        XCTAssertEqual(plan.steps.first?.toolArgs["count"], "3")
        XCTAssertEqual(plan.steps.first?.toolArgs["name"], "foo")
    }
}
