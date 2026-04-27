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
    /// - Returns: a `Formatted` value with the synthesized text + flags the
    ///   chat layer needs (`isHtml` for WebView rendering of skill outputs
    ///   that include tables / formatted markup).
    public func format(userMessage: String,
                       plan: ExecutionPlan,
                       results: [String: StepResult]) async throws -> Formatted {
        let ordered = plan.steps.map { results[$0.id] }.compactMap { $0 }
        let isHtml = ordered.contains { Self.containsHtmlMarkup($0.output) }
        let isComplex = ordered.count >= 3 || isHtml

        // Single successful step → pass its output through verbatim. Saves
        // an LLM call when the skill already produced a user-ready answer.
        let successful = ordered.filter { $0.status == .completed && !$0.output.isEmpty }
        if successful.count == 1, !isComplex {
            return Formatted(text: successful[0].output, isHtml: isHtml)
        }

        // Multi-step or complex output → synthesize with the LLM. Mirrors
        // Android's primary path. Falls back to deterministic join if the
        // LLM call throws.
        if !ordered.isEmpty {
            let prompt = """
            You ran this plan in response to the user message: \(userMessage)
            Goal: \(plan.goal)

            Step results:
            \(ordered.map { "- \($0.stepId) [\($0.status.rawValue)]: \($0.output)" }.joined(separator: "\n"))

            Write a concise, friendly final answer for the user. \
            If the step results contain HTML markup, preserve it verbatim. \
            Do not invent facts not present in the step results.
            """
            do {
                let text = try await llm.generateResponse(
                    prompt: prompt,
                    enableThinking: policy.format(complexOutput: isComplex))
                return Formatted(text: text, isHtml: isHtml)
            } catch {
                let pieces = ordered.compactMap { $0.output.isEmpty ? nil : $0.output }
                return Formatted(text: pieces.joined(separator: "\n\n"), isHtml: isHtml)
            }
        }

        return Formatted(text: "(no result)", isHtml: false)
    }

    public struct Formatted: Sendable, Equatable {
        public let text: String
        public let isHtml: Bool
        public init(text: String, isHtml: Bool) {
            self.text = text; self.isHtml = isHtml
        }
    }

    /// Cheap heuristic — looks for an opening tag from the set we'd actually
    /// want to render (`<table>`, `<ul>`, `<ol>`, `<pre>`, `<code>`, `<a >`,
    /// `<div>`). Plain `<` in prose doesn't qualify.
    static func containsHtmlMarkup(_ text: String) -> Bool {
        let markers = ["<table", "<ul", "<ol", "<pre", "<code", "<a ", "<div", "<h1", "<h2", "<img"]
        let lower = text.lowercased()
        return markers.contains { lower.contains($0) }
    }
}
