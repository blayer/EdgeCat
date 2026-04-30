import Foundation

// Mirrors android-app/.../memory/MemoryRepository.{recallForPlanning, save}
// — the orchestration module needs to ask "what's relevant to this user
// message?" and persist a completed run, without depending on the
// SwiftData-backed implementation. The chat layer wires in a concrete
// provider; tests pass in a fake.

public protocol MemoryProvider: Sendable {
    /// Returns a short, planner-prompt-ready string of relevant prior
    /// episodes / device facts / repair records. Empty string when nothing
    /// is recalled. Implementations should bound the result so the planner
    /// prompt stays inside the model's working window.
    func recallForPlanning(userMessage: String) async -> String

    /// Persist a completed orchestration run so future plans can reference
    /// it via `recallForPlanning`. The default implementation is a no-op
    /// so callers that don't care about write-back (eval harness, tests)
    /// don't have to implement it.
    func saveEpisode(_ episode: OrchestrationEpisode) async
}

public extension MemoryProvider {
    func saveEpisode(_ episode: OrchestrationEpisode) async {}
}

/// What the orchestrator hands to memory after a successful run. Mirrors
/// the data Android's `MemoryRepository.save(episode:)` accepts. Kept in
/// the orchestration module so it doesn't depend on SwiftData entities.
public struct OrchestrationEpisode: Sendable, Equatable {
    public let id: String
    public let createdAt: Date
    public let userMessage: String
    public let goal: String
    public let skillsUsed: [String]
    public let outcome: String
    public let finalOutput: String

    public init(id: String = UUID().uuidString,
                createdAt: Date = Date(),
                userMessage: String,
                goal: String,
                skillsUsed: [String],
                outcome: String,
                finalOutput: String) {
        self.id = id
        self.createdAt = createdAt
        self.userMessage = userMessage
        self.goal = goal
        self.skillsUsed = skillsUsed
        self.outcome = outcome
        self.finalOutput = finalOutput
    }
}

/// Default no-op provider used when the chat layer doesn't wire in a real
/// `MemoryRepository` (eval harness, plain test setups). Returns "" so the
/// planner prompt simply omits the memory section.
public struct EmptyMemoryProvider: MemoryProvider {
    public init() {}
    public func recallForPlanning(userMessage: String) async -> String { "" }
    public func saveEpisode(_ episode: OrchestrationEpisode) async {}
}
