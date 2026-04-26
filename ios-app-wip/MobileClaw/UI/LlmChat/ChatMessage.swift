import Foundation

// Mirrors android-app/.../ui/llmchat/ChatMessage subtypes (text, loading, error, warning).
// Phase A scope: text + loading + error. Thinking + image + audio land in Phase C.

public enum MessageRole: String, Sendable {
    case user, assistant, system
}

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case text, loading, error, thinking }
    public let id: UUID
    public let role: MessageRole
    public var text: String
    public var kind: Kind
    /// Optional thinking-channel content (Gemma's CoT). Renders in a
    /// collapsible panel above the text bubble when non-empty.
    public var thought: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), role: MessageRole, text: String, kind: Kind = .text,
                thought: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.kind = kind
        self.thought = thought; self.createdAt = createdAt
    }
}
