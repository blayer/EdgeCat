import Foundation
import Observation

// Mirrors android-app/.../orchestration/OrchestrationController.kt — composes
// Planner + ExecutionOrchestrator + SelfEvaluator + ResponseFormatter into
// the plan→execute→evaluate→replan loop. Exposes OrchestrationState as
// observable so a SwiftUI view can render progress.

@MainActor
@Observable
public final class OrchestrationController {
    public private(set) var state = OrchestrationState()

    private let planner: Planner
    private let executor: ExecutionOrchestrator
    private let evaluator: SelfEvaluator
    private let formatter: ResponseFormatter
    private let toolExecutor: ToolExecutor
    private let llm: LlmInferenceProvider
    private let trace: TraceRecorder

    public let maxIterations: Int
    public let maxRepair: Int
    public let skillTimeoutSecs: Int
    public let historyWindow: Int
    public let userPortrait: String
    private let memory: MemoryProvider
    private let conversationContextProvider: @Sendable () -> String

    /// Set by `cancel()`, checked at every batch / phase boundary in
    /// `handle(userMessage:)`. Once set, the loop bails out, the inference
    /// provider is told to abort any in-flight LLM call, and `handle`
    /// throws `OrchestrationError.cancelled`. Mirrors Android's
    /// `cancelled.set(true)` + `cancelled.get()` checks.
    private var cancelRequested: Bool = false

    public init(llm: LlmInferenceProvider,
                tools: ToolExecutor,
                policy: ThinkingPolicy = ThinkingPolicy(mode: .auto),
                trace: TraceRecorder? = nil,
                maxIterations: Int = 3,
                maxRepair: Int = 0,
                skillTimeoutSecs: Int = 0,
                historyWindow: Int = 6,
                userPortrait: String = "",
                tracesEnabled: Bool = true,
                memory: MemoryProvider = EmptyMemoryProvider(),
                conversationContext: @Sendable @escaping () -> String = { "" }) {
        let recorder = trace ?? TraceRecorder(enabled: tracesEnabled)
        self.planner = Planner(llm: llm, policy: policy,
                                userPortrait: userPortrait,
                                historyWindow: historyWindow)
        // Diagnostic repair: turn on whenever maxRepair > 0 so the LLM
        // gets a chance to fix bad args / suggest alternatives. Skipped
        // when maxRepair == 0 since the user has explicitly asked for no
        // retries at all.
        let skillCreator = maxRepair > 0
            ? SkillCreator(llm: llm, policy: policy)
            : nil
        self.executor = ExecutionOrchestrator(executor: tools,
                                              trace: recorder,
                                              skillTimeoutSecs: skillTimeoutSecs,
                                              maxRepair: maxRepair,
                                              llm: llm,
                                              policy: policy,
                                              skillCreator: skillCreator)
        self.evaluator = SelfEvaluator(llm: llm, policy: policy)
        self.formatter = ResponseFormatter(llm: llm, policy: policy)
        self.toolExecutor = tools
        self.llm = llm
        self.trace = recorder
        self.maxIterations = maxIterations
        self.maxRepair = maxRepair
        self.skillTimeoutSecs = skillTimeoutSecs
        self.historyWindow = historyWindow
        self.userPortrait = userPortrait
        self.memory = memory
        self.conversationContextProvider = conversationContext
    }

    /// Cancel any in-flight orchestration run. Idempotent — calling more
    /// than once or before `handle()` is a no-op. Matches Android's
    /// `OrchestrationController.cancel()`.
    public func cancel() {
        cancelRequested = true
        llm.cancel()
    }

    private func throwIfCancelled() throws {
        if cancelRequested { throw OrchestrationError.cancelled }
    }

