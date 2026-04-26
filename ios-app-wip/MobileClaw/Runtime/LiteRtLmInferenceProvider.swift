import Foundation

// Adapter so the orchestration module can talk to LiteRtLmEngine via the
// LlmInferenceProvider protocol without depending on the bridge directly.

public final class LiteRtLmInferenceProvider: LlmInferenceProvider, @unchecked Sendable {
    private let engine: LiteRtLmEngine
    public init(engine: LiteRtLmEngine) { self.engine = engine }

    public func generateResponse(prompt: String, enableThinking: Bool) async throws -> String {
        var buffer = ""
        for try await token in engine.runInference(prompt: prompt) {
            if token.isFinal { break }
            buffer += token.text
        }
        return buffer
    }

    public func cancel() { engine.stopResponse() }
}
