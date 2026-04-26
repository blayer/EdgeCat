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
