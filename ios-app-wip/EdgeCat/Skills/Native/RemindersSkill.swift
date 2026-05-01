import Foundation
import EventKit

// Functional port of android-app/assets/skills/set-reminder, plus a
// `dueWhen` natural-language fallback so the planner doesn't have to
// pre-resolve relative dates ("next Friday at 5pm") into ISO via the
// calculator skill — calculator chokes on "TODAY + 7 days" and the
// run dies with `dependency unmet`. Letting the skill itself parse
// natural-language times short-circuits that whole class of failure.

public final class RemindersSkill: Skill, @unchecked Sendable {
    public var name: String { "set-reminder" }
    public var description: String {
        "Add a TO-DO item to the iOS Reminders app (NOT a calendar event, NOT a scheduled meeting). " +
        "Triggers: 'remind me to ...' (shopping list, errands, nudges), 'add to my list', " +
        "'don't let me forget to ...'. Pick this ONLY for items without a fixed meeting time " +
        "the user wants on their schedule. For 'add to calendar', 'schedule', 'book a meeting', " +
        "'set up an appointment', 'find a slot and add ...' use add-calendar-event instead. " +
        "args: title, notes (optional), dueIso (optional, strict ISO 8601 like '2026-05-01T17:00'), " +
        "dueWhen (optional, natural language like 'tomorrow at 5pm', 'next Friday', 'in 3 days'). " +
        "If you don't already have an ISO timestamp, prefer dueWhen — do NOT route through calculator."
    }
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
        if let due = Self.resolveDueDate(args: args) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        reminder.calendar = store.defaultCalendarForNewReminders()
        do {
            try store.save(reminder, commit: true)
            return ToolExecutionResult(success: true, output: "created: \(title)")
        } catch {
            return ToolExecutionResult(success: false, error: "\(error)")
        }
    }

    /// Resolve a due date from either `dueIso` (strict ISO 8601) or
    /// `dueWhen` (natural language via NSDataDetector). `dueIso` wins
    /// when both are present so an explicit timestamp isn't accidentally
    /// overridden by a leftover natural-language arg. Returns nil if
    /// neither is set or both fail to parse.
    static func resolveDueDate(args: [String: String]) -> Date? {
        if let iso = args["dueIso"], !iso.isEmpty {
            // Try strict ISO 8601 first, then common relaxations.
            if let d = ISO8601DateFormatter().date(from: iso) { return d }
            let formats = ["yyyy-MM-dd'T'HH:mm:ss",
                            "yyyy-MM-dd'T'HH:mm",
                            "yyyy-MM-dd HH:mm",
                            "yyyy-MM-dd"]
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            for fmt in formats {
                f.dateFormat = fmt
                if let d = f.date(from: iso) { return d }
            }
        }
        if let when = args["dueWhen"], !when.isEmpty {
            return parseNaturalDate(when)
        }
        return nil
    }

    /// `NSDataDetector(types: .date)` handles "tomorrow", "next Friday",
    /// "in 3 days", "5pm tomorrow", "May 5 at 9am", etc. The detector
    /// resolves relative phrases against `Date()`.
    private static func parseNaturalDate(_ text: String) -> Date? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let date = match.date else {
            return nil
        }
        return date
    }
}
