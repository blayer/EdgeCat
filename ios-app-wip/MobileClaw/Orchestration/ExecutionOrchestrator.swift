import Foundation

// Mirrors android-app/.../orchestration/ExecutionOrchestrator.kt — runs each
// step of an ExecutionPlan in dependency order via the injected ToolExecutor.
// The Android version is ~787 lines because it also handles repair / diagnosis
// loops and parallel execution; this Swift version is sequential. Phase 1
// adds the per-step skill timeout + same-args retry counter; the parallel
// batch executor + diagnostic repair come in Phase 5.

/// Serializes LLM-step execution. The LiteRT-LM Conversation is single-
/// threaded — concurrent calls would interleave token streams. Mirrors
/// Android's `llmMutex` in ExecutionOrchestrator.kt.
actor LlmStepLane {
    func run<T: Sendable>(_ block: @Sendable () async -> T) async -> T {
        await block()
    }
}

public final class ExecutionOrchestrator: @unchecked Sendable {
    public let executor: ToolExecutor
    private let trace: TraceRecorder?
    /// Per-skill execution deadline. 0 means no deadline (matches Android
    /// when the timeout setting is left at its default).
    public let skillTimeoutSecs: Int
    /// How many times a failed step is retried with the same args before
    /// giving up. Mirrors Android's `attemptRepair` retry counter.
    public let maxRepair: Int
    private let llmLane = LlmStepLane()

    public init(executor: ToolExecutor,
                trace: TraceRecorder? = nil,
                skillTimeoutSecs: Int = 0,
                maxRepair: Int = 0) {
        self.executor = executor
        self.trace = trace
        self.skillTimeoutSecs = skillTimeoutSecs
        self.maxRepair = maxRepair
    }

    /// Execute a plan in dependency-respecting batches. Tool-only steps
    /// within a batch run in parallel; LLM-only steps are serialized via
    /// `LlmStepLane`. Batches execute sequentially.
    public func execute(plan: ExecutionPlan) async -> [String: StepResult] {
        let batches = SkillTools.batches(for: plan)
        var results: [String: StepResult] = [:]
        for batch in batches {
            await trace?.event(kind: "batch.start", name: "batch",
                                payload: ["size": String(batch.count)])
            let batchResults = await runBatch(batch, results: results)
            for (id, res) in batchResults { results[id] = res }
            await trace?.event(kind: "batch.end", name: "batch", payload: [:])
        }
        return results
    }

    private func runBatch(_ batch: [PlanStep],
                          results: [String: StepResult]) async -> [String: StepResult] {
        let snapshot = results
        return await withTaskGroup(of: (String, StepResult).self) { group in
            for step in batch {
                group.addTask { [self] in
                    let r = await runStep(step, priorResults: snapshot)
                    return (step.id, r)
                }
            }
            var collected: [String: StepResult] = [:]
            for await (id, res) in group { collected[id] = res }
            return collected
        }
    }

    private func runStep(_ step: PlanStep,
                         priorResults: [String: StepResult]) async -> StepResult {
        // Dependency check — failed dep means skip.
        if step.dependsOn.contains(where: { priorResults[$0]?.status != .completed }) {
            return StepResult(stepId: step.id, status: .skipped, error: "dependency unmet")
        }

        let start = DispatchTime.now()
        await trace?.event(kind: "step.start", name: step.id,
                            payload: ["skill": step.skillName ?? ""])

        let resolved = SkillTools.resolveTool(skillName: step.skillName, toolName: step.toolName)
        let normalizedSkill = step.skillName.map(SkillTools.normalize)

        // No tool resolved → either an LLM-only step ("summarize", "compose")
        // or a description-only thinking step. Phase 5 keeps both as
        // synthesis stubs that just echo the description; the dedicated
        // LLM-step path lands when the orchestrator gains an inference
        // provider field. The lane mutex still guards future expansion.
        guard let tool = resolved, !tool.isEmpty else {
            return await llmLane.run {
                let dur = Int64(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                let result = StepResult(stepId: step.id, status: .completed,
                                        output: step.description,
                                        durationMs: dur)
                await self.trace?.event(kind: "step.end", name: step.id,
                                         payload: ["ok": "1", "lane": "llm"])
                return result
            }
        }

        // Resolve final args: rescue placeholders + date-time + phone.
        let depOutputs = step.dependsOn.reduce(into: [String: String]()) { acc, dep in
            if let r = priorResults[dep], r.status == .completed { acc[dep] = r.output }
        }
        var finalArgs = StepArgRescue.rescue(args: step.toolArgs, dependencies: depOutputs)

        // For runJs: inject normalized skillName so the WebView loader
        // hits the right asset folder.
        if tool == "runJs", let normalizedSkill, finalArgs["skillName"] == nil {
            finalArgs["skillName"] = normalizedSkill
        }

        var res = await runWithTimeout(toolName: tool, args: finalArgs)
        var attempt = 0
        while !res.success && attempt < maxRepair {
            attempt += 1
            await trace?.event(kind: "step.retry", name: step.id,
                                payload: ["attempt": String(attempt)])
            res = await runWithTimeout(toolName: tool, args: finalArgs)
        }

        let dur = Int64(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        let result = StepResult(
            stepId: step.id,
            status: res.success ? .completed : .failed,
            output: res.output,
            error: res.error,
            durationMs: dur
        )
        await trace?.event(kind: "step.end", name: step.id,
                            payload: ["ok": res.success ? "1" : "0",
                                      "retries": String(attempt),
                                      "tool": tool])
        return result
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
            for await res in group {
                group.cancelAll()
                if let res { return res }
                return ToolExecutionResult(success: false, error: "timeout after \(self.skillTimeoutSecs)s")
            }
            return ToolExecutionResult(success: false, error: "no result")
        }
    }
}
