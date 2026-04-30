import Foundation

// Adapter so the orchestration module can talk to LiteRtLmEngine via the
// LlmInferenceProvider protocol without depending on the bridge directly.

public final class LiteRtLmInferenceProvider: LlmInferenceProvider, @unchecked Sendable {
    private let engine: LiteRtLmEngine
    public init(engine: LiteRtLmEngine) { self.engine = engine }

    public func generateResponse(prompt: String, enableThinking: Bool) async throws -> String {
        // Use generateOnce so the orchestrator's planner / evaluator /
        // formatter prompts run against a fresh conversation each time.
        // Reusing the live chat conversation appends every phase as a new
        // user turn and the model returns nonsense (or in our case
        // LiteRtLmError 0). Mirrors Android's generatePlanningResponse.
        try await engine.generateOnce(prompt: prompt)
    }

    public func cancel() { engine.stopResponse() }
}
