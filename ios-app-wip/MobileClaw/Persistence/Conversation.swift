import Foundation
import SwiftData

// 1:1 port of android-app/.../conversations/db/ConversationEntity.kt to SwiftData.
// Same column semantics: title, created/updated timestamps, message count,
// last message preview, pinned flag.

@Model
public final class Conversation {
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var lastMessagePreview: String
    public var pinned: Bool
    public var pinnedAt: Date?
    /// Absolute path to the .litertlm file this conversation runs against.
    /// Stored as String (not URL) since SwiftData's URL handling is brittle.
    public var modelPath: String

    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
    public var messages: [StoredMessage] = []

    public init(
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messageCount: Int = 0,
        lastMessagePreview: String = "",
        pinned: Bool = false,
        pinnedAt: Date? = nil,
        modelPath: String = ""
    ) {
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.lastMessagePreview = lastMessagePreview
        self.pinned = pinned
        self.pinnedAt = pinnedAt
        self.modelPath = modelPath
    }
}
