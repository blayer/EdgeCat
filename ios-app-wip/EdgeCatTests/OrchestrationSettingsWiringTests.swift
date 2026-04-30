import XCTest
@testable import EdgeCat

/// Phase 1 wiring contract: every agent setting in `SamplerSettings.Snapshot`
/// must reach the `OrchestrationController` and its child components.
///
/// We construct the controller the same way `ChatViewModel` does, then verify
/// the values land where they're expected to drive runtime behavior. Tests
/// the constructor surface, not LLM behavior.
final class OrchestrationSettingsWiringTests: XCTestCase {

    private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
        func generateResponse(prompt: String, enableThinking: Bool) async throws -> String { "{}" }
        func cancel() {}
    }

    private final class StubTools: ToolExecutor, @unchecked Sendable {
        func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
            ToolExecutionResult(success: true, output: "")
        }
        func getAvailableSkills() -> [SkillSummary] { [] }
    }

    @MainActor
    func testAllAgentSettingsReachController() {
        let controller = OrchestrationController(
            llm: StubLLM(),
            tools: StubTools(),
            policy: ThinkingPolicy(mode: .auto),
            maxIterations: 5,
            maxRepair: 2,
            skillTimeoutSecs: 45,
            historyWindow: 8,
            userPortrait: "Likes brevity.",
            tracesEnabled: true)

        XCTAssertEqual(controller.maxIterations, 5)
        XCTAssertEqual(controller.maxRepair, 2)
        XCTAssertEqual(controller.skillTimeoutSecs, 45)
        XCTAssertEqual(controller.historyWindow, 8)
        XCTAssertEqual(controller.userPortrait, "Likes brevity.")
    }

    @MainActor
    func testDefaultsMatchSamplerSettingsAgentDefaults() {
        // Constructing with no overrides should match the same shape as
        // SamplerSettings.agentDefaults so first-launch behavior is the
        // same as Settings defaults.
        let controller = OrchestrationController(
            llm: StubLLM(),
            tools: StubTools())

        XCTAssertEqual(controller.maxIterations, 3,
                       "Default maxIterations should match SamplerSettings.agentDefaults.maxLoops")
        XCTAssertEqual(controller.historyWindow, 6,
                       "Default historyWindow should match SamplerSettings.agentDefaults.historyWindow")
        XCTAssertEqual(controller.userPortrait, "")
    }

    func testPlannerReceivesPortraitAndHistoryWindow() {
        let planner = Planner(llm: StubLLM(),
                               policy: ThinkingPolicy(mode: .off),
                               userPortrait: "Vegetarian.",
                               historyWindow: 4)
        XCTAssertEqual(planner.userPortrait, "Vegetarian.")
        XCTAssertEqual(planner.historyWindow, 4)

        let prompt = Planner.buildPrompt(
            userMessage: "what should I cook tonight?",
            skills: [],
            iteration: 0,
            userPortrait: "Vegetarian.",
            conversationContext: "user: previously asked about pasta")
        XCTAssertTrue(prompt.contains("Vegetarian."),
                      "Portrait must be folded into the prompt")
        XCTAssertTrue(prompt.contains("Recent conversation:"),
                      "Conversation context section must be present when non-empty")
        XCTAssertTrue(prompt.contains("previously asked about pasta"))
    }

    func testPromptOmitsEmptyOptionalSections() {
        let prompt = Planner.buildPrompt(
            userMessage: "hello",
            skills: [],
            iteration: 0)
        XCTAssertFalse(prompt.contains("User portrait"),
                       "Portrait section omitted when blank to avoid wasting tokens")
        XCTAssertFalse(prompt.contains("Recent conversation:"),
                       "Conversation section omitted when blank")
    }

    func testExecutionOrchestratorTimeoutFiresWhenSkillStalls() async {
        final class SlowExec: ToolExecutor, @unchecked Sendable {
            func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return ToolExecutionResult(success: true, output: "late")
            }
            func getAvailableSkills() -> [SkillSummary] { [] }
        }
        let orch = ExecutionOrchestrator(executor: SlowExec(), skillTimeoutSecs: 1)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "x", skillName: "slow"),
        ])
        let start = DispatchTime.now()
        let results = await orch.execute(plan: plan)
        let elapsedSec = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        XCTAssertEqual(results["s1"]?.status, .failed)
        XCTAssertTrue(results["s1"]?.error?.contains("timeout") == true,
                      "Error should report timeout, got: \(results["s1"]?.error ?? "nil")")
        XCTAssertLessThan(elapsedSec, 3.0,
                          "Timeout should cancel well before the 5s skill sleep completes")
    }

    func testExecutionOrchestratorRetriesUpToMaxRepair() async {
        final class FlakyExec: ToolExecutor, @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
            func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
                lock.lock(); count += 1; let n = count; lock.unlock()
                if n < 3 {
                    return ToolExecutionResult(success: false, error: "transient")
                }
                return ToolExecutionResult(success: true, output: "ok")
            }
            func getAvailableSkills() -> [SkillSummary] { [] }
        }
        let exec = FlakyExec()
        let orch = ExecutionOrchestrator(executor: exec, maxRepair: 2)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "x", skillName: "flaky"),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.status, .completed)
        XCTAssertEqual(exec.attempts, 3, "Should run 1 initial + 2 retries before succeeding")
    }

    func testExecutionOrchestratorStopsAfterMaxRepair() async {
        final class AlwaysFails: ToolExecutor, @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
            func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
                lock.lock(); count += 1; lock.unlock()
                return ToolExecutionResult(success: false, error: "permanent")
            }
            func getAvailableSkills() -> [SkillSummary] { [] }
        }
        let exec = AlwaysFails()
        let orch = ExecutionOrchestrator(executor: exec, maxRepair: 2)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "x", skillName: "broken"),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.status, .failed)
        XCTAssertEqual(exec.attempts, 3, "Should stop after 1 + maxRepair=2 attempts")
    }
}
