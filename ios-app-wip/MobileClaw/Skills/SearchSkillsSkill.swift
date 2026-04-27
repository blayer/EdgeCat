import Foundation

// Mirrors android-app's `searchSkills` tool in OrchestrationBridge.kt.
// When the planner emits `{"skillName": "search-skills", "toolArgs": {"query": "..."}}`,
// this returns a JSON list of deferred-tier skills whose name or description
// matches the query, with their full instructions, so the next planner
// iteration has enough info to actually use them.

public final class SearchSkillsSkill: Skill, @unchecked Sendable {
    public let name = "searchSkills"
    public let description = "Loads deferred-tier skill instructions on demand. Pass a `query` arg with keywords; returns matching skills with their usage instructions."
    public let tier = "base"

    /// Closure into the SkillRegistry so this skill can introspect the
    /// catalog at call time. Returning a closure avoids a retain cycle —
    /// the registry constructs this skill last so a weak ref is safe.
    private let allSkillsProvider: @Sendable () -> [SkillSummary]

    public init(_ allSkillsProvider: @Sendable @escaping () -> [SkillSummary]) {
        self.allSkillsProvider = allSkillsProvider
    }

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let query = (args["query"] ?? "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        let deferred = allSkillsProvider().filter { $0.tier == "deferred" }
        let matches: [SkillSummary]
        if tokens.isEmpty {
            matches = deferred
        } else {
            matches = deferred.filter { skill in
                let haystack = (skill.name + " " + skill.description).lowercased()
                return tokens.contains(where: { haystack.contains($0) })
            }
        }

        let payload: [String: Any] = [
            "status": "succeeded",
            "loaded": matches.map { $0.name },
            "skills": matches.map { skill -> [String: Any] in
                [
                    "name": skill.name,
                    "description": skill.description,
                    "instructions": String(skill.instructions.prefix(800)),
                ]
            },
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolExecutionResult(success: true, output: json)
    }
}
