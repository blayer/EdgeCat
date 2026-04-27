import XCTest
@testable import MobileClaw

private final class ScriptedExecutor: ToolExecutor, @unchecked Sendable {
    private let scripts: [String: ToolExecutionResult]
    private(set) var calls: [(String, [String: String])] = []
    private let lock = NSLock()

    init(_ scripts: [String: ToolExecutionResult]) { self.scripts = scripts }

    func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
        lock.lock(); calls.append((toolName, args)); lock.unlock()
        return scripts[toolName] ?? ToolExecutionResult(success: false, error: "unscripted: \(toolName)")
    }

    func getAvailableSkills() -> [SkillSummary] {
        scripts.keys.sorted().map { SkillSummary(name: $0, description: "scripted") }
    }
}

final class ExecutionOrchestratorTests: XCTestCase {

    func testCompletesAllStepsInOrder() async {
        let exec = ScriptedExecutor([
            "a": ToolExecutionResult(success: true, output: "A"),
            "b": ToolExecutionResult(success: true, output: "B"),
        ])
        let orch = ExecutionOrchestrator(executor: exec)
        // Use toolName directly — bypasses the SkillTools.resolveTool
        // routing layer (which would map unknown skillNames to "runJs").
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "first", toolName: "a"),
            PlanStep(id: "s2", description: "second", toolName: "b", dependsOn: ["s1"]),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.status, .completed)
        XCTAssertEqual(results["s1"]?.output, "A")
        XCTAssertEqual(results["s2"]?.status, .completed)
        XCTAssertEqual(results["s2"]?.output, "B")
        XCTAssertEqual(Set(exec.calls.map(\.0)), Set(["a", "b"]))
    }

    func testSkipStepWhenDependencyFails() async {
        let exec = ScriptedExecutor([
            "a": ToolExecutionResult(success: false, error: "boom"),
            "b": ToolExecutionResult(success: true, output: "B"),
        ])
        let orch = ExecutionOrchestrator(executor: exec)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "first", toolName: "a"),
            PlanStep(id: "s2", description: "second", toolName: "b", dependsOn: ["s1"]),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.status, .failed)
        XCTAssertEqual(results["s2"]?.status, .skipped)
        XCTAssertEqual(results["s2"]?.error, "dependency unmet")
        XCTAssertEqual(exec.calls.map(\.0), ["a"], "Dependent step should not have called the executor")
    }

    func testStepWithoutToolNameJustEchoesDescription() async {
        let exec = ScriptedExecutor([:])
        let orch = ExecutionOrchestrator(executor: exec)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "thinking-only step"),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["s1"]?.status, .completed)
        XCTAssertEqual(results["s1"]?.output, "thinking-only step")
        XCTAssertTrue(exec.calls.isEmpty)
    }

    func testToolNameOverridesSkillName() async {
        let exec = ScriptedExecutor([
            "explicit-tool": ToolExecutionResult(success: true, output: "ok"),
        ])
        let orch = ExecutionOrchestrator(executor: exec)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "x",
                     skillName: "ignored-skill", toolName: "explicit-tool"),
        ])
        _ = await orch.execute(plan: plan)
        XCTAssertEqual(exec.calls.map(\.0), ["explicit-tool"])
    }

    func testStepArgsForwarded() async {
        let exec = ScriptedExecutor([
            "calc": ToolExecutionResult(success: true, output: "42"),
        ])
        let orch = ExecutionOrchestrator(executor: exec)
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "x", toolName: "calc",
                     toolArgs: ["expression": "6*7"]),
        ])
        _ = await orch.execute(plan: plan)
        XCTAssertEqual(exec.calls.first?.1["expression"], "6*7")
    }
}
