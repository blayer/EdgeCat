import Foundation
import UserNotifications

// Mirrors android-app/.../DeviceSkills.manageTimer. iOS doesn't expose
// the system Clock app's timer programmatically, so we approximate by
// scheduling a local notification at +N seconds via
// UNUserNotificationCenter. The user gets a banner + sound when the
// timer fires; cancel removes the pending notification.
//
// args:
//   action  = "start" | "cancel" | "list"
//   seconds = number of seconds (start only) — alternative: `minutes`
//   label   = optional name shown in the notification (start)
//   id      = identifier to cancel (cancel only) — uses `label` when omitted

public final class TimerSkill: Skill, @unchecked Sendable {
    public var name: String { "timer" }
    public var description: String {
        "Schedule a timer (delivered as a local notification on iOS). " +
        "ALWAYS schedules immediately — there is no pause / preview mode. " +
        "If the user says 'set a 5 minute timer but don't start it', schedule it anyway and explain to them that iOS timers always start; offer to cancel via action=cancel if needed. " +
        "args: action=start|cancel|list (default start), seconds=N (or minutes=N), label=<name>"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let action = (args["action"] ?? "start").lowercased()
        switch action {
        case "start":
            return await start(args: args)
        case "cancel", "stop":
            return await cancel(args: args)
        case "list":
            return await list()
        default:
            return ToolExecutionResult(success: false,
                                       error: "unknown action '\(action)' — expected start|cancel|list")
        }
    }

    private func start(args: [String: String]) async -> ToolExecutionResult {
        let seconds: TimeInterval
        if let s = args["seconds"].flatMap(Double.init), s > 0 {
            seconds = s
        } else if let m = args["minutes"].flatMap(Double.init), m > 0 {
            seconds = m * 60
        } else {
            return ToolExecutionResult(success: false,
                                       error: "missing 'seconds' or 'minutes' argument")
        }
        let label = (args["label"].flatMap { $0.isEmpty ? nil : $0 }) ?? "Timer"
        let id = (args["id"].flatMap { $0.isEmpty ? nil : $0 }) ?? label

        let center = UNUserNotificationCenter.current()
        // Include `.provisional` so headless surfaces (eval harness on
        // the simulator) get auto-grant without a user-facing dialog.
        // On real devices `.provisional` is silently approved and the
        // user can promote to "prominent" later from Settings; for the
        // eval the timer still schedules correctly. iOS 12+.
        let granted: Bool = await withCheckedContinuation { cont in
            center.requestAuthorization(options: [.alert, .sound, .provisional]) { ok, _ in
                cont.resume(returning: ok)
            }
        }
        guard granted else {
            return ToolExecutionResult(success: false,
                                       error: "notification permission denied — required to deliver timers on iOS")
        }
        let content = UNMutableNotificationContent()
        content.title = label
        content.body = "\(label) finished"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        do {
            try await center.add(request)
            let mins = Int((seconds / 60).rounded())
            let pretty = mins >= 1 ? "\(mins)m" : "\(Int(seconds))s"
            return ToolExecutionResult(
                success: true,
                output: "Timer '\(label)' set for \(pretty) (id=\(id))")
        } catch {
            return ToolExecutionResult(success: false,
                                       error: "couldn't schedule timer: \(error.localizedDescription)")
        }
    }

    private func cancel(args: [String: String]) async -> ToolExecutionResult {
        let id = args["id"] ?? args["label"] ?? ""
        guard !id.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'id' or 'label' to cancel")
        }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])
        return ToolExecutionResult(success: true, output: "Cancelled timer '\(id)'")
    }

    private func list() async -> ToolExecutionResult {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let timers = pending.filter { $0.trigger is UNTimeIntervalNotificationTrigger }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let lines = timers.map { req -> String in
            let trigger = req.trigger as? UNTimeIntervalNotificationTrigger
            let fireAt = trigger?.nextTriggerDate().map { formatter.string(from: $0) } ?? "?"
            return "- \(req.identifier): fires at \(fireAt) (\(req.content.title))"
        }
        let output = lines.isEmpty ? "No active timers." : lines.joined(separator: "\n")
        return ToolExecutionResult(success: true, output: output)
    }
}
