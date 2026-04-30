import Foundation
import UIKit

// Mirrors android-app/.../DeviceSkills.openSettings. iOS doesn't let an
// app jump to arbitrary system Settings panes (Wi-Fi, Bluetooth, etc.)
// programmatically — the only sanctioned target is the calling app's own
// Settings page via `UIApplication.openSettingsURLString`. We surface
// that and document the limitation so the planner can fall back to
// guidance when the user asks for "open Wi-Fi settings" etc.

public final class OpenSettingsSkill: Skill, @unchecked Sendable {
    public var name: String { "open-settings" }
    public var description: String {
        "USE THIS for any \"open settings\", \"go to settings\", \"open " +
        "iOS settings\" request — DO NOT use launch-app for Settings. " +
        "Opens the iOS Settings app on this app's preferences page. " +
        "iOS does not let third-party apps jump to other Settings panes."
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        await MainActor.run {
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                return ToolExecutionResult(success: false, error: "couldn't construct settings URL")
            }
            UIApplication.shared.open(url, options: [:]) { _ in }
            return ToolExecutionResult(success: true,
                                       output: "Opened Settings → Mobile-Claw")
        }
    }
}
