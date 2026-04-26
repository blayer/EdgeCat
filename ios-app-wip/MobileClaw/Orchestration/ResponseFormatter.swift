import Foundation

// Mirrors android-app/.../orchestration/ResponseFormatter.kt — turns the raw
// step results into a single user-facing answer. The Android version uses
// the LLM to format; for Phase D scaffold we keep it deterministic and let
// the LLM-driven path land later.

public struct ResponseFormatter {
    public let llm: LlmInferenceProvider
    public let policy: ThinkingPolicy

    public init(llm: LlmInferenceProvider, policy: ThinkingPolicy) {
        self.llm = llm
        self.policy = policy
    }

    /// Format the final user-facing response.
    /// - Parameters:
    ///   - userMessage: original user prompt
    ///   - plan: the plan that was executed
    ///   - results: completed step results keyed by step id
    public func format(userMessage: String,
                       plan: ExecutionPlan,
                       results: [String: StepResult]) async throws -> String {
        // Deterministic fallback: pick the last successful step's output, else
        // synthesize from any non-empty outputs joined by blank lines.
        let ordered = plan.steps.map { results[$0.id] }.compactMap { $0 }
        if let last = ordered.last(where: { $0.status == .completed && !$0.output.isEmpty }) {
            return last.output
        }
        let pieces = ordered.compactMap { $0.output.isEmpty ? nil : $0.output }
        if !pieces.isEmpty { return pieces.joined(separator: "\n\n") }

        // Last-resort: ask the LLM. This mirrors Android's primary path.
        let prompt = """
        You ran this plan in response to the user message: \(userMessage)
        Step results:
        \(ordered.map { "- \($0.stepId): \($0.status.rawValue) — \($0.output)" }.joined(separator: "\n"))

        Write a concise, friendly answer for the user.
        """
        return try await llm.generateResponse(prompt: prompt, enableThinking: policy.format())
    }
}
