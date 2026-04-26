import Foundation

// UserDefaults-backed sampler settings, mirrors android-app's per-model
// ConfigKeys persistence (DataStore) for the values that matter at chat
// session start. Per-conversation overrides land later when the
// agent-settings tab is ported.

public enum SamplerSettings {
    public static let agenticKey       = "MOBILECLAW_AGENTIC_MODE"
    public static let topKKey          = "MOBILECLAW_SAMPLER_TOPK"
    public static let topPKey          = "MOBILECLAW_SAMPLER_TOPP"
    public static let temperatureKey   = "MOBILECLAW_SAMPLER_TEMPERATURE"
    public static let maxTokensKey     = "MOBILECLAW_SAMPLER_MAX_TOKENS"
    public static let systemPromptKey  = "MOBILECLAW_SYSTEM_PROMPT"

    /// Defaults match the Gemma 4 E2B metadata block (TOP_P, k=1, p=0.95,
    /// temperature=1) plus the prefill_1024 signature for max_tokens.
    public static let defaults = (topK: 40, topP: 0.95, temperature: 1.0, maxTokens: 1024)

    public static func current() -> Snapshot {
        let d = UserDefaults.standard
        return Snapshot(
            topK: d.object(forKey: topKKey) as? Int ?? defaults.topK,
            topP: d.object(forKey: topPKey) as? Double ?? defaults.topP,
            temperature: d.object(forKey: temperatureKey) as? Double ?? defaults.temperature,
            maxTokens: d.object(forKey: maxTokensKey) as? Int ?? defaults.maxTokens,
            systemPrompt: d.string(forKey: systemPromptKey) ?? ""
        )
    }

    public struct Snapshot: Sendable {
        public let topK: Int
        public let topP: Double
        public let temperature: Double
        public let maxTokens: Int
        public let systemPrompt: String
    }
}
