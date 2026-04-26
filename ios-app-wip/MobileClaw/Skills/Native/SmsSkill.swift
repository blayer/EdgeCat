import Foundation
import UIKit
import MessageUI

// Closest iOS analogue to android-app/assets/skills/send-sms. iOS does not
// allow programmatic SMS sending — MFMessageComposeViewController shows the
// user the message and they tap send. For Phase D scope we open the sms:
// URL with a prefilled body, which surfaces the system composer.

@MainActor public final class SmsSkill: Skill {
    nonisolated public var name: String { "send-sms" }
    nonisolated public var description: String {
        "Open the system SMS composer prefilled with a message (user must confirm). args: number, body"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let number = args["number"], !number.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'number' argument")
        }
        let body = args["body"] ?? ""
        let escaped = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = URL(string: "sms:\(number)\(escaped.isEmpty ? "" : "&body=" + escaped)")
        guard let url else { return ToolExecutionResult(success: false, error: "invalid url") }
        let opened = await UIApplication.shared.open(url)
        return ToolExecutionResult(success: opened, output: opened ? "opened SMS composer" : "could not open")
    }
}
