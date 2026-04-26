import Foundation
import Observation

// Mirrors android-app/.../ui/llmchat/LlmChatViewModel.kt for Phase A (text only).
// Lazily initializes the LiteRtLmEngine on first send; streams assistant tokens via
// AsyncThrowingStream from the bridge.

@MainActor
@Observable
public final class ChatViewModel {
    public private(set) var messages: [Message] = []
    public private(set) var isStreaming = false
    public private(set) var loadStatus: String?

    public let modelURL: URL
    private let engine: LiteRtLmEngine
    private var streamTask: Task<Void, Never>?

    public init(modelURL: URL, engine: LiteRtLmEngine = LiteRtLmEngine()) {
        self.modelURL = modelURL
        self.engine = engine
    }

    public func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(Message(role: .user, text: trimmed))
        let assistantId = UUID()
        messages.append(Message(id: assistantId, role: .assistant, text: "", kind: .loading))
        isStreaming = true

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                if loadStatus == nil {
                    self.loadStatus = "Loading model…"
                    try await engine.initialize(config: LlmInitConfig(modelPath: modelURL))
                    self.loadStatus = "Ready"
                }
                let stream = engine.runInference(prompt: trimmed)
                var buffer = ""
                for try await token in stream {
                    if token.isFinal { break }
                    if !token.text.isEmpty {
                        buffer.append(token.text)
                        self.update(id: assistantId, text: buffer, kind: .text)
                    }
                }
                if buffer.isEmpty {
                    self.update(id: assistantId, text: "(no response)", kind: .text)
                }
            } catch {
                self.update(id: assistantId, text: "Error: \(error.localizedDescription)", kind: .error)
            }
            self.isStreaming = false
        }
    }

    public func stop() {
        engine.stopResponse()
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func update(id: UUID, text: String, kind: Message.Kind) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
        messages[idx].kind = kind
    }
}
