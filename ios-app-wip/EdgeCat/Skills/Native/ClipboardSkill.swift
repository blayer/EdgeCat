import Foundation
import UIKit

// 1:1 functional port of android-app/assets/skills/clipboard. UIPasteboard.general
// is the iOS equivalent of Android's ClipboardManager.

@MainActor public final class ClipboardSkill: Skill {
    nonisolated public var name: String { "clipboard" }
    nonisolated public var description: String { "Read or write the system clipboard. action=read|write, text=..." }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let action = args["action"] ?? "read"
        if action == "write" {
            UIPasteboard.general.string = args["text"] ?? ""
            return ToolExecutionResult(success: true, output: "wrote to clipboard")
        }
        let text = UIPasteboard.general.string ?? ""
        return ToolExecutionResult(success: true, output: text)
    }
}
