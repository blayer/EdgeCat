import SwiftUI
import SwiftData

// 1:1 port of android-app/.../ui/common/chat/ChatView.kt + ChatPanel.kt for
// Phase B scope (text-only, persistence-aware). Loads message history from
// the SwiftData Conversation, streams new turns via LiteRtLmEngine, and
// saves each completed user/assistant pair back to the store.

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var input: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    init(conversation: Conversation) {
        // ConversationStore needs the same context the conversation lives in;
        // SwiftData exposes that via the entity's modelContext property at runtime.
        let ctx = conversation.modelContext ?? ModelContext(try! ModelContainer(for: Conversation.self, StoredMessage.self))
        let store = ConversationStore(context: ctx)
        _viewModel = State(initialValue: ChatViewModel(conversation: conversation, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            ModelPageAppBarContent(
                modelName: viewModel.modelURL.deletingPathExtension().lastPathComponent,
                isStreaming: viewModel.isStreaming,
                onBack: { dismiss() },
                onReset: { viewModel.resetSession() }
            )
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if viewModel.messages.isEmpty {
                            EmptyChatState()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 96)
                        } else {
                            ForEach(viewModel.messages) { message in
                                MessageRow(message: message).id(message.id)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(AppColors.surface)
                .onChange(of: viewModel.messages.last?.text) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation(.linear(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
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
                isStreaming: viewModel.isStreaming,
                canSend: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onSend: submit,
                onStop: viewModel.stop,
                showImageButton: false,   // Phase C
                showAudioButton: false    // Phase C
            )
        }
        .background(AppColors.surface.ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear {
            if let auto = ProcessInfo.processInfo.environment["MOBILECLAW_AUTO_SEND"],
               !auto.isEmpty, viewModel.messages.isEmpty {
                viewModel.send(auto)
            }
        }
    }

    private func submit() {
        let text = input
        input = ""
        viewModel.send(text)
    }
}

// MARK: - Message row + bubble

private struct MessageRow: View {
    let message: ChatMessage
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
                bubble
            }
            if !isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(AppColors.primary.opacity(0.5))
            Text("Start a conversation")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.onSurface)
            Text("Send a message to chat with the model on-device.")
                .font(.callout)
                .foregroundStyle(AppColors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
    }
}
