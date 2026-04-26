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
    /// PNG/JPEG bytes for any images the user attached to this turn. Kept
    /// inline so the chat bubble can render them after relaunch without
    /// reaching back to the user's photo library.
    public var imageBlobs: [Data]?
    /// M4A bytes for any audio recordings the user attached to this turn.
    public var audioBlobs: [Data]?

    public init(role: String, content: String, createdAt: Date = Date(),
                conversation: Conversation? = nil,
                imageBlobs: [Data]? = nil, audioBlobs: [Data]? = nil) {
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.conversation = conversation
        self.imageBlobs = imageBlobs
        self.audioBlobs = audioBlobs
    }
}
