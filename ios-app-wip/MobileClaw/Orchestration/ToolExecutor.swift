import Foundation

// 1:1 port of android-app/.../orchestration/ToolExecutor.kt

public struct ToolExecutionResult: Sendable, Equatable {
    public let success: Bool
    public let output: String
    public let error: String?
    public init(success: Bool, output: String = "", error: String? = nil) {
        self.success = success; self.output = output; self.error = error
    }
}

public protocol ToolExecutor: AnyObject, Sendable {
    /// Execute a tool by name with the given arguments.
    func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult

    /// Currently available skills.
    func getAvailableSkills() -> [SkillSummary]

    /// Update a skill's instructions persistently. Returns false for built-in skills.
    func updateSkillInstructions(skillName: String, newInstructions: String) async -> Bool
}

public extension ToolExecutor {
    func updateSkillInstructions(skillName: String, newInstructions: String) async -> Bool { false }
}
