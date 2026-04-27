import Foundation

// Mirrors android-app/.../customtasks/agentchat/SkillManagerViewModel.kt's
// catalog-of-skills surface. Each Skill registers itself; ToolExecutor
// dispatches by name. The registry knows about every shipped skill;
// `getAvailableSkills()` filters to user-enabled skills via
// `SkillToggles` so the planner only sees what the user wants exposed.

public final class SkillRegistry: ToolExecutor, @unchecked Sendable {
    private var skillsByName: [String: Skill] = [:]
    private let queue = DispatchQueue(label: "com.mobileclawapp.skillregistry", attributes: .concurrent)

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

    /// Skills the planner should see — drops anything the user has toggled
    /// off via the Skill Manager. The full catalog (including disabled
    /// rows) is reachable through `allSkills()` for the Settings UI.
    public func getAvailableSkills() -> [SkillSummary] {
        queue.sync {
            skillsByName.values
                .filter { SkillToggles.isEnabled($0.name) }
                .map { $0.summary }
                .sorted { $0.name < $1.name }
        }
    }

    /// Full catalog regardless of enabled state. Used by SkillManagerView.
    public func allSkills() -> [SkillSummary] {
        queue.sync { skillsByName.values.map { $0.summary }.sorted { $0.name < $1.name } }
    }

    /// Bundle of native iOS skills (permission-gated platform integrations
    /// and on-device computations) plus every JS skill auto-loaded from
    /// `Resources/skills/<slug>/SKILL.md`. Stubs for skills without an iOS
    /// equivalent (DND toggle, set-alarm, list-apps) round out the catalog
    /// so the planner addresses the same names Android does and the
    /// evaluator can replan around `not_supported_on_ios` errors.
    @MainActor public static func defaultSet() -> SkillRegistry {
        let nativeSkills: [Skill] = [
            CalculatorSkill(),
            ClipboardSkill(),
            DeviceInfoSkill(),
            FetchWebContentSkill(),
            SearchWebSkill(),
            ContactsSkill(),
            CalendarSkill(),
            RemindersSkill(),
            PhotosSkill(),
            LocationSkill(),
            PhoneCallSkill(),
            SmsSkill(),
            FlashlightSkill(),
            ShareContentSkill(),
            BarcodeSkill(),
            DoNotDisturbSkill(),
            SetAlarmSkill(),
            ListAppsSkill(),
        ]
        let nativeNames = Set(nativeSkills.map { $0.name })

        // Auto-discover JS-backed skills. Any `<root>/skills/<slug>/`
        // directory (built-in OR user-authored) with a SKILL.md and a
        // `scripts/index.html` becomes a JsSkill — no per-skill
        // registration needed. Custom skills win on slug collision (so a
        // user can override a built-in). Native skills shadow both.
        let jsSkills: [Skill] = SkillBundle.scanAll()
            .filter { $0.hasJsScripts && !nativeNames.contains($0.slug) }
            .map { JsSkill(manifest: $0) }

        return SkillRegistry(skills: nativeSkills + jsSkills)
    }
}
