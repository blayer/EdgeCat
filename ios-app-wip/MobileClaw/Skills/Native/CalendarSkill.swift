import Foundation
import EventKit

// 1:1 functional port of android-app/assets/skills/calendar (read side).
// EventKit access is permission-gated; we ask once, then fall back to a
// not-supported error if denied.

public final class CalendarSkill: Skill, @unchecked Sendable {
    public var name: String { "calendar" }
    public var description: String { "List upcoming calendar events for the next N days. args: days=7 (optional)" }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let store = EKEventStore()
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestFullAccessToEvents { ok, _ in cont.resume(returning: ok) }
        }
        guard granted else {
            return ToolExecutionResult(success: false, error: "calendar access denied")
        }
        let days = Int(args["days"] ?? "7") ?? 7
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate).prefix(25)
        if events.isEmpty {
            return ToolExecutionResult(success: true, output: "no upcoming events")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short; formatter.timeStyle = .short
        let out = events.map { ev in
            "\(formatter.string(from: ev.startDate)) — \(ev.title ?? "(untitled)")"
        }.joined(separator: "\n")
        return ToolExecutionResult(success: true, output: out)
    }
}
