import Foundation
import LiteRtLmBridge

// Phase A step 2: real bridge over the C-API. Replaces the stub from step 1.
// Mirrors android-app/.../ui/llmchat/LlmChatModelHelper.kt's lifecycle
// (initialize → createConversation → sendMessage stream → close).

public enum LiteRtLmError: Error, LocalizedError {
    case notInitialized
    case bridge(NSError)

    /// Surface the wrapped NSError's `localizedDescription` so the chat UI
    /// shows a useful error string instead of the opaque
    /// "(MobileClaw.LiteRtLmError error 0.)" Swift prints by default for
    /// associated-value enums.
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "LiteRT-LM engine not initialized"
        case .bridge(let underlying):
            return underlying.localizedDescription
        }
    }
}

public final class LiteRtLmEngine: LlmModelHelper {
    private var engine: LRTLMEngine?
    private var conversation: LRTLMConversation?

    public init() {}

    public func initialize(config: LlmInitConfig) async throws {
        let settings = LRTLMEngineSettings(modelPath: config.modelPath.path)
        settings.backend            = config.backend.bridgeValue
        settings.visionBackend      = config.visionBackend.bridgeValue
        settings.audioBackend       = config.audioBackend.bridgeValue
        settings.maxTokens          = Int32(config.maxTokens)
        settings.cacheDir           = config.cacheDir?.path
        settings.parallelFileSectionLoading = config.parallelFileSectionLoading
        settings.activationDataType = config.activationDataType.bridgeValue
        settings.prefillChunkSize   = Int32(config.prefillChunkSize)
        settings.enableSpeculativeDecoding = config.enableSpeculativeDecoding
        settings.logLevel           = LRTLMLogLevel(rawValue: config.logLevel.rawValue) ?? .silent

        let engine = try LRTLMEngine(settings: settings)

        let sampler = LRTLMSamplerParams()
        sampler.type        = (config.samplerType == .greedy) ? .greedy : .topP
        sampler.topK        = Int32(config.topK)
        sampler.topP        = config.topP
        sampler.temperature = config.temperature
        sampler.seed        = Int32(bitPattern: config.seed)

        let conv = try engine.createConversation(
            withSystemPrompt: config.systemInstruction,
            sampler: sampler,
            applyPromptTemplate: config.applyPromptTemplate,
            enableConstrainedDecoding: config.enableConstrainedDecoding,
            maxOutputTokens: Int32(config.maxOutputTokens))
        self.engine = engine
        self.conversation = conv
    }

    public func runInference(prompt: String) -> AsyncThrowingStream<ChatToken, Error> {
        runInference(prompt: prompt, imageData: [], audioData: [])
    }

    public func runInference(prompt: String, imageData: [Data]) -> AsyncThrowingStream<ChatToken, Error> {
        runInference(prompt: prompt, imageData: imageData, audioData: [])
    }

    public func runInference(prompt: String, imageData: [Data], audioData: [Data])
        -> AsyncThrowingStream<ChatToken, Error> {
        AsyncThrowingStream { continuation in
            guard let conversation else {
                continuation.finish(throwing: LiteRtLmError.notInitialized)
                return
            }
            // Write images + audio to NSTemporaryDirectory; the bridge passes
            // paths to the C API (path form is more efficient than base64 per
            // runtime/conversation/model_data_processor/data_utils.h).
            var tempPaths: [String] = []
            var imagePaths: [String] = []
            for data in imageData {
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("mc-img-\(UUID().uuidString).png")
                if (try? data.write(to: url)) != nil {
                    imagePaths.append(url.path); tempPaths.append(url.path)
                }
            }
            var audioPaths: [String] = []
            for data in audioData {
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("mc-aud-\(UUID().uuidString).m4a")
                if (try? data.write(to: url)) != nil {
                    audioPaths.append(url.path); tempPaths.append(url.path)
                }
            }
            conversation.sendMessage(prompt,
                                     imagePaths: imagePaths.isEmpty ? nil : imagePaths,
                                     audioPaths: audioPaths.isEmpty ? nil : audioPaths,
                                     onToken: { chunk, thought in
                continuation.yield(ChatToken(text: chunk, thought: thought, isFinal: false))
            },
                                     onDone: { error in
                for p in tempPaths { try? FileManager.default.removeItem(atPath: p) }
                if let error {
                    continuation.finish(throwing: LiteRtLmError.bridge(error as NSError))
                } else {
                    continuation.yield(ChatToken(text: "", thought: nil, isFinal: true))
                    continuation.finish()
                }
            })
            continuation.onTermination = { @Sendable _ in
                conversation.cancel()
            }
        }
    }

