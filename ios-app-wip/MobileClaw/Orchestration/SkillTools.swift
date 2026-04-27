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
        if let toolName, !toolName.isEmpty { return toolName }
        guard let skillName, !skillName.isEmpty else { return nil }
        let normalized = normalize(skillName)
        if let native = native[normalized] { return native }
        if llmOnly.contains(normalized) { return nil }
        return "runJs"
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
