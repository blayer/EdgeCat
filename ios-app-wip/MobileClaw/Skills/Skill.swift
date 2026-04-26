import Foundation

// Mirrors the `@Tool`-annotated method shape from android-app/.../AgentTools.kt
// but expressed as a protocol so each iOS skill is a small isolated unit.

public protocol Skill: AnyObject, Sendable {
    var name: String { get }
    var description: String { get }
    var instructions: String { get }
    /// "base" (always in planner catalog) or "deferred" (loaded on demand).
    var tier: String { get }

    func run(args: [String: String]) async -> ToolExecutionResult
}

public extension Skill {
    var instructions: String { "" }
    var tier: String { "base" }
    var summary: SkillSummary {
        SkillSummary(name: name, description: description, instructions: instructions, tier: tier)
    }
}
