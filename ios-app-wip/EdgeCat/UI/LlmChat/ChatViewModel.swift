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

    /// Snapshot of the engine-affecting settings used at the last
    /// `engine.initialize` call. When the user changes any of these in
    /// Settings, the next `send()` detects the diff and tears down +
    /// re-initializes the engine. Without this the user would have to
    /// restart the app for `maxTokens` / `accelerator` / etc. changes
    /// to take effect — which is what produced the 1024-token error
    /// users hit when bumping max tokens to 4000 in Settings.
    private var loadedConfigHash: Int?

    /// When true, route user messages through the orchestration loop
    /// (Planner → Executor → Evaluator) instead of direct chat. Sources, in
    /// priority order: launch env var EDGECAT_AGENTIC=1, then the
    /// SettingsView toggle backed by UserDefaults.
    public var agenticMode: Bool {
        if ProcessInfo.processInfo.environment["EDGECAT_AGENTIC"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "EDGECAT_AGENTIC_MODE")
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
                let s = SamplerSettings.current()
                // Per-conversation override wins over the global Settings
                // value, which in turn wins over the bundled default.
                // Mirrors Android's
                // `AgentChatTask.defaultSystemPrompt` fallback chain.
                let prompt = conversation.systemPromptOverride
                    ?? (s.systemPrompt.isEmpty ? SamplerSettings.defaultSystemPrompt : s.systemPrompt)
                let configHash = Self.engineConfigHash(settings: s, systemPrompt: prompt)

                // First-load OR settings changed → tear down + re-init.
                // The engine holds the C-side conversation, sampler params,
                // and KV-cache size; none of those can be mutated after
                // construction, so we destroy the live engine and build a
                // fresh one. Slow (5-30 s for big models) but correct.
                let needsReload = (loadStatus == nil) || (configHash != loadedConfigHash)
                if needsReload {
                    if loadStatus != nil { engine.cleanUp() }
                    self.loadStatus = "Loading model…"
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
                    self.loadedConfigHash = configHash
                }

                // Agentic mode: drive a Planner → Executor → Evaluator loop
                // and emit the final formatted response as a single bubble.
                // Used by env var EDGECAT_AGENTIC=1 today; surfaces as a
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
                        // a planner run.
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

                        // Replace the "loading" placeholder with a fresh
                        // orchestration-log bubble. The observer Task below
                        // appends lines (Planning…, step results, evaluation)
                        // as the controller's @Observable state changes.
                        // Mirrors android-app's `ChatMessageOrchestrationLog`.
                        let logId = assistantId
                        self.replace(id: logId,
                                     with: ChatMessage(id: logId, role: .assistant,
                                                       text: "", kind: .agentLog,
                                                       logLines: ["💡 Planning…"],
                                                       logInProgress: true))

                        let observerTask = Task { @MainActor [weak self] in
                            await self?.observeOrchestration(logId: logId,
                                                             controller: controller)
                        }
                        defer { observerTask.cancel() }

                        let final = try await controller.handle(userMessage: trimmed)
                        observerTask.cancel()
                        // Finalize the log and emit the answer as a
                        // separate text bubble so the user can copy /
                        // run-again on it independently of the trace.
                        self.appendOrchestrationLine(id: logId, "🎉 Task complete")
                        self.finalizeOrchestrationLog(id: logId)
                        let answerId = UUID()
                        self.messages.append(ChatMessage(id: answerId, role: .assistant,
                                                         text: final, kind: .text))
                        try? store.appendMessage(to: conversation, role: "assistant", content: final)
                        // Wipe the formatter's KV cache and reseed with
                        // the visible chat history so post-task chat
                        // turns can still reason against earlier bubbles.
                        // Without the reset, the next chat turn would
                        // inherit the formatter's `<msg>…</msg>` few-
                        // shot prompt and the model would echo the
                        // wrapper. Without the history reseed, the
                        // model would start cold and have no memory of
                        // the user's prior turns visible in the UI.
                        let historyForReplay = ChatViewModel.replayableHistory(
                            from: self.messages, take: s.agentHistoryWindow)
                        try? engine.resetConversation(
                            systemInstruction: prompt,
                            history: historyForReplay)
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
        loadedConfigHash = nil
    }

    /// Hash over every setting that requires reconstructing the LiteRT-LM
    /// engine (those passed to `litert_lm_engine_settings_*` /
    /// `litert_lm_session_config_*` / `litert_lm_conversation_config_*`,
    /// none of which can be mutated after engine creation). Sampler-only
    /// changes (topK/topP/temperature) ALSO require a re-init because we
    /// pass them at conversation creation time. Skip pure UI settings.
    /// `nonisolated` because it touches no actor state — pure Hasher work
    /// over an immutable Snapshot. Without this, tests calling it from a
    /// nonisolated XCTestCase context fail under stricter Swift 6
    /// concurrency in CI.
    nonisolated static func engineConfigHash(settings s: SamplerSettings.Snapshot,
                                             systemPrompt: String?) -> Int {
        var hasher = Hasher()
        hasher.combine(s.maxTokens)
        hasher.combine(s.accelerator)
        hasher.combine(s.visionAccelerator)
        hasher.combine(s.audioAccelerator)
        hasher.combine(s.parallelFileLoading)
        hasher.combine(s.activationDtype)
        hasher.combine(s.prefillChunkSize)
        hasher.combine(s.speculativeDecoding)
        hasher.combine(s.debugLogLevel)
        hasher.combine(s.samplerType)
        hasher.combine(s.topK)
        hasher.combine(s.topP)
        hasher.combine(s.temperature)
        hasher.combine(s.seed)
        hasher.combine(s.maxOutputTokens)
        hasher.combine(s.applyPromptTemplate)
        hasher.combine(s.enableConstrainedDecoding)
        hasher.combine(systemPrompt ?? "")
        return hasher.finalize()
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
    /// trailing turn.
    ///
    /// Per-message truncation: 1000 chars, bumped up from 280. A 280-char
    /// cap eats multi-paragraph assistant outputs (e.g. a generated trip
    /// plan) after the first sentence — the next turn's planner then can't
    /// "base on" the prior plan and asks the user to repeat themselves.
    /// `Planner.bound` enforces an outer cap by `historyWindow * 1000` so
    /// the total context still has a hard ceiling.
    nonisolated static func recentHistory(_ messages: [ChatMessage], take: Int) -> String {
        guard take > 0 else { return "" }
        // Drop trailing loading bubbles before slicing.
        let stable = messages.filter { $0.kind != .loading && !$0.text.isEmpty }
        let recent = stable.suffix(take)
        return recent.map { msg in
            let role = msg.role == .assistant ? "assistant" : "user"
            let text = msg.text.count > 1000 ? String(msg.text.prefix(1000)) + "…" : msg.text
            return "\(role): \(text)"
        }.joined(separator: "\n")
    }

    /// Last N visible chat turns formatted for `set_messages` reseed
    /// of a fresh LiteRT-LM conversation. Drops loading placeholders,
    /// orchestration logs (UI noise the model shouldn't see), and
    /// error bubbles. Returns role-tagged tuples — JSON encoding is
    /// the bridge's job.
    nonisolated static func replayableHistory(from messages: [ChatMessage],
                                              take: Int) -> [(role: String, content: String)] {
        guard take > 0 else { return [] }
        let stable = messages.filter { msg in
            (msg.kind == .text || msg.kind == .thinking)
                && !msg.text.isEmpty
                && (msg.role == .user || msg.role == .assistant)
        }
        return stable.suffix(take).map { msg in
            (role: msg.role == .assistant ? "assistant" : "user",
             content: msg.text)
        }
    }

    private func update(id: UUID, text: String, kind: ChatMessage.Kind, thought: String? = nil) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
        messages[idx].kind = kind
        if let thought { messages[idx].thought = thought }
    }

    /// Wholesale replacement keeping ID stable. Used to swap a `loading`
    /// placeholder for an `agentLog` bubble when agentic mode kicks in.
    private func replace(id: UUID, with new: ChatMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            messages.append(new); return
        }
        messages[idx] = new
    }

    private func appendOrchestrationLine(id: UUID, _ line: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        // Whole-struct replacement so @Observable's setter on `messages`
        // fires and SwiftUI re-renders. Nested in-place mutation
        // (`messages[idx].logLines.append(...)`) sometimes doesn't
        // trip the observation under iOS 17 in our setup.
        var msg = messages[idx]
        msg.logLines.append(line)
        messages[idx] = msg
    }

    /// Replace the most recent line that starts with `prefix` (e.g. an
    /// "in-progress" `…` line) with `replacement`. No-op when no match.
    private func replaceOrchestrationLine(id: UUID,
                                          prefix: String,
                                          with replacement: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var msg = messages[idx]
        if let lineIdx = msg.logLines.lastIndex(where: { $0.hasPrefix(prefix) }) {
            msg.logLines[lineIdx] = replacement
        } else {
            msg.logLines.append(replacement)
        }
        messages[idx] = msg
    }

    private func finalizeOrchestrationLog(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var msg = messages[idx]
        msg.logInProgress = false
        messages[idx] = msg
    }

    /// Polls `OrchestrationController.state` while the run is active and
    /// translates state transitions into log lines on the active log
    /// bubble. Mirrors android-app's `controller.state.collect { … }` in
    /// AgentChatScreen. We poll instead of using a stream because
    /// `@Observable` doesn't expose an AsyncSequence directly; the
    /// 50ms tick is well below any user-noticeable lag.
    @MainActor
    private func observeOrchestration(logId: UUID,
                                      controller: OrchestrationController) async {
        var lastStatus: OrchestrationStatus = .idle
        var lastIteration: Int = -1
        var emittedSteps: Set<String> = []
        // Track whether we already announced memory recall / planning thinking
        // so each event renders exactly once.
        var memoryAnnounced = false

        while !Task.isCancelled {
            let s = controller.state

            // Memory recall — fires once.
            if !memoryAnnounced, let recalled = s.memoryRecalled {
                memoryAnnounced = true
                appendOrchestrationLine(id: logId,
                                        recalled ? "🧠 Memory recalled"
                                                 : "🧠 No memory found")
            }

            // Plan ready → resolve "Planning…" and list the steps.
            if let plan = s.plan, s.iteration != lastIteration {
                lastIteration = s.iteration
                let label = s.iteration == 0 ? "💡 Planned" : "🔄 Re-planned"
                replaceOrchestrationLine(id: logId, prefix: "💡 Planning",
                                         with: label)
                replaceOrchestrationLine(id: logId, prefix: "🔄 Re-planning",
                                         with: label)
                let iterTag = s.iteration > 0 ? " (iter \(s.iteration + 1))" : ""
                appendOrchestrationLine(id: logId, "📋 \(plan.goal)\(iterTag)")
                for step in plan.steps {
                    let skill = step.skillName.map { " [\($0)]" } ?? ""
                    appendOrchestrationLine(id: logId, "   • \(step.description)\(skill)")
                }
                emittedSteps.removeAll()
            }

            // Step transitions during execution.
            if s.status == .executing {
                for (id, result) in s.stepResults {
                    let key = "\(id):\(result.status.rawValue)"
                    if emittedSteps.contains(key) { continue }
                    emittedSteps.insert(key)
                    let desc = s.plan?.steps.first(where: { $0.id == id })?.description ?? id
                    switch result.status {
                    case .completed:
                        let dur = result.durationMs > 0
                            ? String(format: " (%.1fs)", Double(result.durationMs) / 1000)
                            : ""
                        appendOrchestrationLine(id: logId, "✅ \(desc)\(dur)")
                    case .failed:
                        let err = (result.error ?? "unknown").prefix(80)
                        appendOrchestrationLine(id: logId, "❌ \(desc) — \(err)")
                    case .skipped:
                        appendOrchestrationLine(id: logId, "⏭ \(desc)")
                    case .running, .pending:
                        break
                    }
                }
            }

            // Evaluation result.
            if let eval = s.evaluation, lastStatus == .evaluating, s.status != .evaluating {
                if eval.goalAchieved {
                    appendOrchestrationLine(id: logId, "🔍 Evaluated → goal achieved")
                } else {
                    let snippet = eval.assessment.prefix(100)
                    appendOrchestrationLine(id: logId, "⚠️ \(snippet)")
                    if eval.shouldReplan {
                        appendOrchestrationLine(id: logId, "🔄 Re-planning…")
                    }
                }
            }

            // Phase transitions for status-only updates (no plan/eval change).
            if s.status != lastStatus {
                switch s.status {
                case .formatting:
                    appendOrchestrationLine(id: logId, "✍️ Formatting response…")
                case .repairing:
                    appendOrchestrationLine(id: logId, "🔧 Diagnosing failed step…")
                default:
                    break
                }
                lastStatus = s.status
            }

            // Completed / cancelled / error end states.
            if s.status == .completed || s.status == .cancelled || s.status == .error {
                return
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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
