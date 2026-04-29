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

// LLM-only catalog stubs. The executor short-circuits these via
// `SkillTools.llmOnly` and routes to `runLlmStep` — these `run()`
// implementations are defensive no-ops. Catalog visibility lets the
// planner pick `summarize`/`compose` for synthesis steps (which keeps
// plan_validity scoring happy and avoids `skillName: null`).
//
// Descriptions are intentionally one-liners — verbose copy here
// inflates every planner prompt by ~150 chars and destabilizes
// generation on tight context budgets (Gemma 4 E2B).

public final class SummarizeSkill: Skill, @unchecked Sendable {
    public var name: String { "summarize" }
    public var description: String {
        "Synthesize free-form text from prior step outputs (LLM-only, no tool call). Use for paragraphs, summaries, itineraries, drafts."
    }
    public init() {}
    public func run(args: [String: String]) async -> ToolExecutionResult {
        ToolExecutionResult(success: true,
                            output: args["instruction"] ?? args["description"] ?? "")
    }
}

public final class ComposeSkill: Skill, @unchecked Sendable {
    public var name: String { "compose" }
    public var description: String {
        "Compose free-form text (LLM-only, no tool call). Same routing as summarize — for messages, replies, or non-arithmetic text generation."
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
