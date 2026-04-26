import Foundation
import LiteRtLmBridge

// Phase A step 2: real bridge over the C-API. Replaces the stub from step 1.
// Mirrors android-app/.../ui/llmchat/LlmChatModelHelper.kt's lifecycle
// (initialize → createConversation → sendMessage stream → close).

public enum LiteRtLmError: Error {
    case notInitialized
    case bridge(NSError)
}

public final class LiteRtLmEngine: LlmModelHelper {
    private var engine: LRTLMEngine?
    private var conversation: LRTLMConversation?

    public init() {}

    public func initialize(config: LlmInitConfig) async throws {
        let engine = try LRTLMEngine(modelPath: config.modelPath.path,
                                     backend: .CPU,
                                     maxTokens: Int32(config.maxTokens),
                                     cacheDir: nil)

        let sampler = LRTLMSamplerParams()
        sampler.topK = Int32(config.topK)
        sampler.topP = config.topP
        sampler.temperature = config.temperature

        let conv = try engine.createConversation(withSystemPrompt: config.systemInstruction,
                                                 sampler: sampler)
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
}
