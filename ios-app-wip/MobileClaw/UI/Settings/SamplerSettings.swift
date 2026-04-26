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
    // Agent-mode knobs — mirror android-app/.../ConfigDialog.kt agent tab.
    public static let agentMaxLoopsKey         = "MOBILECLAW_AGENT_MAX_LOOPS"
    public static let agentMaxRepairKey        = "MOBILECLAW_AGENT_MAX_REPAIR"
    public static let agentSkillTimeoutKey     = "MOBILECLAW_AGENT_SKILL_TIMEOUT"
    public static let agentThinkingModeKey     = "MOBILECLAW_AGENT_THINKING_MODE"
    public static let agentHistoryWindowKey    = "MOBILECLAW_AGENT_HISTORY_WINDOW"
    public static let agentDefaults = (maxLoops: 3, maxRepair: 2, skillTimeoutSecs: 60,
                                       thinkingMode: 0, historyWindow: 6)

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
            systemPrompt: d.string(forKey: systemPromptKey) ?? "",
            agentMaxLoops: d.object(forKey: agentMaxLoopsKey) as? Int ?? agentDefaults.maxLoops,
            agentMaxRepair: d.object(forKey: agentMaxRepairKey) as? Int ?? agentDefaults.maxRepair,
            agentSkillTimeoutSecs: d.object(forKey: agentSkillTimeoutKey) as? Int ?? agentDefaults.skillTimeoutSecs,
            agentThinkingMode: d.object(forKey: agentThinkingModeKey) as? Int ?? agentDefaults.thinkingMode,
            agentHistoryWindow: d.object(forKey: agentHistoryWindowKey) as? Int ?? agentDefaults.historyWindow
        )
    }

    public struct Snapshot: Sendable {
        public let topK: Int
        public let topP: Double
        public let temperature: Double
        public let maxTokens: Int
        public let systemPrompt: String
        public let agentMaxLoops: Int
        public let agentMaxRepair: Int
        public let agentSkillTimeoutSecs: Int
        public let agentThinkingMode: Int
        public let agentHistoryWindow: Int
    }
}
