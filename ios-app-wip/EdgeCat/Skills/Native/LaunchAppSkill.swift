import Foundation
import UIKit

// Mirrors android-app/.../DeviceSkills.launchApp. iOS apps can't launch
// arbitrary other apps by package name like Android can — sandboxing
// blocks it. The supported workaround is URL schemes: every shipped app
// can register one (e.g. `instagram://`, `tg://`, `googlemaps://`) and
// `UIApplication.canOpenURL` lets us probe for it. We keep a small
// curated map for the most common destinations so plan steps like
// "launch maps" / "launch messages" still work, and fall through to
// trying the raw arg as a scheme for anything outside the curated set.

public final class LaunchAppSkill: Skill, @unchecked Sendable {
    public var name: String { "launch-app" }
    public var description: String {
        "Launch a known app by name. arg: appName=<name|url scheme>. " +
        "iOS only supports a curated set of apps (maps, messages, mail, phone, " +
        "music, podcasts, weather, calendar, notes, reminders, photos) " +
        "or an explicit URL scheme. " +
        "DO NOT use this for \"open Settings\" / \"iOS settings\" — pick " +
        "the `open-settings` skill instead (iOS sandboxes third-party " +
        "apps to their own Settings pane, not the system Settings app)."
    }
    public init() {}

    /// Common app → URL scheme mapping. Each scheme opens the app's root.
    /// Android passes a package name like `com.google.android.apps.maps`;
    /// the planner is told (via `description`) to use a friendly name.
    private static let appSchemes: [String: String] = [
        "maps":      "maps://",
        "apple-maps": "maps://",
        "googlemaps": "comgooglemaps://",
        "google-maps": "comgooglemaps://",
        "messages":  "sms:",
        "sms":       "sms:",
        "mail":      "message://",
        "phone":     "tel:",
        "music":     "music://",
        "apple-music": "music://",
        "spotify":   "spotify:",
        "podcasts":  "podcasts://",
        "weather":   "weather://",
        "calendar":  "calshow://",
        "notes":     "mobilenotes://",
        "reminders": "x-apple-reminderkit://",
        "photos":    "photos-redirect://",
        "settings":  UIApplication.openSettingsURLString,
        "youtube":   "youtube://",
        "instagram": "instagram://",
        "twitter":   "twitter://",
        "x":         "twitter://",
        "facebook":  "fb://",
        "whatsapp":  "whatsapp://",
        "telegram":  "tg://",
        "slack":     "slack://",
    ]

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let raw = (args["appName"] ?? args["app"] ?? args["packageName"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'appName' argument")
        }
        let normalized = raw.lowercased().replacingOccurrences(of: " ", with: "-")
        // 1. Curated map. 2. Caller-supplied URL scheme as-is.
        let candidate = Self.appSchemes[normalized] ?? raw

        let urlString = candidate.contains(":") ? candidate : "\(candidate):"
        guard let url = URL(string: urlString) else {
            return ToolExecutionResult(success: false, error: "couldn't parse URL: \(urlString)")
        }
        return await MainActor.run {
            guard UIApplication.shared.canOpenURL(url) else {
                return ToolExecutionResult(
                    success: false,
                    error: "app not installed or scheme not registered: \(url.scheme ?? "?")")
            }
            UIApplication.shared.open(url, options: [:]) { _ in }
            return ToolExecutionResult(success: true, output: "Launched \(raw)")
        }
    }
}
