import XCTest
@testable import MobileClaw

private final class ScriptedLLM: LlmInferenceProvider, @unchecked Sendable {
    var responses: [String]
    private(set) var promptCount = 0
    private let lock = NSLock()
    init(_ responses: [String]) { self.responses = responses }
    func generateResponse(prompt: String, enableThinking: Bool) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        promptCount += 1
        if responses.isEmpty {
            return "{}"
        }
        return responses.removeFirst()
    }
    func cancel() {}
}

private final class ScriptedExecutor: ToolExecutor, @unchecked Sendable {
    let scripts: [String: ToolExecutionResult]
    init(_ scripts: [String: ToolExecutionResult]) { self.scripts = scripts }
    func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
        scripts[toolName] ?? ToolExecutionResult(success: false, error: "unscripted")
    }
    func getAvailableSkills() -> [SkillSummary] {
        scripts.keys.sorted().map { SkillSummary(name: $0, description: "x") }
    }
}

@MainActor
final class OrchestrationControllerTests: XCTestCase {

    func testHappyPathPlanExecuteEvaluateFormat() async throws {
        // Planner emits skillName "calculator" → SkillTools resolves to
        // tool "calculate" (matches Android NATIVE_SKILL_TOOLS map).
        // Single completed step + plain output → formatter passes through.
        let llm = ScriptedLLM([
            #"""
            {"goal":"calc","reasoning":"r","steps":[{"id":"s1","description":"compute","skillName":"calculator","toolArgs":{"expression":"2+2"}}],"successCriteria":[]}
            """#,
            #"""
            {"goalAchieved":true,"assessment":"good","missingItems":[],"shouldReplan":false,"failedCriteria":[]}
            """#,
        ])
        let tools = ScriptedExecutor([
            "calculate": ToolExecutionResult(success: true, output: "4"),
        ])
        let ctrl = OrchestrationController(llm: llm, tools: tools,
                                           policy: ThinkingPolicy(mode: .off),
                                           maxIterations: 3)
        let final = try await ctrl.handle(userMessage: "what's 2+2")
        XCTAssertEqual(final, "4")
        XCTAssertEqual(ctrl.state.status, .completed)
        XCTAssertEqual(ctrl.state.iteration, 0)
        XCTAssertEqual(ctrl.state.stepResults["s1"]?.status, .completed)
    }

    func testReplansWhenEvaluatorRequests() async throws {
        let llm = ScriptedLLM([
            // iter 0: plan
            #"""
            {"goal":"calc","reasoning":"r","steps":[{"id":"s1","description":"compute","skillName":"calculator","toolArgs":{"expression":"2+2"}}]}
            """#,
            // iter 0: evaluator → replan
            #"""
            {"goalAchieved":false,"assessment":"need more","shouldReplan":true,"missingItems":["x"],"failedCriteria":[]}
            """#,
            // iter 1: replan
            #"""
            {"goal":"calc","reasoning":"r2","steps":[{"id":"s1","description":"compute again","skillName":"calculator","toolArgs":{"expression":"3+3"}}]}
            """#,
            // iter 1: evaluator → done
            #"""
            {"goalAchieved":true,"assessment":"good","shouldReplan":false}
            """#,
        ])
        let tools = ScriptedExecutor([
            "calculate": ToolExecutionResult(success: true, output: "ok"),
        ])
        let ctrl = OrchestrationController(llm: llm, tools: tools,
                                           policy: ThinkingPolicy(mode: .off),
                                           maxIterations: 3)
        let final = try await ctrl.handle(userMessage: "calc me")
        XCTAssertEqual(final, "ok")
        XCTAssertEqual(ctrl.state.iteration, 1, "Should have replanned exactly once")
    }

    func testCapsAtMaxIterations() async throws {
        // Always responds replan=true; controller should cap at maxIterations.
        // Use toolName directly so we don't hit the SkillTools routing.
        let evaluatorReplan = #"""
        {"goalAchieved":false,"shouldReplan":true,"assessment":"never","missingItems":[],"failedCriteria":[]}
        """#
        let plan = #"""
        {"goal":"x","reasoning":"r","steps":[{"id":"s1","description":"x","toolName":"calc"}]}
        """#
        let llm = ScriptedLLM(Array(repeating: [plan, evaluatorReplan], count: 5).flatMap { $0 })
        let tools = ScriptedExecutor(["calc": ToolExecutionResult(success: true, output: "y")])
        let ctrl = OrchestrationController(llm: llm, tools: tools,
                                           policy: ThinkingPolicy(mode: .off),
                                           maxIterations: 2)
        let final = try await ctrl.handle(userMessage: "hi")
        XCTAssertFalse(final.isEmpty)
        // After maxIterations=2 → iterations 0,1 run; iteration counter
        // increments to 2 on the failed evaluation that triggers replan.
        XCTAssertEqual(ctrl.state.iteration, 2)
    }

    func testFailedSkillStillFormatsBestEffort() async throws {
        let llm = ScriptedLLM([
            #"""
            {"goal":"x","reasoning":"r","steps":[{"id":"s1","description":"x","toolName":"will-fail"}]}
            """#,
            #"""
            {"goalAchieved":false,"shouldReplan":false,"assessment":"failed but stop"}
            """#,
            "synthesized fallback",  // formatter LLM call
        ])
        let tools = ScriptedExecutor([
            "will-fail": ToolExecutionResult(success: false, error: "boom"),
        ])
        let ctrl = OrchestrationController(llm: llm, tools: tools,
                                           policy: ThinkingPolicy(mode: .off))
        let final = try await ctrl.handle(userMessage: "?")
        XCTAssertEqual(final, "synthesized fallback")
        XCTAssertEqual(ctrl.state.stepResults["s1"]?.status, .failed)
    }
}
