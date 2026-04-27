import Foundation
import UIKit

// 1:1 port of android-app/.../DeviceSkills.openUrl. Opens an http(s)
// URL in the system browser. iOS sandbox lets `UIApplication.open` hand
// off any registered URL scheme to whatever app is set as the default
// handler — for http/https that's Safari (or whichever browser the user
// picked in Settings).

public final class OpenUrlSkill: Skill, @unchecked Sendable {
    public var name: String { "open-url" }
    public var description: String {
        "Open a URL in the user's default browser. arg: url=<https://…>"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let raw = args["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw) else {
            return ToolExecutionResult(success: false, error: "missing or invalid 'url' argument")
        }
        return await MainActor.run {
            guard UIApplication.shared.canOpenURL(url) else {
                return ToolExecutionResult(success: false,
                                           error: "no app registered for URL scheme \(url.scheme ?? "?")")
            }
            UIApplication.shared.open(url, options: [:]) { _ in }
            return ToolExecutionResult(success: true, output: "Opened \(raw)")
        }
    }
}
