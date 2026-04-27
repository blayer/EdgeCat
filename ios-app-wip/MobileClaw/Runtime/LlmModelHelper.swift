import Foundation

// Mirrors android-app/.../runtime/LlmModelHelper.kt — the protocol the chat layer
// depends on. The Swift implementation is `LiteRtLmEngine.swift`.

/// Compute backend choice — maps directly to LiteRT-LM's `backend_str`
/// argument. `default` skips the parameter so the runtime falls back to
/// whatever the model file declares.
public enum LlmBackend: Sendable, Equatable {
    case `default`
    case cpu
    case gpu
}

/// Sampler algorithm for the next-token decision. TopK is intentionally
/// omitted — the LiteRT-LM runtime returns "Sampler type 1 not implemented
/// yet" for it as of this build.
public enum LlmSamplerType: Sendable, Equatable {
    case topP
    case greedy
}

/// Activation precision — maps to `litert_lm_engine_settings_set_activation_data_type`.
/// `default` skips the call so the model's preferred precision wins.
public enum LlmActivationDtype: Sendable, Equatable {
    case `default`
    case f32
    case f16
    case i16
    case i8
}

/// Mirrors the `litert_lm_set_min_log_level` levels documented in
/// `c/engine.h`.
public enum LlmLogLevel: Int, Sendable {
    case verbose = 0
    case debug   = 1
    case info    = 2
    case warning = 3
    case error   = 4
    case fatal   = 5
    case silent  = 1000
}

/// Full set of knobs the LiteRT-LM C API accepts at engine + session +
/// conversation creation time. Defaults match Gemma 4 metadata + Android's
/// `DEFAULT_ACCELERATORS = [GPU]`. Anything left at its default skips the
/// matching C setter so the runtime falls back to its own internal default.
public struct LlmInitConfig: Sendable {
    // Engine-level
    public var modelPath: URL
    public var backend: LlmBackend
    public var visionBackend: LlmBackend
    public var audioBackend: LlmBackend
    public var maxTokens: Int                            // KV cache cap (0 = unset)
    public var cacheDir: URL?
    public var parallelFileSectionLoading: Bool
    public var activationDataType: LlmActivationDtype
    public var prefillChunkSize: Int                     // CPU dynamic models (0 = unset)
    public var enableSpeculativeDecoding: Bool
    public var logLevel: LlmLogLevel

    // Session/sampler-level
    public var samplerType: LlmSamplerType
    public var topK: Int
    public var topP: Float
    public var temperature: Float
    public var seed: UInt32
    public var maxOutputTokens: Int                      // 0 = unset (per-turn cap)
    public var applyPromptTemplate: Bool

    // Conversation-level
    public var systemInstruction: String?
    public var enableConstrainedDecoding: Bool

    public init(
        modelPath: URL,
        // Default to CPU on iOS — the libLiteRtLm.dylib in
        // LiteRtLmBridge/Vendor/ is built CPU-only (cc_binary +
        // :engine_cpu). Asking for GPU returns NULL from engine_create.
        // Flip back to .gpu when a Metal-enabled dylib ships.
        backend: LlmBackend = .cpu,
        visionBackend: LlmBackend = .default,
        audioBackend: LlmBackend = .default,
        maxTokens: Int = 1024,
        cacheDir: URL? = nil,
        parallelFileSectionLoading: Bool = true,
        activationDataType: LlmActivationDtype = .default,
        prefillChunkSize: Int = 0,
        enableSpeculativeDecoding: Bool = false,
        logLevel: LlmLogLevel = .silent,
        samplerType: LlmSamplerType = .topP,
        topK: Int = 40,
        topP: Float = 0.95,
        temperature: Float = 1.0,
        seed: UInt32 = 0,
        maxOutputTokens: Int = 0,
        applyPromptTemplate: Bool = true,
        systemInstruction: String? = nil,
        enableConstrainedDecoding: Bool = false
    ) {
        self.modelPath = modelPath
        self.backend = backend
        self.visionBackend = visionBackend
        self.audioBackend = audioBackend
        self.maxTokens = maxTokens
        self.cacheDir = cacheDir
        self.parallelFileSectionLoading = parallelFileSectionLoading
        self.activationDataType = activationDataType
        self.prefillChunkSize = prefillChunkSize
        self.enableSpeculativeDecoding = enableSpeculativeDecoding
        self.logLevel = logLevel
        self.samplerType = samplerType
        self.topK = topK
        self.topP = topP
        self.temperature = temperature
        self.seed = seed
        self.maxOutputTokens = maxOutputTokens
        self.applyPromptTemplate = applyPromptTemplate
        self.systemInstruction = systemInstruction
        self.enableConstrainedDecoding = enableConstrainedDecoding
    }
}

public struct ChatToken: Sendable {
    public let text: String
    public let thought: String?
    public let isFinal: Bool
}

public protocol LlmModelHelper: AnyObject {
    func initialize(config: LlmInitConfig) async throws
    func runInference(prompt: String) -> AsyncThrowingStream<ChatToken, Error>
    /// Multimodal variant — pass image data (PNG/JPEG bytes) for Gemma 4 / 3n
    /// vision-capable models. Empty `imageData` is equivalent to plain
    /// runInference(prompt:).
    func runInference(prompt: String, imageData: [Data]) -> AsyncThrowingStream<ChatToken, Error>
    /// Full multimodal variant — text + images + audio. Each audio Data is
    /// expected to be M4A bytes (AVAudioRecorder default).
    func runInference(prompt: String, imageData: [Data], audioData: [Data])
        -> AsyncThrowingStream<ChatToken, Error>
    func resetConversation(systemInstruction: String?) throws
    func stopResponse()
    func cleanUp()
}

public extension LlmModelHelper {
    func runInference(prompt: String, imageData: [Data]) -> AsyncThrowingStream<ChatToken, Error> {
        runInference(prompt: prompt)
    }
    func runInference(prompt: String, imageData: [Data], audioData: [Data])
        -> AsyncThrowingStream<ChatToken, Error> {
        runInference(prompt: prompt, imageData: imageData)
    }
}