    /// Stateless one-shot inference for the orchestration layer.
    ///
    /// Runs against a *separate* tool-free scratch conversation so the
    /// chat conversation's KV cache (`self.conversation`) is never
    /// touched. Each orchestration phase (planner, executor, evaluator,
    /// formatter) gets its own fresh scratch — phases must not see one
    /// another's history (the formatter's `<msg>` few-shot prompt would
    /// otherwise leak into the next planner call). Crucially, the chat
    /// conversation survives an agentic turn untouched, so post-task
    /// follow-ups still have the user's prior chat history in cache.
    public func generateOnce(prompt: String) async throws -> String {
        guard let engine else { throw LiteRtLmError.notInitialized }

        let sampler = LRTLMSamplerParams()
        sampler.type = .topP
        sampler.topK = 40
        sampler.topP = 0.95
        sampler.temperature = 1.0
        sampler.seed = 0

        let scratch = try engine.createConversation(
            withSystemPrompt: nil,
            sampler: sampler,
            applyPromptTemplate: true,
            enableConstrainedDecoding: false,
            maxOutputTokens: 0)
        defer { scratch.close() }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            // Serialize to a single resume — onToken can race with onDone if
            // the C-side closes the stream after a partial chunk.
            let didResume = NSLock()
            var resumed = false
            var buffer = ""
            scratch.sendMessage(prompt,
                                imagePaths: nil,
                                audioPaths: nil,
                                onToken: { chunk, _ in
                buffer += chunk
            }, onDone: { error in
                didResume.lock()
                defer { didResume.unlock() }
                guard !resumed else { return }
                resumed = true
                if let error {
                    continuation.resume(throwing: LiteRtLmError.bridge(error as NSError))
                } else {
                    continuation.resume(returning: buffer)
                }
            })
        }
    }

    public func resetConversation(systemInstruction: String?) throws {
        guard let engine else { throw LiteRtLmError.notInitialized }
        conversation?.close()
        conversation = nil

        let sampler = LRTLMSamplerParams()
        sampler.topK = 40
        sampler.topP = 0.95
        sampler.temperature = 1.0
        conversation = try engine.createConversation(withSystemPrompt: systemInstruction, sampler: sampler)
    }

    public func stopResponse() {
        conversation?.cancel()
    }

    public func cleanUp() {
        conversation?.close(); conversation = nil
        engine?.close(); engine = nil
    }

    // Swift's ARC release order across stored properties isn't part of the
    // language contract. Force the right teardown order explicitly so we
    // never delete the C-side engine while a conversation still references
    // it — that combination produced the back-from-chat crash.
    deinit {
        cleanUp()
    }
}

// MARK: - Swift → bridge enum mappings

private extension LlmBackend {
    var bridgeValue: LRTLMBackend {
        switch self {
        case .cpu:     return .CPU
        case .gpu:     return .GPU
        case .default: return .default
        }
    }
}

private extension LlmActivationDtype {
    var bridgeValue: LRTLMActivationDtype {
        switch self {
        case .f32:     return .F32
        case .f16:     return .F16
        case .i16:     return .I16
        case .i8:      return .I8
        case .default: return .default
        }
    }
}
