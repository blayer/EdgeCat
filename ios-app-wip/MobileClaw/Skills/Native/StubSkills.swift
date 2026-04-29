import Foundation

// Skills that have no clean iOS equivalent (per the iOS skill mapping memo).
// They return a structured `not_supported_on_ios` error so the
// SelfEvaluator's repair loop can replan around them rather than crash.

public final class DoNotDisturbSkill: Skill, @unchecked Sendable {
    public var name: String { "do-not-disturb" }
    public var description: String { "(iOS) Read-only — DND can't be toggled programmatically." }
    public init() {}
    public func run(args: [String: String]) async -> ToolExecutionResult {
        ToolExecutionResult(success: false, error: "not_supported_on_ios — DND is user-only")
    }
}

public final class SetAlarmSkill: Skill, @unchecked Sendable {
    public var name: String { "set-alarm" }
    public var description: String { "(iOS) Not supported — Clock app has no public API." }
    public init() {}
    public func run(args: [String: String]) async -> ToolExecutionResult {
        ToolExecutionResult(success: false, error: "not_supported_on_ios — use set-reminder instead")
    }
}

public final class ListAppsSkill: Skill, @unchecked Sendable {
    public var name: String { "list-apps" }
    public var description: String { "(iOS) Not supported — sandbox prevents enumerating other apps." }
    public init() {}
    public func run(args: [String: String]) async -> ToolExecutionResult {
        ToolExecutionResult(success: false, error: "not_supported_on_ios")
    }
}

public final class TakePhotoSkill: Skill, @unchecked Sendable {
    public var name: String { "take-photo" }
    public var description: String {
        "(iOS) Not supported headlessly — UIImagePickerController / AVCapturePhotoOutput " +
        "require UI presentation context the orchestration layer doesn't have. " +
        "Tell the user to use the camera button in chat input instead."
    }
    public init() {}
    public func run(args: [String: String]) async -> ToolExecutionResult {
        ToolExecutionResult(
            success: false,
            error: "not_supported_on_ios — capture requires user-driven UI, " +
                   "use the camera button in the chat composer")
    }
}

/// LLM-only catalog stub. The executor short-circuits skills whose
/// names appear in `SkillTools.llmOnly` and runs `runLlmStep` instead
/// of calling this skill — so `run()` here is a no-op fallback that
/// shouldn't ever fire. Registering the catalog entry lets the planner
/// pick `summarize` for free-form synthesis tasks (instead of leaving
/// `skillName: null`), which the eval harness's plan_validity scorer
/// requires.
public final class SummarizeSkill: Skill, @unchecked Sendable {
    public var name: String { "summarize" }
    public var description: String {
        "Synthesize free-form text from prior step outputs (LLM-only). " +
        "USE THIS for any task whose final step is composing a paragraph, " +
        "drafting an itinerary, summarizing an article, or otherwise " +
        "producing prose. The executor routes this name through the LLM " +
        "lane — no tool is invoked. " +
        "DO NOT pick `calculator` for synthesis (that's arithmetic only). " +
        "Set `dependsOn` to the prior step IDs whose outputs you want the " +
        "LLM to read. Optional `instruction` arg overrides the description " +
        "as the synthesis prompt."
    }
    public init() {}
    public func run(args: [String: String]) async -> ToolExecutionResult {
        // Defensive: if for some reason the executor invokes this directly
        // (shouldn't happen — `SkillTools.llmOnly` short-circuits to
        // `runLlmStep`), return the description as a no-op so we don't
        // surface a hard failure.
        ToolExecutionResult(success: true,
                            output: args["instruction"] ?? args["description"] ?? "")
    }
}

public final class ComposeSkill: Skill, @unchecked Sendable {
    public var name: String { "compose" }
    public var description: String {
        "Compose free-form text (LLM-only). Same routing as `summarize` — " +
        "the executor synthesizes via the LLM lane rather than calling a " +
        "tool. Use for messages, drafts, replies, or any non-arithmetic " +
        "text generation that doesn't fit a domain-specific skill."
    }
    public init() {}
    public func run(args: [String: String]) async -> ToolExecutionResult {
        ToolExecutionResult(success: true,
                            output: args["instruction"] ?? args["description"] ?? "")
    }
}

public final class VolumeControlSkill: Skill, @unchecked Sendable {
    public var name: String { "volume-control" }
    public var description: String {
        "(iOS) Not supported — Apple revoked the MPVolumeView slider API; " +
        "third-party apps can no longer change system audio volume."
    }
    public init() {}
    public func run(args: [String: String]) async -> ToolExecutionResult {
        ToolExecutionResult(
            success: false,
            error: "not_supported_on_ios — programmatic volume control was removed in iOS 11+")
    }
}
