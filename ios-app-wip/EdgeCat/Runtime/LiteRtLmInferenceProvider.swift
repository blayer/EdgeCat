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
    /// Matches the Android Gallery pattern exactly:
    /// `if (enableThinking) mapOf("enable_thinking" to "true") else null`
    /// — i.e. ONLY include the key when thinking is on. Sending
    /// `"enable_thinking":"false"` explicitly was empirically slower
    /// (the SDK seems to interpret presence-of-key as "model is being
    /// asked about thinking, emit a CoT preamble"); omitting the key
    /// returns the engine to its default behavior. Empty dict
    /// serializes to `{}`, the same default the bridge already used.
    static func makeExtraContext(enableThinking: Bool) -> [String: String] {
        enableThinking ? ["enable_thinking": "true"] : [:]
    }

    public func cancel() { engine.stopResponse() }
}
