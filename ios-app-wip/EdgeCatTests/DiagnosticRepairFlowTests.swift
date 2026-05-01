import XCTest
@testable import EdgeCat

/// End-to-end test: a step fails after `maxRepair` same-args retries, the
/// orchestrator runs a diagnostic LLM call, and applies the suggested fix.
final class DiagnosticRepairFlowTests: XCTestCase {

    private final class ScriptedLLM: LlmInferenceProvider, @unchecked Sendable {
        var responses: [String]
        init(_ responses: [String]) { self.responses = responses }
        func generateResponse(prompt: String, enableThinking: Bool, maxOutputTokens: Int) async throws -> String {
            responses.isEmpty ? "{}" : responses.removeFirst()
        }
        func cancel() {}
    }

    /// Tool that fails when given the original args, succeeds when given
    /// the LLM's "alternativeArgs" — proves the diagnostic loop wired the
    /// alternative args back into the retry.
    private final class FixableExec: ToolExecutor, @unchecked Sendable {
        let lock = NSLock()
        private(set) var allCalls: [[String: String]] = []
        private let goodArg: (key: String, value: String)
        init(goodArg: (key: String, value: String)) { self.goodArg = goodArg }
        func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
            lock.lock(); allCalls.append(args); lock.unlock()
            if args[goodArg.key] == goodArg.value {
                return ToolExecutionResult(success: true, output: "fixed")
            }
            return ToolExecutionResult(success: false, error: "DateTimeParseException")
        }
        func getAvailableSkills() -> [SkillSummary] { [] }
    }

    func testDiagnosticRetryAppliesAlternativeArgs() async {
        // Use a non-datetime arg key so StepArgRescue's date / phone /
        // placeholder normalizations don't accidentally fix the input
        // before the executor sees it. We want the bad value to reach
        // the tool unchanged, fail, and only be fixed via the LLM
        // diagnostic loop.
        let exec = FixableExec(goodArg: ("query", "good-value"))
        let llm = ScriptedLLM([
            #"""
            {"diagnosis":"query was wrong","fixType":"retry_with_different_args","alternativeArgs":{"query":"good-value"},"alternativeSkillName":null,"updatedInstructions":null}
            """#,
        ])
        let creator = SkillCreator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let orch = ExecutionOrchestrator(executor: exec,
                                          maxRepair: 1,
                                          llm: llm,
                                          skillCreator: creator)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "search",
                     toolName: "searchWeb",
                     toolArgs: ["query": "bad-value"]),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.status, .completed,
                       "Step should succeed after the diagnostic retry")
        XCTAssertEqual(results["s1"]?.output, "fixed")
        XCTAssertGreaterThanOrEqual(exec.allCalls.count, 2,
                                     "Should have called with bad args (>=1 incl. maxRepair) + once with corrected args")
        XCTAssertEqual(exec.allCalls.last?["query"], "good-value",
                        "Final call must use the LLM's alternative args")
    }

    func testDiagnosticSkipMarksStepCompleted() async {
        // Failing tool, LLM says "skip — this step isn't needed".
        let exec = FixableExec(goodArg: ("never", "matches"))
        let llm = ScriptedLLM([
            #"""
            {"diagnosis":"step is redundant","fixType":"skip","alternativeArgs":{}}
            """#,
        ])
        let creator = SkillCreator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let orch = ExecutionOrchestrator(executor: exec,
                                          maxRepair: 1,
                                          llm: llm,
                                          skillCreator: creator)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "redundant step", toolName: "manageCalendar"),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.status, .completed)
        XCTAssertTrue(results["s1"]?.output.contains("skipped") == true,
                      "Skip output should mention skipping for downstream consumers")
    }

    func testUnfixableDiagnosisLeavesStepFailed() async {
        let exec = FixableExec(goodArg: ("never", "matches"))
        let llm = ScriptedLLM([
            #"""
            {"diagnosis":"permission denied","fixType":"unfixable","alternativeArgs":{}}
            """#,
        ])
        let creator = SkillCreator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let orch = ExecutionOrchestrator(executor: exec,
                                          maxRepair: 1,
                                          llm: llm,
                                          skillCreator: creator)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "x", toolName: "manageCalendar"),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.status, .failed,
                       "Unfixable diagnosis should leave the step in failed state")
    }
}
