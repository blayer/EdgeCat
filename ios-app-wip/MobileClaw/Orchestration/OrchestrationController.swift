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
    private let trace: TraceRecorder

    public init(llm: LlmInferenceProvider,
                tools: ToolExecutor,
                policy: ThinkingPolicy = ThinkingPolicy(mode: .auto),
                trace: TraceRecorder = TraceRecorder()) {
        self.planner = Planner(llm: llm, policy: policy)
        self.executor = ExecutionOrchestrator(executor: tools, trace: trace)
        self.evaluator = SelfEvaluator(llm: llm, policy: policy)
        self.formatter = ResponseFormatter(llm: llm, policy: policy)
        self.toolExecutor = tools
        self.trace = trace
    }

    /// Run one user message through the orchestration loop.
    public func handle(userMessage: String) async throws -> String {
        var s = OrchestrationState()
        s.iteration = 0
        s.maxIterations = 3
        state = s

        let skills = toolExecutor.getAvailableSkills()
        var plan: ExecutionPlan?
        var results: [String: StepResult] = [:]

        while state.iteration < state.maxIterations {
            // Plan
            state.status = .planning
            let p = try await trace.phase(kind: "phase", name: "plan") {
                try await planner.plan(userMessage: userMessage,
                                        availableSkills: skills,
                                        iteration: state.iteration)
            }
            plan = p
            state.plan = p

            // Execute
            state.status = .executing
            results = await trace.phase(kind: "phase", name: "execute") {
                await executor.execute(plan: p)
            }
            state.stepResults = results

            // Evaluate
            state.status = .evaluating
            let evalResult = try await trace.phase(kind: "phase", name: "evaluate") {
                try await evaluator.evaluate(userMessage: userMessage, plan: p, results: results)
            }
            state.evaluation = evalResult
            if evalResult.goalAchieved || !evalResult.shouldReplan { break }
            state.status = .replanning
            state.iteration += 1
        }

        guard let finalPlan = plan else {
            state.status = .error
            state.error = "No plan produced"
            throw OrchestrationError.noPlan
        }

        // Format
        state.status = .formatting
        let final = try await trace.phase(kind: "phase", name: "format") {
            try await formatter.format(userMessage: userMessage, plan: finalPlan, results: results)
        }
        state.finalOutput = final
        state.status = .completed
        return final
    }
}

public enum OrchestrationError: Error {
    case noPlan
    case cancelled
}