    /// Run one user message through the orchestration loop.
    public func handle(userMessage: String) async throws -> String {
        cancelRequested = false
        var s = OrchestrationState()
        s.iteration = 0
        s.maxIterations = maxIterations
        state = s

        let skills = toolExecutor.getAvailableSkills()
        let memoryContext = await memory.recallForPlanning(userMessage: userMessage)
        state.memoryRecalled = !memoryContext.isEmpty
        let conversationContext = conversationContextProvider()
        let isOnline = ConnectivityChecker.isOnline()

        var plan: ExecutionPlan?
        var results: [String: StepResult] = [:]
        var lastEvaluation: EvaluationResult?

        while state.iteration < state.maxIterations {
            try throwIfCancelled()
            // Plan or replan based on iteration.
            state.status = .planning
            let p: ExecutionPlan
            if state.iteration == 0 {
                p = try await trace.phase(kind: "phase", name: "plan") {
                    try await planner.plan(
                        userMessage: userMessage,
                        availableSkills: skills,
                        iteration: 0,
                        conversationContext: conversationContext,
                        memoryContext: memoryContext,
                        isOnline: isOnline)
                }
            } else if let priorPlan = plan, let priorEval = lastEvaluation {
                let replanContext = Planner.ReplanContext(
                    priorPlan: priorPlan,
                    priorResults: results,
                    evaluation: priorEval,
                    replanAttempt: state.iteration)
                p = try await trace.phase(kind: "phase", name: "replan") {
                    try await planner.replan(
                        userMessage: userMessage,
                        availableSkills: skills,
                        context: replanContext,
                        conversationContext: conversationContext,
                        memoryContext: memoryContext)
                }
            } else {
                // Defensive: shouldn't happen because iteration > 0 implies a
                // prior loop set plan + evaluation. Fall back to a fresh plan.
                p = try await trace.phase(kind: "phase", name: "plan") {
                    try await planner.plan(
                        userMessage: userMessage,
                        availableSkills: skills,
                        iteration: state.iteration,
                        conversationContext: conversationContext,
                        memoryContext: memoryContext,
                        isOnline: isOnline)
                }
            }
            plan = p
            state.plan = p

            try throwIfCancelled()
            // Execute
            state.status = .executing
            results = await trace.phase(kind: "phase", name: "execute") {
                await executor.execute(plan: p)
            }
            state.stepResults = results

            try throwIfCancelled()
            // Evaluate
            state.status = .evaluating
            let evalResult = try await trace.phase(kind: "phase", name: "evaluate") {
                try await evaluator.evaluate(userMessage: userMessage, plan: p, results: results)
            }
            state.evaluation = evalResult
            lastEvaluation = evalResult
            if evalResult.goalAchieved || !evalResult.shouldReplan { break }
            state.status = .replanning
            state.iteration += 1
        }

        guard let finalPlan = plan else {
            state.status = .error
            state.error = "No plan produced"
            throw OrchestrationError.noPlan
        }

        try throwIfCancelled()
        // Format
        state.status = .formatting
        let formatted = try await trace.phase(kind: "phase", name: "format") {
            try await formatter.format(userMessage: userMessage,
                                       plan: finalPlan,
                                       results: results)
        }
        state.finalOutput = formatted.text
        state.finalOutputIsHtml = formatted.isHtml
        state.status = .completed

        // Memory write-back. Persist the run so future plans can recall it.
        // Only on goalAchieved — partial / failed runs would pollute recall.
        // Mirrors android-app's `MemoryRepository.save(episode:)` in
        // OrchestrationController.run after a successful turn.
        if let priorEval = lastEvaluation, priorEval.goalAchieved {
            let outcome = formatted.text.isEmpty ? "partial" : "success"
            let episode = OrchestrationEpisode(
                userMessage: userMessage,
                goal: finalPlan.goal,
                skillsUsed: finalPlan.steps.compactMap { $0.skillName },
                outcome: outcome,
                finalOutput: formatted.text)
            await memory.saveEpisode(episode)
        }
        return formatted.text
    }
}

public enum OrchestrationError: Error {
    case noPlan
    case cancelled
}
