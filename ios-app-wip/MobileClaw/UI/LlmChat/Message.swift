import Foundation

// Mirrors android-app/.../ui/llmchat/ChatMessage subtypes (text, loading, error, warning).
// Phase A scope: text + loading + error. Thinking + image + audio land in Phase C.

public enum MessageRole: String, Sendable {
    case user, assistant, system
}

public struct Message: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case text, loading, error }
    public let id: UUID
    public let role: MessageRole
    public var text: String
    public var kind: Kind
    public let createdAt: Date

    public init(id: UUID = UUID(), role: MessageRole, text: String, kind: Kind = .text, createdAt: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.kind = kind; self.createdAt = createdAt
    }
}
