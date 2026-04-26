import Foundation
import SwiftData

// Wrapper around SwiftData's ModelContext that mirrors the Android
// ConversationRepository surface (create / delete / setPinned / observe).
// Used by ConversationListViewModel and ChatViewModel.

@MainActor
public final class ConversationStore {
    public let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public func createConversation() throws -> Conversation {
        let conv = Conversation()
        context.insert(conv)
        try context.save()
        return conv
    }

    public func deleteConversation(_ conv: Conversation) throws {
        context.delete(conv)
        try context.save()
    }

    public func setPinned(_ conv: Conversation, _ pinned: Bool) throws {
        conv.pinned = pinned
        conv.pinnedAt = pinned ? Date() : nil
        try context.save()
    }

    public func appendMessage(to conv: Conversation, role: String, content: String,
                              images: [Data] = []) throws {
        let stored = StoredMessage(role: role, content: content, conversation: conv,
                                   imageBlobs: images.isEmpty ? nil : images)
        context.insert(stored)
        conv.messageCount += 1
        conv.lastMessagePreview = String(content.prefix(120))
        conv.updatedAt = Date()
        if conv.title.isEmpty, role == "user" {
            conv.title = String(content.prefix(60))
        }
        try context.save()
    }

    public func messages(in conv: Conversation) -> [StoredMessage] {
        conv.messages.sorted { $0.createdAt < $1.createdAt }
    }
}
