import Foundation

// 1:1 port of android-app/.../orchestration/LlmInferenceProvider.kt
//
// Abstraction over LLM inference. The app layer (LiteRtLmEngine) implements
// this and injects it into the orchestration module so the orchestration
// stack stays runtime-agnostic.

public protocol LlmInferenceProvider: AnyObject, Sendable {
    /// Run inference with the given prompt and return the complete response text.
    func generateResponse(prompt: String, enableThinking: Bool) async throws -> String

    /// Cancel any in-flight inference.
    func cancel()
}

public extension LlmInferenceProvider {
    func generateResponse(prompt: String) async throws -> String {
        try await generateResponse(prompt: prompt, enableThinking: false)
    }
}
