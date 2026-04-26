import SwiftUI
import SwiftData

// 1:1 mirror of android-app/.../MobileClawNavHost.kt routing:
//   conversations -> model_select(?conversationId) -> agent_chat/{model}/{conversation}

enum Route: Hashable {
    case modelSelect(conversationID: PersistentIdentifier?)
    case chat(conversationID: PersistentIdentifier)
}

struct AppRouter: View {
    @Environment(\.modelContext) private var context
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            ConversationListView(
                onConversationOpened: { conv in
                    if conv.modelPath.isEmpty || !FileManager.default.fileExists(atPath: conv.modelPath) {
                        path.append(.modelSelect(conversationID: conv.persistentModelID))
                    } else {
                        path.append(.chat(conversationID: conv.persistentModelID))
                    }
                },
                onOpenModelSelect: { path.append(.modelSelect(conversationID: nil)) }
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .modelSelect(conversationID):
                    ModelManagerView { url in
                        attachModelAndOpenChat(modelURL: url, conversationID: conversationID)
                    }
                case let .chat(conversationID):
                    if let conv = fetchConversation(id: conversationID) {
                        ChatView(conversation: conv)
                    } else {
                        Text("Conversation not found.").foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { handleAutoOpen() }
        }
    }

    // MARK: - Helpers

    private func attachModelAndOpenChat(modelURL: URL, conversationID: PersistentIdentifier?) {
        let store = ConversationStore(context: context)
        let conv: Conversation
        if let id = conversationID, let existing = fetchConversation(id: id) {
            conv = existing
        } else if let created = try? store.createConversation() {
            conv = created
        } else {
            return
        }
        conv.modelPath = modelURL.path
        try? context.save()
        // Replace the model-select frame with the chat to avoid a back-stack landmine.
        path.removeLast()
        path.append(.chat(conversationID: conv.persistentModelID))
    }

    private func fetchConversation(id: PersistentIdentifier) -> Conversation? {
        context.model(for: id) as? Conversation
    }

    private func handleAutoOpen() {
        guard ProcessInfo.processInfo.environment["MOBILECLAW_AUTO_OPEN_CHAT"] == "1",
              path.isEmpty,
              let url = firstSideloadedModel() else { return }
        let store = ConversationStore(context: context)
        guard let conv = try? store.createConversation() else { return }
        conv.modelPath = url.path
        try? context.save()
        path.append(.chat(conversationID: conv.persistentModelID))
    }

    private func firstSideloadedModel() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let dir = docs?.appendingPathComponent("Models", isDirectory: true)
        guard let dir,
              let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return contents.first(where: { $0.pathExtension.lowercased() == "litertlm" })
    }
}
