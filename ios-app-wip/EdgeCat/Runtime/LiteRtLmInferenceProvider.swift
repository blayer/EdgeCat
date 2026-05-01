import Foundation

// Adapter so the orchestration module can talk to LiteRtLmEngine via the
// LlmInferenceProvider protocol without depending on the bridge directly.

public final class LiteRtLmInferenceProvider: LlmInferenceProvider, @unchecked Sendable {
    private let engine: LiteRtLmEngine
    public init(engine: LiteRtLmEngine) { self.engine = engine }

    public func generateResponse(prompt: String,
                                 enableThinking: Bool,
                                 maxOutputTokens: Int) async throws -> String {
        // Use generateOnce so the orchestrator's planner / evaluator /
        // formatter prompts run against a fresh conversation each time.
        // Reusing the live chat conversation appends every phase as a
        // new user turn and the model returns nonsense (LiteRtLmError 0).
        //
        // Thinking is toggled via the underlying C library's
        // `extra_context` JSON arg (mirrors the Android Gallery's
        // `extraContext = mapOf("enable_thinking" to "true")` hook).
        try await engine.generateOnce(
            prompt: prompt,
            maxOutputTokens: maxOutputTokens,
            extraContext: Self.makeExtraContext(enableThinking: enableThinking))
    }

    /// Build the `extra_context` dict the LiteRtLm bridge JSON-encodes
    /// and forwards to the C-side `litert_lm_conversation_send_message_stream`.
    /// Key + string-value shape matches what the Android Gallery sends
    /// (mapOf("enable_thinking" to "true"|"false")) so the C-side
    /// parser sees the same encoding on both platforms. Static so the
    /// mapping is unit-testable without a live engine.
    static func makeExtraContext(enableThinking: Bool) -> [String: String] {
        ["enable_thinking": enableThinking ? "true" : "false"]
    }

    public func cancel() { engine.stopResponse() }
}
