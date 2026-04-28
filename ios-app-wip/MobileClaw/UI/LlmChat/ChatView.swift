import SwiftUI
import SwiftData

// 1:1 port of android-app/.../ui/common/chat/ChatView.kt + ChatPanel.kt for
// Phase B+F scope. Loads message history from the SwiftData Conversation,
// streams new turns via LiteRtLmEngine, persists each turn back to the store,
// and surfaces the chat-page settings sheet + model-switch sheet from the
// top bar.

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var input: String = ""
    @State private var attachedImages: [Data] = []
    @State private var attachedAudio: [Data] = []
    @State private var showSettings = false
    @State private var showModelSwitch = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    init(conversation: Conversation) {
        // ConversationStore needs the same context the conversation lives in;
        // SwiftData exposes that via the entity's modelContext property at runtime.
        let ctx = conversation.modelContext ?? Self.makeFallbackContext()
        let store = ConversationStore(context: ctx)
        _viewModel = State(initialValue: ChatViewModel(conversation: conversation, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            ModelPageAppBarContent(
                modelName: viewModel.modelURL.deletingPathExtension().lastPathComponent,
                isStreaming: viewModel.isStreaming,
                onBack: { dismiss() },
                onSettings: { showSettings = true },
                onSwitchModel: { showModelSwitch = true }
            )
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if viewModel.messages.isEmpty {
                            EmptyChatState(onPromptTap: { template in input = template })
                                .frame(maxWidth: .infinity)
                                .padding(.top, 64)
                        } else {
                            ForEach(viewModel.messages) { message in
                                MessageRow(
                                    message: message,
                                    onCopy: { UIPasteboard.general.string = message.text },
                                    onRunAgain: { viewModel.runAgain(message) },
                                    onRegenerate: { viewModel.regenerateLast() },
                                    onDelete: { viewModel.deleteMessage(id: message.id) }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(AppColors.surface)
                .onChange(of: viewModel.messages.last?.text) { _, _ in scroll(proxy) }
                .onChange(of: viewModel.messages.count) { _, _ in scroll(proxy) }
                // Opening a conversation with prior turns should land
                // the user at the latest message, not the very top.
                // No animation — the view hasn't appeared yet.
                .onAppear {
                    if let last = viewModel.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let status = viewModel.loadStatus, status != "Ready" {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(AppColors.onSurfaceVariant)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(AppColors.surfaceVariant.opacity(0.5))
            }

            Divider()
            MessageInputText(
                text: $input,
                attachedImages: $attachedImages,
                attachedAudio: $attachedAudio,
                isStreaming: viewModel.isStreaming,
                canSend: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !attachedImages.isEmpty || !attachedAudio.isEmpty,
                onSend: submit,
                onStop: viewModel.stop,
                showImageButton: true,
                showAudioButton: true
            )
        }
        .background(AppColors.surface.ignoresSafeArea())
        .navigationBarHidden(true)
        .sheet(isPresented: $showSettings) { SettingsView(conversation: viewModel.conversation) }
        .sheet(isPresented: $showModelSwitch) {
            ModelSwitchSheet(currentURL: viewModel.modelURL) { url in
                viewModel.switchModel(to: url)
                showModelSwitch = false
            }
        }
        .onAppear {
            if let auto = ProcessInfo.processInfo.environment["MOBILECLAW_AUTO_SEND"],
               !auto.isEmpty, viewModel.messages.isEmpty {
                viewModel.send(auto)
            }
        }
        .onDisappear { viewModel.tearDown() }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if let last = viewModel.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func submit() {
        let text = input
        let images = attachedImages
        let audio = attachedAudio
        input = ""
        attachedImages = []
        attachedAudio = []
        viewModel.send(text, imageData: images, audioData: audio)
    }

    private static func makeFallbackContext() -> ModelContext {
        do {
            let container = try ModelContainer(for: Conversation.self, StoredMessage.self)
            return ModelContext(container)
        } catch {
            fatalError("Failed to create fallback SwiftData container for ChatView: \(error)")
        }
    }
}

// MARK: - Message row + bubble

private struct MessageRow: View {
    let message: ChatMessage
    let onCopy: () -> Void
    let onRunAgain: () -> Void
    let onRegenerate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let isUser = message.role == .user
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser {
                    Text("Assistant")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColors.onSurfaceVariant)
                        .padding(.leading, 6)
                }
                if !isUser, let thought = message.thought, !thought.isEmpty {
                    ThinkingPanel(text: thought)
                }
                if !message.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                                if let img = UIImage(data: data) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(maxWidth: 160, maxHeight: 160)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }
                    }
                }
                if !message.text.isEmpty || message.kind != .text {
                    bubble
                        .contextMenu {
                            Button { onCopy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                            if isUser {
                                Button { onRunAgain() } label: { Label("Run again", systemImage: "arrow.clockwise") }
                            } else {
                                Button { onRegenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                            }
                            Divider()
                            Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
                        }
                }
                if !isUser, let ms = message.latencyMs, ms > 0 {
                    Text(formatLatency(ms))
                        .font(.caption2)
                        .foregroundStyle(AppColors.onSurfaceVariant)
                        .padding(.leading, 6)
                }
            }
            if !isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func formatLatency(_ ms: Int64) -> String {
        if ms < 1000 { return "\(ms) ms" }
        return String(format: "%.1f s", Double(ms) / 1000)
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.kind {
        case .loading:
            HStack(spacing: 6) {
                TypingIndicator()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(MessageBubbleShape(hardCornerAtLeft: true).fill(AppColors.agentBubble))
        case .error:
            Text(message.text)
                .font(.callout)
                .foregroundStyle(AppColors.onErrorContainer)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(MessageBubbleShape(hardCornerAtLeft: message.role != .user).fill(AppColors.errorContainer))
        case .text, .thinking:
            let isUser = message.role == .user
            // Assistant messages render with inline markdown (bold/italic/code/
            // links) — same behavior as android-app/.../MarkdownText.kt.
            // User messages stay literal so prompts containing markdown
            // characters aren't mangled.
            renderText(message.text, isUser: isUser)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(isUser ? AppColors.onUserBubble : AppColors.onAgentBubble)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    MessageBubbleShape(hardCornerAtLeft: !isUser)
                        .fill(isUser ? AppColors.userBubble : AppColors.agentBubble)
                )
        case .agentLog:
            // Orchestration progress log — one line per phase / step
            // (Planning, step run, step ✓, evaluation, formatting, …).
            // Mirrors android-app's `ChatMessageOrchestrationLog`.
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.onAgentBubble.opacity(0.7))
                    .padding(.bottom, 2)
                ForEach(Array(message.logLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(AppColors.onAgentBubble)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.logInProgress {
                    HStack(spacing: 6) {
                        TypingIndicator()
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                MessageBubbleShape(hardCornerAtLeft: true)
                    .fill(AppColors.agentBubble)
            )
        }
    }

    @ViewBuilder
    private func renderText(_ text: String, isUser: Bool) -> some View {
        if isUser {
            Text(text)
        } else if let attr = try? AttributedString(markdown: text,
                                                   options: AttributedString.MarkdownParsingOptions(
                                                    interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attr)
        } else {
            Text(text)
        }
    }
}

private struct TypingIndicator: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(AppColors.onSurfaceVariant)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

private struct EmptyChatState: View {
    let onPromptTap: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Gradient-styled invitation. Android paints the headline with
            // a `Brush.linearGradient(task color → onSurface)`; SwiftUI
            // gets the same effect via `LinearGradient` masked by a Text.
            Text("Try an example prompt")
                .font(.title2.weight(.bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppColors.primary, AppColors.onSurface],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)
            Text("Or make your own")
                .font(.callout)
                .foregroundStyle(AppColors.onSurfaceVariant)
            VStack(spacing: 12) {
                ForEach(PromptTemplates.load(), id: \.self) { prompt in
                    Button {
                        onPromptTap(prompt)
                    } label: {
                        // Card tile mirroring Android's `Card` with a 1dp
                        // primary-30%-alpha border, 24dp corner, and a soft
                        // shadow tinted with the same primary color.
                        VStack(alignment: .leading, spacing: 6) {
                            Text(prompt)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppColors.onSurface)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(AppColors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(AppColors.primary.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: AppColors.primary.opacity(0.15),
                                radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
        }
    }
}

// MARK: - Model switch sheet

private struct ModelSwitchSheet: View {
    let currentURL: URL
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sideloaded: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if sideloaded.isEmpty {
                        Text("No sideloaded models. Drop a .litertlm into Documents/Models/ via Finder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sideloaded, id: \.self) { url in
                            Button { onPick(url) } label: {
                                HStack {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    Spacer()
                                    if url == currentURL {
                                        MIcon(name: MIconName.check, size: 18, weight: .regular)
                                            .foregroundStyle(AppColors.primary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Switch model")
                } footer: {
                    Text("Switching reloads the engine. The current conversation history is preserved; the new model sees it on the next turn.")
                        .font(.caption)
                }
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let dir = docs?.appendingPathComponent("Models", isDirectory: true) else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        sideloaded = contents.filter { $0.pathExtension.lowercased() == "litertlm" }
                              .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
