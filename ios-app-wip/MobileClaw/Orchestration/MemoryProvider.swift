import Foundation

// Mirrors android-app/.../memory/MemoryRepository.recallForPlanning — the
// orchestration module needs to ask "what's relevant to this user message?"
// without depending on the SwiftData-backed implementation. The chat layer
// passes in a concrete provider; tests pass in a fake.

public protocol MemoryProvider: Sendable {
    /// Returns a short, planner-prompt-ready string of relevant prior
    /// episodes / device facts / repair records. Empty string when nothing
    /// is recalled. Implementations should bound the result so the planner
    /// prompt stays inside the model's working window.
    func recallForPlanning(userMessage: String) async -> String
}

/// Default no-op provider used when the chat layer doesn't wire in a real
/// `MemoryRepository` (eval harness, plain test setups). Returns "" so the
/// planner prompt simply omits the memory section.
public struct EmptyMemoryProvider: MemoryProvider {
    public init() {}
    public func recallForPlanning(userMessage: String) async -> String { "" }
}
