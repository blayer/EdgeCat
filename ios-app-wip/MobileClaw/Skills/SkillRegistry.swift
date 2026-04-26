import Foundation

// Mirrors android-app/.../customtasks/agentchat/SkillManagerViewModel.kt's
// catalog-of-skills surface. Each Skill registers itself; ToolExecutor
// dispatches by name.

public final class SkillRegistry: ToolExecutor, @unchecked Sendable {
    private var skillsByName: [String: Skill] = [:]
    private let queue = DispatchQueue(label: "com.mobileclaw.skillregistry", attributes: .concurrent)

    public init(skills: [Skill] = []) {
        for s in skills { register(s) }
    }

    public func register(_ skill: Skill) {
        queue.async(flags: .barrier) { self.skillsByName[skill.name] = skill }
    }

    public func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
        let skill: Skill? = queue.sync { skillsByName[toolName] }
        guard let skill else {
            return ToolExecutionResult(success: false, output: "", error: "unknown skill: \(toolName)")
        }
        return await skill.run(args: args)
    }

    public func getAvailableSkills() -> [SkillSummary] {
        queue.sync { skillsByName.values.map { $0.summary }.sorted { $0.name < $1.name } }
    }

    /// Bundle of platform-portable skills suitable for Phase D MVP. Native
    /// iOS skills (Contacts, Calendar, Photos, etc.) compose on top of this.
    @MainActor public static func defaultSet() -> SkillRegistry {
        SkillRegistry(skills: [
            CalculatorSkill(),
            ClipboardSkill(),
            DeviceInfoSkill(),
            FetchWebContentSkill(),
            SearchWebSkill(),
        ])
    }
}
