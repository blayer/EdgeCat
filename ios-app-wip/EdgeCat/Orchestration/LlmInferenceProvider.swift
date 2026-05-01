import Foundation

// 1:1 port of android-app/.../orchestration/LlmInferenceProvider.kt
//
// Abstraction over LLM inference. The app layer (LiteRtLmEngine) implements
// this and injects it into the orchestration module so the orchestration
// stack stays runtime-agnostic.

public protocol LlmInferenceProvider: AnyObject, Sendable {
    /// Run inference with the given prompt and return the complete response
    /// text. `maxOutputTokens=0` means engine default (usually unbounded);
    /// orchestration call sites pass a small cap (e.g. 512–1024) for the
    /// planner / evaluator where the response shape is bounded JSON, which
    /// caps decode time directly.
    func generateResponse(prompt: String,
                          enableThinking: Bool,
                          maxOutputTokens: Int) async throws -> String

    /// Cancel any in-flight inference.
    func cancel()
}

public extension LlmInferenceProvider {
    /// Convenience: full-default call (no thinking, unbounded output).
    func generateResponse(prompt: String) async throws -> String {
        try await generateResponse(prompt: prompt, enableThinking: false, maxOutputTokens: 0)
    }
    /// Convenience: control thinking only, leave output cap at engine default.
    func generateResponse(prompt: String, enableThinking: Bool) async throws -> String {
        try await generateResponse(prompt: prompt,
                                   enableThinking: enableThinking,
                                   maxOutputTokens: 0)
    }
}
