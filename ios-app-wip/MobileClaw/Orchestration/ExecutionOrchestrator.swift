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
    /// Optional inference provider used for LLM-only steps (`summarize`,
    /// `compose`) and steps with no resolved tool. When nil, those steps
    /// fall back to echoing the step description.
    private let llm: LlmInferenceProvider?
    private let policy: ThinkingPolicy
    private let llmLane = LlmStepLane()

    /// When non-nil, triggers a single LLM-driven diagnostic-and-retry
    /// after `maxRepair` same-args retries have failed. Mirrors Android's
    /// `attemptRepair`. Pass `nil` to skip diagnostic repair.
    private let skillCreator: SkillCreator?

    public init(executor: ToolExecutor,
                trace: TraceRecorder? = nil,
                skillTimeoutSecs: Int = 0,
                maxRepair: Int = 0,
                llm: LlmInferenceProvider? = nil,
                policy: ThinkingPolicy = ThinkingPolicy(mode: .auto),
                skillCreator: SkillCreator? = nil) {
        self.executor = executor
        self.trace = trace
        self.skillTimeoutSecs = skillTimeoutSecs
        self.maxRepair = maxRepair
        self.llm = llm
        self.policy = policy
        self.skillCreator = skillCreator
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
        // or a description-only thinking step. Run a real LLM call with
        // prior step outputs as context (mirrors Android's executeLlmStep).
        // Falls back to echoing the description if no LLM was provided.
        guard let tool = resolved, !tool.isEmpty else {
            let result = await runLlmStep(step, priorResults: priorResults, start: start)
            return result
        }

        // Resolve final args: rescue placeholders + date-time + phone.
        // Feed ALL completed prior steps to the rescue, not just those
        // listed in `dependsOn`. Small models routinely emit
        // `toolArgs: {"url": "Output from s1"}` while leaving
        // `dependsOn: []`, which would otherwise leave the literal
        // string in the arg and fail with "invalid 'url' argument".
        // The substitution is keyed on the step ID appearing in the
        // arg value, so unrelated prior IDs are harmless.
        let depOutputs = priorResults.reduce(into: [String: String]()) { acc, kv in
            if kv.value.status == .completed { acc[kv.key] = kv.value.output }
        }
        var finalArgs = StepArgRescue.rescue(args: step.toolArgs, dependencies: depOutputs)

        // For runJs: inject normalized skillName so the WebView loader
        // hits the right asset folder.
        if tool == "runJs", let normalizedSkill, finalArgs["skillName"] == nil {
            finalArgs["skillName"] = normalizedSkill
        }

        var res = await runWithTimeout(toolName: tool, args: finalArgs)
        // If the registry doesn't know the skill (planner hallucinated
        // a name like `query-wikipedia` or `list_photos_album`), fall
        // through to an LLM-driven step using the description as the
        // instruction. Beats failing the step and burning a replan
        // iteration on the same hallucination.
        if !res.success,
           let err = res.error?.lowercased(),
           err.contains("unknown skill:") {
            await trace?.event(kind: "step.fallback_llm", name: step.id,
                                payload: ["from_skill": tool])
            return await runLlmStep(step, priorResults: priorResults, start: start)
        }
        var attempt = 0
        while !res.success && attempt < maxRepair {
            attempt += 1
            await trace?.event(kind: "step.retry", name: step.id,
                                payload: ["attempt": String(attempt)])
            res = await runWithTimeout(toolName: tool, args: finalArgs)
        }

        // Diagnostic-LLM repair. After `maxRepair` same-args retries have
        // failed and a SkillCreator is available, ask the LLM what's wrong
        // and apply the suggested fix once. Mirrors Android's attemptRepair.
        var diagnosticUsed = false
        if !res.success, let skillCreator,
           let errorText = res.error, !errorText.isEmpty {
            await trace?.event(kind: "step.diagnose.start", name: step.id,
                                payload: ["error": String(errorText.prefix(200))])
            let diagnostic = await skillCreator.diagnose(
                failedStep: step, error: errorText)
            await trace?.event(kind: "step.diagnose.end", name: step.id,
                                payload: ["fixType": diagnostic.fixType,
                                          "alt": diagnostic.alternativeSkillName ?? ""])
            switch diagnostic.fixType {
            case "retry_with_different_args":
                let merged = finalArgs.merging(diagnostic.alternativeArgs) { _, new in new }
                res = await runWithTimeout(toolName: tool, args: merged)
                if res.success { finalArgs = merged }
                diagnosticUsed = true
            case "use_alternative_skill":
                if let altName = diagnostic.alternativeSkillName,
                   let altTool = SkillTools.resolveTool(skillName: altName, toolName: nil),
                   !altTool.isEmpty {
                    let altArgs = diagnostic.alternativeArgs.isEmpty
                        ? finalArgs
                        : diagnostic.alternativeArgs
                    res = await runWithTimeout(toolName: altTool, args: altArgs)
                    diagnosticUsed = true
                }
            case "skip":
                // Step is unnecessary — mark completed with the diagnostic
                // explanation so downstream steps don't get marked skipped.
                res = ToolExecutionResult(
                    success: true,
                    output: "skipped: \(diagnostic.diagnosis)")
                diagnosticUsed = true
            default:
                break
            }
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
                                      "diagnostic": diagnosticUsed ? "1" : "0",
                                      "tool": tool])
        return result
    }

    /// LLM-only step (summarize / compose / no resolved tool). Builds a
    /// prompt from prior step outputs + the step's instruction (preferring
    /// `toolArgs["instruction"]`, falling back to `description`), then asks
    /// the LLM. Serialized via `llmLane` so two LLM steps in the same batch
    /// can't overlap on the single LiteRT-LM conversation.
    /// Mirrors android-app/.../ExecutionOrchestrator.executeLlmStep.
    private func runLlmStep(_ step: PlanStep,
                            priorResults: [String: StepResult],
                            start: DispatchTime) async -> StepResult {
        let isLlmSkill = step.skillName.map(SkillTools.normalize)
            .map { SkillTools.llmOnly.contains($0) } ?? false
        let maxOutputLen = isLlmSkill ? 3000 : 500

        var contextParts: [String] = []
        for depId in step.dependsOn {
            if let depResult = priorResults[depId], depResult.status == .completed {
                let truncated = String(depResult.output.prefix(maxOutputLen))
                contextParts.append("Result from \(depId): \(truncated)")
            }
        }

        // Prefer explicit instruction arg. For non-summarize skills also
        // accept "text" as the task; otherwise fall back to step.description.
        let taskText: String
        if let instruction = step.toolArgs["instruction"], !instruction.isEmpty {
            taskText = instruction
        } else if let text = step.toolArgs["text"], !text.isEmpty,
                  step.skillName != "summarize" {
            taskText = text
        } else {
            taskText = step.description
        }

        var prompt = ""
        if !contextParts.isEmpty {
            prompt += "Context from previous steps:\n"
            prompt += contextParts.joined(separator: "\n")
            prompt += "\n\n"
        }
        prompt += "Task: \(taskText)"
        if isLlmSkill {
            prompt += "\n\nIMPORTANT: Output ONLY the result text. Do not add explanations or preamble."
        }

        let llmRef = self.llm
        return await llmLane.run { [trace] in
            let result: StepResult
            if let llmRef {
                do {
                    let response = try await llmRef.generateResponse(
                        prompt: prompt,
                        enableThinking: self.policy.llmStep())
                    let dur = Int64(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                    result = StepResult(stepId: step.id, status: .completed,
                                        output: response, durationMs: dur)
                    await trace?.event(kind: "step.end", name: step.id,
                                       payload: ["ok": "1", "lane": "llm"])
                } catch {
                    let dur = Int64(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                    result = StepResult(stepId: step.id, status: .failed,
                                        error: error.localizedDescription,
                                        durationMs: dur)
                    await trace?.event(kind: "step.end", name: step.id,
                                       payload: ["ok": "0", "lane": "llm"])
                }
            } else {
                // No LLM injected — echo the description as before so test
                // callers without an LLM provider keep working.
                let dur = Int64(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                result = StepResult(stepId: step.id, status: .completed,
                                    output: step.description, durationMs: dur)
                await trace?.event(kind: "step.end", name: step.id,
                                   payload: ["ok": "1", "lane": "llm-stub"])
            }
            return result
        }
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
