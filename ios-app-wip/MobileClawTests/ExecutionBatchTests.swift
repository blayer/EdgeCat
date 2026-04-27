import XCTest
@testable import MobileClaw

final class ExecutionBatchTests: XCTestCase {

    func testIndependentStepsLandInOneBatch() {
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "a", description: "x"),
            PlanStep(id: "b", description: "x"),
            PlanStep(id: "c", description: "x"),
        ])
        let batches = SkillTools.batches(for: plan)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(Set(batches[0].map(\.id)), ["a", "b", "c"])
    }

    func testChainOfDependenciesProducesOneBatchPerStep() {
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "a", description: "x"),
            PlanStep(id: "b", description: "x", dependsOn: ["a"]),
            PlanStep(id: "c", description: "x", dependsOn: ["b"]),
        ])
        let batches = SkillTools.batches(for: plan)
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0].map(\.id), ["a"])
        XCTAssertEqual(batches[1].map(\.id), ["b"])
        XCTAssertEqual(batches[2].map(\.id), ["c"])
    }

    func testDiamondGraphProducesThreeBatches() {
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "root", description: "x"),
            PlanStep(id: "left", description: "x", dependsOn: ["root"]),
            PlanStep(id: "right", description: "x", dependsOn: ["root"]),
            PlanStep(id: "merge", description: "x", dependsOn: ["left", "right"]),
        ])
        let batches = SkillTools.batches(for: plan)
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0].map(\.id), ["root"])
        XCTAssertEqual(Set(batches[1].map(\.id)), ["left", "right"])
        XCTAssertEqual(batches[2].map(\.id), ["merge"])
    }

    func testEmptyPlanReturnsNoBatches() {
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [])
        XCTAssertTrue(SkillTools.batches(for: plan).isEmpty)
    }

    func testIndependentBatchRunsConcurrently() async {
        // Two slow tools; if they ran serially total ≥ 2*delay. In parallel
        // total ≈ delay. We use 200ms each and assert total < 500ms.
        final class SlowExec: ToolExecutor, @unchecked Sendable {
            func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return ToolExecutionResult(success: true, output: toolName)
            }
            func getAvailableSkills() -> [SkillSummary] { [] }
        }
        let orch = ExecutionOrchestrator(executor: SlowExec())
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "a", description: "x", toolName: "alpha"),
            PlanStep(id: "b", description: "x", toolName: "beta"),
            PlanStep(id: "c", description: "x", toolName: "gamma"),
        ])
        let start = DispatchTime.now()
        let results = await orch.execute(plan: plan)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results["a"]?.output, "alpha")
        XCTAssertLessThan(elapsedMs, 500.0,
                          "Three 200ms tools in one batch should finish under 500ms; got \(elapsedMs)ms")
    }

    func testDependentStepsRespectOrder() async {
        // First step writes to a counter; second step depends on it.
        // If the second runs before the first's dependency check passes,
        // it would be skipped instead of completed.
        actor Counter {
            var n = 0
            func bump() -> Int { n += 1; return n }
        }
        final class Exec: ToolExecutor, @unchecked Sendable {
            let c: Counter
            init(_ c: Counter) { self.c = c }
            func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
                let n = await c.bump()
                return ToolExecutionResult(success: true, output: "\(toolName)=\(n)")
            }
            func getAvailableSkills() -> [SkillSummary] { [] }
        }
        let orch = ExecutionOrchestrator(executor: Exec(Counter()))
        let plan = ExecutionPlan(goal: "g", reasoning: "r", steps: [
            PlanStep(id: "first", description: "x", toolName: "alpha"),
            PlanStep(id: "second", description: "x", toolName: "beta",
                     dependsOn: ["first"]),
        ])
        let results = await orch.execute(plan: plan)
        XCTAssertEqual(results["first"]?.status, .completed)
        XCTAssertEqual(results["second"]?.status, .completed)
    }
}
