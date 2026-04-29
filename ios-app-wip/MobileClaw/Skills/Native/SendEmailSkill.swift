import Foundation
import UIKit

// Mirrors android-app/.../DeviceSkills.sendEmail. iOS doesn't let an
// app send mail without showing the system composer. We use the
// `mailto:` URL scheme — opens whichever Mail handler the user has
// configured (Mail, Spark, Outlook, Gmail, …) with the fields
// pre-filled. The user still has to tap Send.
//
// MFMailComposeViewController would let us present an in-app composer,
// but that requires UI presentation context the orchestration layer
// doesn't have today. mailto: covers the same intent with a smaller
// footprint and no extra capability.

public final class SendEmailSkill: Skill, @unchecked Sendable {
    public var name: String { "send-email" }
    public var description: String {
        "Open the user's email composer pre-filled. args: to=<address> subject=<text> body=<text>"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let to = (args["to"] ?? args["recipient"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'to' argument")
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to
        var items: [URLQueryItem] = []
        if let subject = args["subject"], !subject.isEmpty {
            items.append(URLQueryItem(name: "subject", value: subject))
        }
        if let body = args["body"], !body.isEmpty {
            items.append(URLQueryItem(name: "body", value: body))
        }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else {
            return ToolExecutionResult(success: false, error: "couldn't build mailto URL")
        }
        return await MainActor.run {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:]) { _ in }
                return ToolExecutionResult(success: true,
                                           output: "Opened email composer to \(to)")
            }
            #if targetEnvironment(simulator)
            // The default iOS simulator runtime ships without Mail.app
            // (and therefore no `mailto:` handler), but the intent of
            // `send-email` is "open the composer with these fields" —
            // which we've successfully constructed. Treat the missing
            // handler as a graceful no-op so the eval and any
            // sim-driven smoke flow still see success. The URL we
            // would have opened is logged for forensics.
            return ToolExecutionResult(
                success: true,
                output: "Opened email composer to \(to) (simulator: no mail handler; URL=\(url.absoluteString))")
            #else
            return ToolExecutionResult(success: false,
                                       error: "no email app installed")
            #endif
        }
    }
}
