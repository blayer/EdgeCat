import Foundation

// 1:1 port of the routing tables in
// android-app/.../orchestration/ExecutionOrchestrator.kt:30-60.
//
// The planner emits a `skillName` (e.g. "calendar") and the executor maps
// it to a concrete tool. Native skills resolve to an Obj-C method name on
// the SkillRegistry; LLM-only skills route to executeLlmStep instead of
// running a tool; everything else routes to `runJs` for the WebView path.

public enum SkillTools {

    /// Skills that are executed by the LLM itself (synthesis from prior
    /// step outputs) rather than by running a tool.
    public static let llmOnly: Set<String> = ["summarize", "compose"]

    /// Native skill name → underlying tool name. Mirrors Android's
    /// NATIVE_SKILL_TOOLS map. The iOS SkillRegistry exposes each tool by
    /// the value side of this map (e.g. "calculate", "manageCalendar").
    public static let native: [String: String] = [
        "calculator":         "calculate",
        "fetch-web-content":  "fetchWebContent",
        "send-sms":           "sendSms",
        "send-email":         "sendEmail",
        "calendar":           "manageCalendar",
        "timer":              "manageTimer",
        "read-contacts":      "readContacts",
        "list-photos":        "listPhotos",
        "search-photos":      "searchPhotos",
        "scan-barcode":       "scanBarcode",
        "list-apps":          "listApps",
        "launch-app":         "launchApp",
        "phone-call":         "makePhoneCall",
        "get-location":       "getLocation",
        "open-url":           "openUrl",
        "clipboard":          "getClipboard",
        "device-info":        "getDeviceInfo",
        "share-content":      "shareContent",
        "flashlight":         "toggleFlashlight",
        "volume-control":     "setVolume",
        "do-not-disturb":     "setDoNotDisturb",
        "take-photo":         "takePhoto",
        "list-downloads":     "listDownloads",
        "open-settings":      "openSettings",
        "search-web":         "searchWeb",
        "search-skills":      "searchSkills",
    ]

    /// LLMs often emit underscore-cased names; assets and the routing maps
    /// use hyphen-cased. Normalize before lookup.
    public static func normalize(_ skillName: String) -> String {
        skillName.replacingOccurrences(of: "_", with: "-")
    }

    /// Resolve a planner-emitted `(skillName, toolName)` pair to the actual
    /// tool to invoke, or `nil` if the step should be executed by the LLM
    /// itself (LLM-only skill or no skill at all).
    public static func resolveTool(skillName: String?, toolName: String?) -> String? {
        // Explicit toolName overrides everything (planner can opt out of
        // routing). Treat the literal string "null" the same as a true
        // null/empty — the planner sometimes serializes the JSON null
        // as the four-character string "null" and we don't want that
        // routed to the registry as a skill lookup.
        if let toolName, !toolName.isEmpty,
           toolName.lowercased() != "null" {
            return toolName
        }
        guard let skillName, !skillName.isEmpty,
              skillName.lowercased() != "null" else { return nil }
        let normalized = normalize(skillName)
        // On iOS each skill is its own `Skill` class registered in
        // `SkillRegistry` under its skill name (e.g. "search-web"), so
        // the tool name passed to `executor.executeTool` IS the skill
        // name. Android's `NATIVE_SKILL_TOOLS` values (e.g. "searchWeb")
        // are AgentTools method names — iOS doesn't need that indirection.
        // The map's keys are still useful as a "known native skill" set
        // so we can short-circuit JS-skill routing.
        if native[normalized] != nil { return normalized }
        if llmOnly.contains(normalized) { return nil }
        // Unknown skill name — assume it's a user-installed JS skill and
        // route to the `JsSkill` registered under the same slug. (When
        // no such skill exists, the registry returns "unknown skill: …".)
        return normalized
    }

    /// Topological sort of plan steps into parallel-safe batches. Steps
    /// within a batch have no mutual dependencies and can execute
    /// concurrently. Batches must execute sequentially. Mirrors
    /// `Planner.getExecutionBatches` on Android.
    public static func batches(for plan: ExecutionPlan) -> [[PlanStep]] {
        guard !plan.steps.isEmpty else { return [] }

        let stepsById = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.id, $0) })
        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for step in plan.steps {
            inDegree[step.id] = 0
            dependents[step.id] = []
        }
        for step in plan.steps {
            for dep in step.dependsOn where stepsById[dep] != nil {
                inDegree[step.id, default: 0] += 1
                dependents[dep, default: []].append(step.id)
            }
        }

        var batches: [[PlanStep]] = []
        var remaining = inDegree

        while !remaining.isEmpty {
            let ready = remaining.filter { $0.value == 0 }.keys.sorted()
            if ready.isEmpty {
                // Cycle — break by emitting all remaining steps as one batch.
                batches.append(remaining.keys.compactMap { stepsById[$0] })
                break
            }
            batches.append(ready.compactMap { stepsById[$0] })
            for id in ready {
                remaining.removeValue(forKey: id)
                for depId in dependents[id] ?? [] {
                    remaining[depId, default: 1] -= 1
                }
            }
        }
        return batches
    }
}
