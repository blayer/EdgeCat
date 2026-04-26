import Foundation

// Mirrors android-app/.../runtime/LlmModelHelper.kt — the protocol the chat layer
// depends on. The Swift implementation (LiteRtLmEngine.swift) lands in Phase A step 2.
//
// Kept narrow on purpose: only the methods Phase A needs. Multimodal + tool-use
// surfaces are added in later phases as we port the corresponding Android code.

public struct LlmInitConfig {
    public var modelPath: URL
    public var maxTokens: Int
    public var topK: Int
    public var topP: Float
    public var temperature: Float
    public var systemInstruction: String?

    public init(
        modelPath: URL,
        maxTokens: Int = 1024,
        topK: Int = 40,
        topP: Float = 0.95,
        temperature: Float = 1.0,
        systemInstruction: String? = nil
    ) {
        self.modelPath = modelPath
        self.maxTokens = maxTokens
        self.topK = topK
        self.topP = topP
        self.temperature = temperature
        self.systemInstruction = systemInstruction
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
    func resetConversation(systemInstruction: String?) throws
    func stopResponse()
    func cleanUp()
}
