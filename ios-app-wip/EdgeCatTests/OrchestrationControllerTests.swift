import XCTest
@testable import EdgeCat

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
            "calculator": ToolExecutionResult(success: true, output: "4"),
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
            "calculator": ToolExecutionResult(success: true, output: "ok"),
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
        // Each iteration varies the plan arg so the idempotent-replan guard
        // doesn't bail early — we want to verify the maxIterations cap
        // specifically, not the loop-stuck guard.
        let evaluatorReplan = #"""
        {"goalAchieved":false,"shouldReplan":true,"assessment":"never","missingItems":[],"failedCriteria":[]}
        """#
        func plan(_ tag: String) -> String {
            #"""
            {"goal":"x","reasoning":"r","steps":[{"id":"s1","description":"x","toolName":"calc","toolArgs":{"v":"\#(tag)"}}]}
            """#
        }
        let llm = ScriptedLLM([
            plan("a"), evaluatorReplan,
            plan("b"), evaluatorReplan,
            plan("c"), evaluatorReplan,
            plan("d"), evaluatorReplan,
        ])
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

    func testIdempotentReplanGuardBailsBeforeMaxIterations() async throws {
        // Same plan + same args + same outcomes across iterations →
        // fingerprint matches → controller bails out instead of looping.
        // Saves ~25-30s per redundant iteration on stuck tasks.
        let evaluatorReplan = #"""
        {"goalAchieved":false,"shouldReplan":true,"assessment":"never","missingItems":[],"failedCriteria":[]}
        """#
        let plan = #"""
        {"goal":"x","reasoning":"r","steps":[{"id":"s1","description":"x","toolName":"calc","toolArgs":{"v":"same"}}]}
        """#
        let llm = ScriptedLLM([
            plan, evaluatorReplan,
            plan, evaluatorReplan,
            plan, evaluatorReplan,
        ])
        let tools = ScriptedExecutor(["calc": ToolExecutionResult(success: true, output: "y")])
        let ctrl = OrchestrationController(llm: llm, tools: tools,
                                           policy: ThinkingPolicy(mode: .off),
                                           maxIterations: 5)
        _ = try await ctrl.handle(userMessage: "hi")
        // Iter 0 records first fingerprint, iter 1 matches it and bails.
        XCTAssertEqual(ctrl.state.iteration, 1,
                       "Idempotency guard should bail on the second matching iteration")
    }

    func testIterationFingerprintMatchesAcrossIdenticalIterations() {
        // Same plan, same args, same outcomes → identical fingerprint
        // → controller should bail.
        let plan = ExecutionPlan(
            goal: "g", reasoning: "r",
            steps: [
                PlanStep(id: "s1", description: "x", skillName: "search-photos",
                         toolArgs: ["query": "foo"]),
                PlanStep(id: "s2", description: "y", skillName: "scan-barcode",
                         toolArgs: ["imageId": "abc"]),
            ])
        let resultsA: [String: StepResult] = [
            "s1": StepResult(stepId: "s1", status: .completed, output: "ok"),
            "s2": StepResult(stepId: "s2", status: .failed, error: "no barcode"),
        ]
        let resultsB = resultsA
        XCTAssertEqual(
            OrchestrationController.iterationFingerprint(plan: plan, results: resultsA),
            OrchestrationController.iterationFingerprint(plan: plan, results: resultsB))
    }

    func testIterationFingerprintDiffersWhenArgsChange() {
        let plan1 = ExecutionPlan(
            goal: "g", reasoning: "r",
            steps: [PlanStep(id: "s1", description: "x", skillName: "search-web",
                             toolArgs: ["query": "tokyo"])])
        let plan2 = ExecutionPlan(
            goal: "g", reasoning: "r",
            steps: [PlanStep(id: "s1", description: "x", skillName: "search-web",
                             toolArgs: ["query": "kyoto"])])
        let results: [String: StepResult] = [
            "s1": StepResult(stepId: "s1", status: .completed, output: "ok"),
        ]
        XCTAssertNotEqual(
            OrchestrationController.iterationFingerprint(plan: plan1, results: results),
            OrchestrationController.iterationFingerprint(plan: plan2, results: results))
    }

    func testNonRecoverableMarkersIncludePlannerShapeFailures() {
        // unknown-skill failure on every step → bail out
        let unknownSkill: [String: StepResult] = [
            "s1": StepResult(stepId: "s1", status: .failed,
                             error: "unknown skill: weather-api-skill"),
        ]
        XCTAssertTrue(
            OrchestrationController.allFailuresAreNonRecoverable(unknownSkill))

        // missing-arg failure on every step → bail out
        let missingArg: [String: StepResult] = [
            "s1": StepResult(stepId: "s1", status: .failed,
                             error: "missing 'query' argument"),
            "s2": StepResult(stepId: "s2", status: .failed,
                             error: "missing 'expression' argument"),
        ]
        XCTAssertTrue(
            OrchestrationController.allFailuresAreNonRecoverable(missingArg))

        // Mixed: one transient → DON'T bail, replan might fix it
        let mixed: [String: StepResult] = [
            "s1": StepResult(stepId: "s1", status: .failed,
                             error: "unknown skill: foo"),
            "s2": StepResult(stepId: "s2", status: .failed,
                             error: "network unreachable"),
        ]
        XCTAssertFalse(
            OrchestrationController.allFailuresAreNonRecoverable(mixed))
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
