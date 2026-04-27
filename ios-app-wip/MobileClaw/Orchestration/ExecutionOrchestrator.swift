import Foundation

// Mirrors android-app/.../orchestration/ExecutionOrchestrator.kt — runs each
// step of an ExecutionPlan in dependency order via the injected ToolExecutor.
// The Android version is ~787 lines because it also handles repair / diagnosis
// loops and parallel execution; this Swift version is sequential. Phase 1
// adds the per-step skill timeout + same-args retry counter; the parallel
// batch executor + diagnostic repair come in Phase 5.

public final class ExecutionOrchestrator {
    public let executor: ToolExecutor
    private let trace: TraceRecorder?
    /// Per-skill execution deadline. 0 means no deadline (matches Android
    /// when the timeout setting is left at its default).
    public let skillTimeoutSecs: Int
    /// How many times a failed step is retried with the same args before
    /// giving up. Mirrors Android's `attemptRepair` retry counter; the
    /// diagnostic-LLM repair path lands in Phase 5.
    public let maxRepair: Int

    public init(executor: ToolExecutor,
                trace: TraceRecorder? = nil,
                skillTimeoutSecs: Int = 0,
                maxRepair: Int = 0) {
        self.executor = executor
        self.trace = trace
        self.skillTimeoutSecs = skillTimeoutSecs
        self.maxRepair = maxRepair
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

            var res = await runWithTimeout(toolName: toolName, args: step.toolArgs)
            var attempt = 0
            while !res.success && attempt < maxRepair {
                attempt += 1
                await trace?.event(kind: "step.retry", name: step.id,
                                   payload: ["attempt": String(attempt)])
                res = await runWithTimeout(toolName: toolName, args: step.toolArgs)
            }

            let dur = Int64(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            results[step.id] = StepResult(
                stepId: step.id,
                status: res.success ? .completed : .failed,
                output: res.output,
                error: res.error,
                durationMs: dur
            )
            await trace?.event(kind: "step.end", name: step.id,
                               payload: ["ok": res.success ? "1" : "0",
                                         "retries": String(attempt)])
        }
        return results
    }

    private func runWithTimeout(toolName: String, args: [String: String]) async -> ToolExecutionResult {
        guard skillTimeoutSecs > 0 else {
            return await executor.executeTool(toolName: toolName, args: args)
        }
        let deadlineNs = UInt64(skillTimeoutSecs) * 1_000_000_000
        return await withTaskGroup(of: ToolExecutionResult?.self) { group in
            group.addTask { await self.executor.executeTool(toolName: toolName, args: args) }
            group.addTask {
                try? await Task.sleep(nanoseconds: deadlineNs)
                return nil
            }
            // First completion wins; cancel the loser.
            for await res in group {
                group.cancelAll()
                if let res { return res }
                return ToolExecutionResult(success: false, error: "timeout after \(self.skillTimeoutSecs)s")
            }
            return ToolExecutionResult(success: false, error: "no result")
        }
    }
}
