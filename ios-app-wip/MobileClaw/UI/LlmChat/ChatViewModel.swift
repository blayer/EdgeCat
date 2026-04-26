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
    /// (Planner → Executor → Evaluator) instead of direct chat. Sources, in
    /// priority order: launch env var MOBILECLAW_AGENTIC=1, then the
    /// SettingsView toggle backed by UserDefaults.
    public var agenticMode: Bool {
        if ProcessInfo.processInfo.environment["MOBILECLAW_AGENTIC"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "MOBILECLAW_AGENTIC_MODE")
    }

    public init(conversation: Conversation, store: ConversationStore, engine: LiteRtLmEngine = LiteRtLmEngine()) {
        self.conversation = conversation
        self.modelURL = URL(fileURLWithPath: conversation.modelPath)
        self.store = store
        self.engine = engine
        loadHistoryFromStore()
    }

    public func send(_ prompt: String, imageData: [Data] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !imageData.isEmpty), !isStreaming else { return }

        let userText = trimmed.isEmpty && !imageData.isEmpty ? "(image)" : trimmed
        messages.append(ChatMessage(role: .user, text: userText, images: imageData))
        try? store.appendMessage(to: conversation, role: "user", content: userText, images: imageData)

        let assistantId = UUID()
        messages.append(ChatMessage(id: assistantId, role: .assistant, text: "", kind: .loading))
        isStreaming = true
        let started = DispatchTime.now()

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                if loadStatus == nil {
                    self.loadStatus = "Loading model…"
                    let s = SamplerSettings.current()
                    try await engine.initialize(config: LlmInitConfig(
                        modelPath: modelURL,
                        maxTokens: s.maxTokens,
                        topK: s.topK,
                        topP: Float(s.topP),
                        temperature: Float(s.temperature),
                        systemInstruction: s.systemPrompt.isEmpty ? nil : s.systemPrompt
                    ))
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

                let stream = engine.runInference(prompt: trimmed, imageData: imageData)
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
            let elapsed = Int64(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            self.setLatency(id: assistantId, ms: elapsed)
            self.isStreaming = false
        }
    }

    /// Re-sends a previous user message verbatim — mirrors Android's
    /// "Run again" affordance below user bubbles.
    public func runAgain(_ message: ChatMessage) {
        guard message.role == .user else { return }
        send(message.text)
    }

    public func stop() {
        engine.stopResponse()
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    /// Mirrors android-app/.../LlmChatModelHelper.resetConversation — clears
    /// the LLM's KV cache + the in-memory chat thread (the persisted messages
    /// stay; the user can revisit them as past turns).
    public func resetSession() {
        stop()
        try? engine.resetConversation(systemInstruction: nil)
        messages.removeAll()
        loadStatus = nil
    }

    private func loadHistoryFromStore() {
        let stored = store.messages(in: conversation)
        messages = stored.map { msg in
            let role: MessageRole = (msg.role == "assistant") ? .assistant : .user
            return ChatMessage(role: role, text: msg.content, kind: .text,
                               images: msg.imageBlobs ?? [],
                               createdAt: msg.createdAt)
        }
    }

    private func update(id: UUID, text: String, kind: ChatMessage.Kind, thought: String? = nil) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
        messages[idx].kind = kind
        if let thought { messages[idx].thought = thought }
    }

    private func setLatency(id: UUID, ms: Int64) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].latencyMs = ms
    }
}
