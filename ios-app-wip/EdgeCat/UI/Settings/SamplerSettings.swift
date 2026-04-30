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
    public static let agenticKey       = "EDGECAT_AGENTIC_MODE"

    /// Default system prompt applied to the LiteRT-LM conversation when the
    /// user hasn't set one in Settings. Mirrors android-app's
    /// `AgentChatTask.defaultSystemPrompt` in shape — drops the `___SKILLS___`
    /// placeholder because iOS's planner builds the skill catalog itself
    /// for the agentic path, and chat-mode doesn't have tool-calling
    /// hooked up. Keeps the "output only the final result" guidance which
    /// is the part that actually changes Gemma's behavior on plain chat.
    public static let defaultSystemPrompt: String = """
    You are a helpful AI assistant running on the user's iPhone.
    Answer concisely and accurately. If you don't know something, say so \
    rather than guessing. When asked to perform a task that requires the \
    device or external information, the host app may route the request \
    through a skill — answer directly only when no skill is needed.
    Output ONLY the final result — no intermediate thoughts or reasoning.
    """

    // MARK: - Sampler / model
    public static let topKKey          = "EDGECAT_SAMPLER_TOPK"
    public static let topPKey          = "EDGECAT_SAMPLER_TOPP"
    public static let temperatureKey   = "EDGECAT_SAMPLER_TEMPERATURE"
    public static let maxTokensKey     = "EDGECAT_SAMPLER_MAX_TOKENS"
    public static let systemPromptKey  = "EDGECAT_SYSTEM_PROMPT"
    /// "cpu" | "gpu" — empty string treated as "default" (let model pick).
    public static let acceleratorKey         = "EDGECAT_ACCELERATOR"
    /// "cpu" | "gpu" | "" — empty = follow `acceleratorKey`.
    public static let visionAcceleratorKey   = "EDGECAT_VISION_ACCELERATOR"
    /// "cpu" | "gpu" | "" — empty = follow `acceleratorKey`.
    public static let audioAcceleratorKey    = "EDGECAT_AUDIO_ACCELERATOR"
    /// 0 = TopP, 1 = Greedy. Matches LRTLMSamplerType.
    public static let samplerTypeKey         = "EDGECAT_SAMPLER_TYPE"
    public static let seedKey                = "EDGECAT_SAMPLER_SEED"
    /// Per-turn output cap, separate from the KV-cache sized `maxTokens`.
    /// 0 = unset → no per-turn cap.
    public static let maxOutputTokensKey     = "EDGECAT_MAX_OUTPUT_TOKENS"
    public static let applyPromptTemplateKey = "EDGECAT_APPLY_PROMPT_TEMPLATE"
    public static let enableConstrainedDecodingKey = "EDGECAT_CONSTRAINED_DECODING"
    public static let parallelFileLoadingKey = "EDGECAT_PARALLEL_FILE_LOADING"
    /// -1 = default (model decides), 0 = F32, 1 = F16, 2 = I16, 3 = I8.
    public static let activationDtypeKey     = "EDGECAT_ACTIVATION_DTYPE"
    /// 0 = unset; only honored on CPU dynamic models.
    public static let prefillChunkSizeKey    = "EDGECAT_PREFILL_CHUNK_SIZE"
    public static let speculativeDecodingKey = "EDGECAT_SPECULATIVE_DECODING"
    /// LiteRT-LM `min_log_level` — 0=verbose…5=fatal, 1000=silent.
    public static let debugLogLevelKey       = "EDGECAT_DEBUG_LOG_LEVEL"

    // MARK: - Agent-mode knobs (port of android-app/.../ConfigDialog.kt agent tab)
    public static let agentMaxLoopsKey         = "EDGECAT_AGENT_MAX_LOOPS"
    public static let agentMaxRepairKey        = "EDGECAT_AGENT_MAX_REPAIR"
    public static let agentSkillTimeoutKey     = "EDGECAT_AGENT_SKILL_TIMEOUT"
    public static let agentThinkingModeKey     = "EDGECAT_AGENT_THINKING_MODE"
    public static let agentHistoryWindowKey    = "EDGECAT_AGENT_HISTORY_WINDOW"
    public static let agentTracesKey           = "EDGECAT_AGENT_TRACES"
    public static let userPortraitKey          = "EDGECAT_USER_PORTRAIT"
    public static let agentDefaults = (maxLoops: 3, maxRepair: 2, skillTimeoutSecs: 60,
                                       thinkingMode: 0, historyWindow: 6,
                                       traces: true)

    /// Defaults match the Gemma 4 E2B metadata block (TOP_P, k=1, p=0.95,
    /// temperature=1). max_tokens raised to 4096 — Android's
    /// DEFAULT_MAX_TOKEN is 1024 too, but its UI slider clamps the
    /// effective minimum to 2000, and agentic-mode planner prompts on
    /// iOS routinely run 1100+ tokens (skill catalog + date hint +
    /// memory + conversation context), which trips
    /// "INVALID_ARGUMENT: Input token ids are too long" on a 1024-token
    /// KV cache. 4096 leaves headroom for a multi-turn agentic chat
    /// without paying memory we don't need; users can still bump it
    /// further in Settings → Model configs.
    public static let defaults = (topK: 40, topP: 0.95, temperature: 1.0, maxTokens: 4096)

    /// Model-knob defaults. Strings are used for accelerator so an empty
    /// value can encode "follow parent".
    public static let modelDefaults = (
        // CPU is the safe default. GPU support IS shipped (the
        // libLiteRtMetalAccelerator.dylib xcframework is embedded), but
        // the iOS Simulator's Metal feature set tops out at a texture-
        // binding argument limit that LiteRT-LM's Gemma kernels exceed
        // (newComputePipelineStateWithFunction: "argument index 31 >
        // 30"). Real iPhone devices clear this limit, but defaulting to
        // GPU would make every sim-based dev hit the error on first
        // model load. Users can still pick GPU via Settings → Model
        // configs → Accelerator on a real device.
        accelerator: "cpu",
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
