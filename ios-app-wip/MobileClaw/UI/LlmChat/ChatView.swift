import SwiftUI

// Phase A SwiftUI port of android-app/.../ui/llmchat/LlmChatScreen.kt.
// Text-only chat with streaming and a stop button.

struct ChatView: View {
    @State private var viewModel: ChatViewModel
    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    init(modelURL: URL) {
        _viewModel = State(initialValue: ChatViewModel(modelURL: modelURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.messages.last?.text) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation(.linear(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            if let status = viewModel.loadStatus, status != "Ready" {
                Text(status).font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit(submit)
                if viewModel.isStreaming {
                    Button(action: viewModel.stop) {
                        Image(systemName: "stop.circle.fill").font(.title)
                    }
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(viewModel.modelURL.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() {
        let text = input
        input = ""
        viewModel.send(text)
    }
}

private struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .foregroundStyle(textColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("…").foregroundStyle(.secondary)
            }
        case .error:
            Text(message.text).font(.callout)
        case .text:
            Text(message.text).font(.body).textSelection(.enabled)
        }
    }

    private var bubbleColor: Color {
        switch (message.role, message.kind) {
        case (.user, _): return .accentColor
        case (_, .error): return .red.opacity(0.15)
        default: return Color(.secondarySystemBackground)
        }
    }
    private var textColor: Color {
        switch (message.role, message.kind) {
        case (.user, _): return .white
        case (_, .error): return .red
        default: return .primary
        }
    }
}
