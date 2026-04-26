import Foundation

// UserDefaults-backed model + agent settings, mirrors android-app's per-model
// ConfigKeys persistence (DataStore). The 13 model knobs added here cover
// every relevant LiteRT-LM C API setter — see the audit in
// /Users/nali/.claude/plans/i-want-to-implement-dynamic-lark.md and the
// matching doc-comments on `LRTLMEngineSettings` in LiteRtLmBridge.h.
//
// NPU note: Android's `Accelerator` enum has CPU / GPU / NPU. iOS LiteRT-LM
// prebuilts ship the Metal accelerator (GPU) only — there is no NPU dylib —
// so iOS exposes CPU + GPU. The `acceleratorKey` therefore stores "cpu" or
// "gpu" only. Default matches Android's `DEFAULT_ACCELERATORS = listOf(GPU)`.

public enum SamplerSettings {
    public static let agenticKey       = "MOBILECLAW_AGENTIC_MODE"

    // MARK: - Sampler / model
    public static let topKKey          = "MOBILECLAW_SAMPLER_TOPK"
    public static let topPKey          = "MOBILECLAW_SAMPLER_TOPP"
    public static let temperatureKey   = "MOBILECLAW_SAMPLER_TEMPERATURE"
    public static let maxTokensKey     = "MOBILECLAW_SAMPLER_MAX_TOKENS"
    public static let systemPromptKey  = "MOBILECLAW_SYSTEM_PROMPT"
    /// "cpu" | "gpu" — empty string treated as "default" (let model pick).
    public static let acceleratorKey         = "MOBILECLAW_ACCELERATOR"
    /// "cpu" | "gpu" | "" — empty = follow `acceleratorKey`.
    public static let visionAcceleratorKey   = "MOBILECLAW_VISION_ACCELERATOR"
    /// "cpu" | "gpu" | "" — empty = follow `acceleratorKey`.
    public static let audioAcceleratorKey    = "MOBILECLAW_AUDIO_ACCELERATOR"
    /// 0 = TopP, 1 = Greedy. Matches LRTLMSamplerType.
    public static let samplerTypeKey         = "MOBILECLAW_SAMPLER_TYPE"
    public static let seedKey                = "MOBILECLAW_SAMPLER_SEED"
    /// Per-turn output cap, separate from the KV-cache sized `maxTokens`.
    /// 0 = unset → no per-turn cap.
    public static let maxOutputTokensKey     = "MOBILECLAW_MAX_OUTPUT_TOKENS"
    public static let applyPromptTemplateKey = "MOBILECLAW_APPLY_PROMPT_TEMPLATE"
    public static let enableConstrainedDecodingKey = "MOBILECLAW_CONSTRAINED_DECODING"
    public static let parallelFileLoadingKey = "MOBILECLAW_PARALLEL_FILE_LOADING"
    /// -1 = default (model decides), 0 = F32, 1 = F16, 2 = I16, 3 = I8.
    public static let activationDtypeKey     = "MOBILECLAW_ACTIVATION_DTYPE"
    /// 0 = unset; only honored on CPU dynamic models.
    public static let prefillChunkSizeKey    = "MOBILECLAW_PREFILL_CHUNK_SIZE"
    public static let speculativeDecodingKey = "MOBILECLAW_SPECULATIVE_DECODING"
    /// LiteRT-LM `min_log_level` — 0=verbose…5=fatal, 1000=silent.
    public static let debugLogLevelKey       = "MOBILECLAW_DEBUG_LOG_LEVEL"

    // MARK: - Agent-mode knobs (port of android-app/.../ConfigDialog.kt agent tab)
    public static let agentMaxLoopsKey         = "MOBILECLAW_AGENT_MAX_LOOPS"
    public static let agentMaxRepairKey        = "MOBILECLAW_AGENT_MAX_REPAIR"
    public static let agentSkillTimeoutKey     = "MOBILECLAW_AGENT_SKILL_TIMEOUT"
    public static let agentThinkingModeKey     = "MOBILECLAW_AGENT_THINKING_MODE"
    public static let agentHistoryWindowKey    = "MOBILECLAW_AGENT_HISTORY_WINDOW"
    public static let agentTracesKey           = "MOBILECLAW_AGENT_TRACES"
    public static let userPortraitKey          = "MOBILECLAW_USER_PORTRAIT"
    public static let agentDefaults = (maxLoops: 3, maxRepair: 2, skillTimeoutSecs: 60,
                                       thinkingMode: 0, historyWindow: 6,
                                       traces: true)

    /// Defaults match the Gemma 4 E2B metadata block (TOP_P, k=1, p=0.95,
    /// temperature=1) plus the prefill_1024 signature for max_tokens.
    public static let defaults = (topK: 40, topP: 0.95, temperature: 1.0, maxTokens: 1024)

