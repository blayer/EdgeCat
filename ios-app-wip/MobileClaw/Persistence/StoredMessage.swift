import Foundation
import SwiftData

// 1:1 port of android-app/.../conversations/db/MessageEntity.kt — persisted
// chat message owned by a Conversation. Distinct from ChatMessage (the
// in-memory UI message struct in UI/LlmChat/ChatMessage.swift).

@Model
public final class StoredMessage {
    public var role: String   // "user" or "assistant"
    public var content: String
    public var createdAt: Date
    public var conversation: Conversation?

    public init(role: String, content: String, createdAt: Date = Date(), conversation: Conversation? = nil) {
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.conversation = conversation
    }
}
