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

    public func send(_ prompt: String, imageData: [Data] = [], audioData: [Data] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !imageData.isEmpty || !audioData.isEmpty
        guard !trimmed.isEmpty || hasAttachments, !isStreaming else { return }

        let userText: String
        if !trimmed.isEmpty { userText = trimmed }
        else if !imageData.isEmpty { userText = "(image)" }
        else { userText = "(audio)" }
        messages.append(ChatMessage(role: .user, text: userText,
                                    images: imageData, audio: audioData))
        try? store.appendMessage(to: conversation, role: "user", content: userText,
                                 images: imageData, audio: audioData)

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
                    // Per-conversation override wins over the global setting.
                    let prompt = conversation.systemPromptOverride
                        ?? (s.systemPrompt.isEmpty ? nil : s.systemPrompt)
                    let visionDefault = LlmBackend.parse(s.visionAccelerator)
                        ?? LlmBackend.parse(s.accelerator)
                        ?? .gpu
                    let audioDefault = LlmBackend.parse(s.audioAccelerator)
                        ?? LlmBackend.parse(s.accelerator)
                        ?? .gpu
                    try await engine.initialize(config: LlmInitConfig(
                        modelPath: modelURL,
                        backend: LlmBackend.parse(s.accelerator) ?? .gpu,
                        visionBackend: visionDefault,
                        audioBackend: audioDefault,
                        maxTokens: s.maxTokens,
                        cacheDir: Self.derivedCacheDir(for: modelURL),
                        parallelFileSectionLoading: s.parallelFileLoading,
                        activationDataType: LlmActivationDtype.from(rawValue: s.activationDtype),
                        prefillChunkSize: s.prefillChunkSize,
                        enableSpeculativeDecoding: s.speculativeDecoding,
                        logLevel: LlmLogLevel(rawValue: s.debugLogLevel) ?? .silent,
                        samplerType: s.samplerType == 1 ? .greedy : .topP,
                        topK: s.topK,
                        topP: Float(s.topP),
                        temperature: Float(s.temperature),
                        seed: UInt32(bitPattern: Int32(truncatingIfNeeded: s.seed)),
                        maxOutputTokens: s.maxOutputTokens,
                        applyPromptTemplate: s.applyPromptTemplate,
                        systemInstruction: prompt,
                        enableConstrainedDecoding: s.enableConstrainedDecoding
                    ))
                    self.loadStatus = "Ready"
                }

                // Agentic mode: drive a Planner → Executor → Evaluator loop
                // and emit the final formatted response as a single bubble.
                // Used by env var MOBILECLAW_AGENTIC=1 today; surfaces as a
                // top-bar toggle in a follow-up commit.
                // Agentic-mode classifier: regex heuristics decide whether
                // the user is asking the device to do something or just
                // chatting. Greetings / small talk fall through to the plain
                // LLM path so we don't burn 3 plan/execute/evaluate cycles
                // on "hi". Mirrors android-app's `Planner.classifyIntent`.
                if self.agenticMode {
                    let hasPrior = self.messages.contains { $0.role == .assistant }
                    let intent = IntentClassifier.classify(trimmed, hasPriorAssistantTurn: hasPrior)
                    if intent == .task {
                        let s = SamplerSettings.current()
                        let provider = LiteRtLmInferenceProvider(engine: self.engine)
                        let tools = SkillRegistry.defaultSet()
                        let policy = ThinkingPolicy(mode: ThinkingMode.from(s.agentThinkingMode))
                        // Real memory bridge — same SwiftData ModelContext
                        // the chat history uses. The repository instance is
                        // cheap (just wraps the context) so we make it per-
                        // run rather than caching it on the view model.
                        let memoryRepo = SwiftDataMemoryRepository(context: store.context)
                        let memoryProvider: MemoryProvider = memoryRepo.asMemoryProvider
                        // Conversation context = last `historyWindow` turns
                        // formatted as "role: text". Snapshot the messages
                        // here so the orchestrator's @Sendable closure
                        // doesn't need to hop back to the MainActor during
                        // a planner run. Bounded to `historyWindow * 2`
                        // entries since the renderer trims further.
                        let historyWindow = s.agentHistoryWindow
                        let snapshot = ChatViewModel.recentHistory(self.messages,
                                                                    take: historyWindow)
                        let conversationContextProvider: @Sendable () -> String = { snapshot }
                        let controller = OrchestrationController(
                            llm: provider, tools: tools, policy: policy,
                            maxIterations: s.agentMaxLoops,
                            maxRepair: s.agentMaxRepair,
                            skillTimeoutSecs: s.agentSkillTimeoutSecs,
                            historyWindow: historyWindow,
                            userPortrait: s.userPortrait,
                            tracesEnabled: s.agentTraces,
                            memory: memoryProvider,
                            conversationContext: conversationContextProvider)
                        let final = try await controller.handle(userMessage: trimmed)
                        self.update(id: assistantId, text: final, kind: .text, thought: nil)
                        try? store.appendMessage(to: conversation, role: "assistant", content: final)
                        self.isStreaming = false
                        return
                    }
                    // Intent == .chat → fall through to the plain LLM stream.
                }

                let stream = engine.runInference(prompt: trimmed,
                                                  imageData: imageData,
                                                  audioData: audioData)
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

    /// Called from ChatView.onDisappear — synchronously stops any in-flight
    /// stream and releases the C-side engine before the view's @State storage
    /// goes away. Without this, navigating back mid-stream raced ARC
    /// deallocation against the LiteRT-LM background thread and crashed.
    public func tearDown() {
        stop()
        engine.cleanUp()
    }

    /// Switch to a different .litertlm file mid-conversation. Tears down the
    /// current engine; the next send re-initializes with the new model.
    public func switchModel(to url: URL) {
        stop()
        engine.cleanUp()
        loadStatus = nil
        conversation.modelPath = url.path
        try? store.context.save()
    }

    /// Regenerate the last assistant turn — drop it and re-send the
    /// preceding user message. Mirrors Android's "Regenerate" action.
    public func regenerateLast() {
        guard !isStreaming else { return }
        // Walk backwards: drop trailing assistant message(s); keep the last
        // user message and re-send it.
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        let userMsg = messages[lastUserIdx]
        // Drop everything after (and including) any assistant message that
        // followed the last user one — they get regenerated.
        if lastUserIdx + 1 < messages.count {
            let toDrop = Array(messages[(lastUserIdx + 1)...])
            for m in toDrop { deleteMessage(id: m.id) }
        }
        // The send method will append a fresh assistant message.
        send(userMsg.text, imageData: userMsg.images)
    }

    /// Delete a message from both the in-memory list and the SwiftData store.
    public func deleteMessage(id: UUID) {
        guard let target = messages.first(where: { $0.id == id }) else { return }
        messages.removeAll { $0.id == id }
        // StoredMessage doesn't carry the in-memory UUID — match on
        // (createdAt, content). Equality on those two is unique in practice.
        if let stored = store.messages(in: conversation)
            .first(where: { $0.createdAt == target.createdAt && $0.content == target.text }) {
            store.context.delete(stored)
            try? store.context.save()
        }
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
                               audio: msg.audioBlobs ?? [],
                               createdAt: msg.createdAt)
        }
    }

    /// Render the last `take` chat turns as a "role: text" string for the
    /// orchestrator's `conversationContextProvider` closure. Skips the
    /// in-flight assistant placeholder so the planner never sees an empty
    /// trailing turn. Truncates each turn to 280 chars to keep the planner
    /// prompt bounded — Phase 4's `Planner.bound` enforces an outer cap too.
    nonisolated static func recentHistory(_ messages: [ChatMessage], take: Int) -> String {
        guard take > 0 else { return "" }
        // Drop trailing loading bubbles before slicing.
        let stable = messages.filter { $0.kind != .loading && !$0.text.isEmpty }
        let recent = stable.suffix(take)
        return recent.map { msg in
            let role = msg.role == .assistant ? "assistant" : "user"
            let text = msg.text.count > 280 ? String(msg.text.prefix(280)) + "…" : msg.text
            return "\(role): \(text)"
        }.joined(separator: "\n")
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

    /// Per-model `litert_lm_engine_settings_set_cache_dir` target. Stable
    /// per-model so the LiteRT-LM runtime can reuse pre-compiled kernels
    /// across launches; ephemeral models get fresh dirs because their path
    /// changes.
    private static func derivedCacheDir(for modelURL: URL) -> URL? {
        guard let appSupport = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                            in: .userDomainMask,
                                                            appropriateFor: nil,
                                                            create: true) else { return nil }
        // Cheap stable hash over the absolute path — avoids dragging in
        // CryptoKit just to derive a directory name.
        var hasher = Hasher()
        hasher.combine(modelURL.path)
        let dir = appSupport
            .appendingPathComponent("litertlm-cache", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize()))),
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Settings → runtime enum coercions

private extension LlmBackend {
    /// Maps the UserDefaults string ("cpu" / "gpu" / "") to an enum case.
    /// `nil` means the caller should fall back to a parent setting (e.g.,
    /// vision/audio backends fall back to compute backend when unset).
    static func parse(_ raw: String) -> LlmBackend? {
        switch raw.lowercased() {
        case "cpu":     return .cpu
        case "gpu":     return .gpu
        case "default": return .default
        case "":        return nil
        default:        return nil
        }
    }
}

private extension LlmActivationDtype {
    /// Maps the UserDefaults int (-1 default, 0..3 = F32..I8) to an enum case.
    static func from(rawValue: Int) -> LlmActivationDtype {
        switch rawValue {
        case 0:  return .f32
        case 1:  return .f16
        case 2:  return .i16
        case 3:  return .i8
        default: return .default
        }
    }
}