    /// Model-knob defaults. Strings are used for accelerator so an empty
    /// value can encode "follow parent".
    public static let modelDefaults = (
        accelerator: "gpu",                      // matches Android DEFAULT_ACCELERATORS
        visionAccelerator: "",                   // empty = follow `accelerator`
        audioAccelerator: "",                    // empty = follow `accelerator`
        samplerType: 0,                          // 0=TopP, 1=Greedy
        seed: 0,
        maxOutputTokens: 0,                      // 0 = no per-turn cap
        applyPromptTemplate: true,
        enableConstrainedDecoding: false,
        parallelFileLoading: true,
        activationDtype: -1,                     // -1 = model default
        prefillChunkSize: 0,
        speculativeDecoding: false,
        debugLogLevel: 1000                      // silent
    )

    public static func current() -> Snapshot {
        let d = UserDefaults.standard
        return Snapshot(
            topK: d.object(forKey: topKKey) as? Int ?? defaults.topK,
            topP: d.object(forKey: topPKey) as? Double ?? defaults.topP,
            temperature: d.object(forKey: temperatureKey) as? Double ?? defaults.temperature,
            maxTokens: d.object(forKey: maxTokensKey) as? Int ?? defaults.maxTokens,
            systemPrompt: d.string(forKey: systemPromptKey) ?? "",
            accelerator: d.string(forKey: acceleratorKey) ?? modelDefaults.accelerator,
            visionAccelerator: d.string(forKey: visionAcceleratorKey) ?? modelDefaults.visionAccelerator,
            audioAccelerator: d.string(forKey: audioAcceleratorKey) ?? modelDefaults.audioAccelerator,
            samplerType: d.object(forKey: samplerTypeKey) as? Int ?? modelDefaults.samplerType,
            seed: d.object(forKey: seedKey) as? Int ?? modelDefaults.seed,
            maxOutputTokens: d.object(forKey: maxOutputTokensKey) as? Int ?? modelDefaults.maxOutputTokens,
            applyPromptTemplate: d.object(forKey: applyPromptTemplateKey) as? Bool ?? modelDefaults.applyPromptTemplate,
            enableConstrainedDecoding: d.object(forKey: enableConstrainedDecodingKey) as? Bool ?? modelDefaults.enableConstrainedDecoding,
            parallelFileLoading: d.object(forKey: parallelFileLoadingKey) as? Bool ?? modelDefaults.parallelFileLoading,
            activationDtype: d.object(forKey: activationDtypeKey) as? Int ?? modelDefaults.activationDtype,
            prefillChunkSize: d.object(forKey: prefillChunkSizeKey) as? Int ?? modelDefaults.prefillChunkSize,
            speculativeDecoding: d.object(forKey: speculativeDecodingKey) as? Bool ?? modelDefaults.speculativeDecoding,
            debugLogLevel: d.object(forKey: debugLogLevelKey) as? Int ?? modelDefaults.debugLogLevel,
            agentMaxLoops: d.object(forKey: agentMaxLoopsKey) as? Int ?? agentDefaults.maxLoops,
            agentMaxRepair: d.object(forKey: agentMaxRepairKey) as? Int ?? agentDefaults.maxRepair,
            agentSkillTimeoutSecs: d.object(forKey: agentSkillTimeoutKey) as? Int ?? agentDefaults.skillTimeoutSecs,
            agentThinkingMode: d.object(forKey: agentThinkingModeKey) as? Int ?? agentDefaults.thinkingMode,
            agentHistoryWindow: d.object(forKey: agentHistoryWindowKey) as? Int ?? agentDefaults.historyWindow,
            agentTraces: d.object(forKey: agentTracesKey) as? Bool ?? agentDefaults.traces,
            userPortrait: d.string(forKey: userPortraitKey) ?? ""
        )
    }

    public struct Snapshot: Sendable {
        public let topK: Int
        public let topP: Double
        public let temperature: Double
        public let maxTokens: Int
        public let systemPrompt: String
        public let accelerator: String
        public let visionAccelerator: String
        public let audioAccelerator: String
        public let samplerType: Int
        public let seed: Int
        public let maxOutputTokens: Int
        public let applyPromptTemplate: Bool
        public let enableConstrainedDecoding: Bool
        public let parallelFileLoading: Bool
        public let activationDtype: Int
        public let prefillChunkSize: Int
        public let speculativeDecoding: Bool
        public let debugLogLevel: Int
        public let agentMaxLoops: Int
        public let agentMaxRepair: Int
        public let agentSkillTimeoutSecs: Int
        public let agentThinkingMode: Int
        public let agentHistoryWindow: Int
        public let agentTraces: Bool
        public let userPortrait: String
    }
}
