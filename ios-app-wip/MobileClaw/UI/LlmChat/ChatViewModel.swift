import Foundation
import Observation
import SwiftData

// Mirrors android-app/.../ui/llmchat/LlmChatViewModel.kt for Phase B.
// Holds an in-memory list of ChatMessages backed by a SwiftData Conversation;
// streams assistant tokens via the LiteRtLmEngine bridge; persists each
// completed user/assistant turn to the store so reopening the chat restores
// history.

@MainActor
@Observable
public final class ChatViewModel {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var isStreaming = false
    public private(set) var loadStatus: String?

    public let conversation: Conversation
    public let modelURL: URL
    private let engine: LiteRtLmEngine
    private let store: ConversationStore
    private var streamTask: Task<Void, Never>?

    /// When true, route user messages through the orchestration loop
    /// (Planner → Executor → Evaluator) instead of direct chat. Flip via
    /// MOBILECLAW_AGENTIC=1 launch env var, or expose as a top-bar toggle
    /// in a follow-up.
    public var agenticMode: Bool = ProcessInfo.processInfo.environment["MOBILECLAW_AGENTIC"] == "1"

    public init(conversation: Conversation, store: ConversationStore, engine: LiteRtLmEngine = LiteRtLmEngine()) {
        self.conversation = conversation
        self.modelURL = URL(fileURLWithPath: conversation.modelPath)
        self.store = store
        self.engine = engine
        loadHistoryFromStore()
    }

    public func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        try? store.appendMessage(to: conversation, role: "user", content: trimmed)

        let assistantId = UUID()
        messages.append(ChatMessage(id: assistantId, role: .assistant, text: "", kind: .loading))
        isStreaming = true

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                if loadStatus == nil {
                    self.loadStatus = "Loading model…"
                    try await engine.initialize(config: LlmInitConfig(modelPath: modelURL, maxTokens: 1024))
                    self.loadStatus = "Ready"
                }

                // Agentic mode: drive a Planner → Executor → Evaluator loop
                // and emit the final formatted response as a single bubble.
                // Used by env var MOBILECLAW_AGENTIC=1 today; surfaces as a
                // top-bar toggle in a follow-up commit.
                if self.agenticMode {
                    let provider = LiteRtLmInferenceProvider(engine: self.engine)
                    let tools = SkillRegistry.defaultSet()
                    let controller = OrchestrationController(llm: provider, tools: tools)
                    let final = try await controller.handle(userMessage: trimmed)
                    self.update(id: assistantId, text: final, kind: .text, thought: nil)
                    try? store.appendMessage(to: conversation, role: "assistant", content: final)
                    self.isStreaming = false
                    return
                }

                let stream = engine.runInference(prompt: trimmed)
                var buffer = ""
                var thought = ""
                for try await token in stream {
                    if token.isFinal { break }
                    if !token.text.isEmpty {
                        buffer.append(token.text)
                    }
                    if let t = token.thought, !t.isEmpty {
                        thought.append(t)
                    }
                    if !buffer.isEmpty || !thought.isEmpty {
                        self.update(id: assistantId, text: buffer, kind: .text,
                                    thought: thought.isEmpty ? nil : thought)
                    }
                }
                if buffer.isEmpty {
                    self.update(id: assistantId, text: "(no response)", kind: .text, thought: nil)
                } else {
                    try? store.appendMessage(to: conversation, role: "assistant", content: buffer)
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

    private func loadHistoryFromStore() {
        let stored = store.messages(in: conversation)
        messages = stored.map { msg in
            let role: MessageRole = (msg.role == "assistant") ? .assistant : .user
            return ChatMessage(role: role, text: msg.content, kind: .text, createdAt: msg.createdAt)
        }
    }

    private func update(id: UUID, text: String, kind: ChatMessage.Kind, thought: String? = nil) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
        messages[idx].kind = kind
        if let thought { messages[idx].thought = thought }
    }
}
