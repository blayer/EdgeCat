import Foundation
import EventKit

// 1:1 functional port of android-app/assets/skills/set-reminder. Creates a
// reminder in the system Reminders app. args: title (required), notes
// (optional), dueIso (optional ISO 8601 date).

public final class RemindersSkill: Skill, @unchecked Sendable {
    public var name: String { "set-reminder" }
    public var description: String { "Create a reminder. args: title, notes (optional), dueIso (optional ISO date)" }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let title = args["title"], !title.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'title' argument")
        }
        let store = EKEventStore()
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestFullAccessToReminders { ok, _ in cont.resume(returning: ok) }
        }
        guard granted else {
            return ToolExecutionResult(success: false, error: "reminders access denied")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = args["notes"]
        if let iso = args["dueIso"], let date = ISO8601DateFormatter().date(from: iso) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
        }
        reminder.calendar = store.defaultCalendarForNewReminders()
        do {
            try store.save(reminder, commit: true)
            return ToolExecutionResult(success: true, output: "created: \(title)")
        } catch {
            return ToolExecutionResult(success: false, error: "\(error)")
        }
    }
}
