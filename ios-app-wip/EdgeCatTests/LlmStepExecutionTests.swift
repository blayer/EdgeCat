import XCTest
@testable import EdgeCat

/// LLM-only steps (`summarize`, `compose`, no resolved tool) must run a real
/// LLM call with prior step outputs as context, not echo the description.
/// Mirrors android-app's `executeLlmStep` behavior.
final class LlmStepExecutionTests: XCTestCase {

    private final class RecordingLLM: LlmInferenceProvider, @unchecked Sendable {
        let lock = NSLock()
        var prompts: [String] = []
        let canned: String
        init(canned: String = "synthesized") { self.canned = canned }
        func generateResponse(prompt: String, enableThinking: Bool, maxOutputTokens: Int) async throws -> String {
            lock.lock(); prompts.append(prompt); lock.unlock()
            return canned
        }
        func cancel() {}
    }

    private final class StubExec: ToolExecutor, @unchecked Sendable {
        func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
            ToolExecutionResult(success: true, output: "tool-\(toolName)")
        }
        func getAvailableSkills() -> [SkillSummary] { [] }
    }

    func testSummarizeStepRunsLlmCallWithPriorOutput() async {
        let llm = RecordingLLM(canned: "Tokyo is the capital of Japan…")
        let orch = ExecutionOrchestrator(executor: StubExec(), llm: llm)
        let plan = ExecutionPlan(goal: "summarize tokyo", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "fetch", toolName: "fetchWebContent",
                     toolArgs: ["url": "https://en.wikipedia.org/wiki/Tokyo"]),
            PlanStep(id: "s2", description: "summarize the article",
                     skillName: "summarize",
                     toolArgs: ["instruction": "summarize in two sentences"],
                     dependsOn: ["s1"]),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s2"]?.status, .completed)
        XCTAssertEqual(results["s2"]?.output, "Tokyo is the capital of Japan…")
        XCTAssertEqual(llm.prompts.count, 1, "Exactly one LLM call for the summarize step")
        let prompt = llm.prompts[0]
        XCTAssertTrue(prompt.contains("Result from s1"),
                      "Summarize prompt must include the prior step output")
        XCTAssertTrue(prompt.contains("summarize in two sentences"),
                      "Summarize prompt must include the explicit instruction")
        XCTAssertTrue(prompt.contains("Output ONLY the result text"),
                      "LLM-only skill prompt must include the no-preamble guard")
    }

    func testStepWithoutSkillOrToolFallsBackToLlm() async {
        let llm = RecordingLLM(canned: "thoughtful answer")
        let orch = ExecutionOrchestrator(executor: StubExec(), llm: llm)
        let plan = ExecutionPlan(goal: "think", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "think about the problem"),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.output, "thoughtful answer")
        XCTAssertEqual(llm.prompts.count, 1)
    }

    func testEchoFallbackWhenNoLlmInjected() async {
        // Existing tests rely on this — without an LLM, an LLM-only step
        // should still complete (echoing the description) so test setups
        // don't need a stub provider.
        let orch = ExecutionOrchestrator(executor: StubExec())
        let plan = ExecutionPlan(goal: "x", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "echo me"),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.status, .completed)
        XCTAssertEqual(results["s1"]?.output, "echo me",
                       "Without an LLM, the LLM-only branch echoes the description")
    }
}
