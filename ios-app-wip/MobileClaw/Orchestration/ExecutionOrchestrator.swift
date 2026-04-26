import Foundation

// Mirrors android-app/.../orchestration/ExecutionOrchestrator.kt — runs each
// step of an ExecutionPlan in dependency order via the injected ToolExecutor.
// The Android version is ~787 lines because it also handles repair / diagnosis
// loops and parallel execution; this Swift version is sequential and lets the
// SelfEvaluator drive replans (Phase D scope).

public final class ExecutionOrchestrator {
    public let executor: ToolExecutor
    private let trace: TraceRecorder?

    public init(executor: ToolExecutor, trace: TraceRecorder? = nil) {
        self.executor = executor
        self.trace = trace
    }

    public func execute(plan: ExecutionPlan) async -> [String: StepResult] {
        var results: [String: StepResult] = [:]
        for step in plan.steps {
            // Dependency check.
            if step.dependsOn.contains(where: { results[$0]?.status != .completed }) {
                results[step.id] = StepResult(stepId: step.id, status: .skipped,
                                              error: "dependency unmet")
                continue
            }
            let start = DispatchTime.now()
            await trace?.event(kind: "step.start", name: step.id, payload: ["skill": step.skillName ?? ""])
            let toolName = step.toolName ?? step.skillName ?? ""
            if toolName.isEmpty {
                results[step.id] = StepResult(stepId: step.id, status: .completed,
                                              output: step.description)
                continue
            }
            let res = await executor.executeTool(toolName: toolName, args: step.toolArgs)
            let dur = Int64(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            results[step.id] = StepResult(
                stepId: step.id,
                status: res.success ? .completed : .failed,
                output: res.output,
                error: res.error,
                durationMs: dur
            )
            await trace?.event(kind: "step.end", name: step.id,
                               payload: ["ok": res.success ? "1" : "0"])
        }
        return results
    }
}
