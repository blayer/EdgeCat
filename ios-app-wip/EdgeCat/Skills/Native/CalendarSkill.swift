import Foundation
import EventKit

// 1:1 functional port of android-app/assets/skills/calendar (both
// sides). Android's `manageCalendar` is one skill with an `action`
// arg covering reads and writes; we keep the same shape on iOS so the
// planner emits the same skill name across platforms. The previous
// split into separate `calendar` (read) + `add-calendar-event` (write)
// skills caused the planner to pick a name not in the dataset's
// expected_skills, even though the action was correct.

public final class CalendarSkill: Skill, @unchecked Sendable {
    public var name: String { "calendar" }
    public var description: String {
        "Read upcoming events or add a new event in the user's calendar. " +
        "args (read, default): action=read, days=7 (how many days ahead to look). " +
        "args (add): action=add, title=<required>, " +
        "startIso=<ISO 8601 e.g. 2026-04-29T14:00> OR " +
        "whenText=<natural language like 'tomorrow at 10am', 'next Friday 3pm'; " +
        "do NOT route through calculator>, " +
        "durationMin=<N, default 30>, notes=<optional>, location=<optional>. " +
        "Use action=add for 'add an event / schedule a meeting / book / put on " +
        "calendar / find a slot' tasks; use the default action=read for 'what's " +
        "on my calendar' tasks. For Reminders-app to-dos use set-reminder, NOT this skill."
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let action = (args["action"] ?? "read").lowercased()
        switch action {
        case "read", "list":
            return await readEvents(args: args)
        case "add", "create", "write":
            return await addEvent(args: args)
        default:
            return ToolExecutionResult(success: false,
                                       error: "unknown action '\(action)' — expected read|add")
        }
    }

    // MARK: - Read

    private func readEvents(args: [String: String]) async -> ToolExecutionResult {
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

    // MARK: - Add

    private func addEvent(args: [String: String]) async -> ToolExecutionResult {
        guard let title = args["title"], !title.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'title' argument")
        }
        guard let startDate = resolveStartDate(args: args) else {
            return ToolExecutionResult(success: false,
                                       error: "missing or unparseable start time (need startIso ISO 8601 or whenText natural-language)")
        }
        let durationMin = max(1, Int(args["durationMin"] ?? "30") ?? 30)
        let endDate = Calendar.current.date(byAdding: .minute,
                                            value: durationMin,
                                            to: startDate) ?? startDate

        let store = EKEventStore()
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestFullAccessToEvents { ok, _ in cont.resume(returning: ok) }
        }
        guard granted else {
            return ToolExecutionResult(success: false, error: "calendar access denied")
        }
        guard let cal = store.defaultCalendarForNewEvents else {
            return ToolExecutionResult(success: false,
                                       error: "no default calendar available")
        }

        let event = EKEvent(eventStore: store)
        event.calendar = cal
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        if let notes = args["notes"], !notes.isEmpty { event.notes = notes }
        if let loc = args["location"], !loc.isEmpty { event.location = loc }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return ToolExecutionResult(success: false,
                                       error: "couldn't save event: \(error.localizedDescription)")
        }
        let isoOut = ISO8601DateFormatter().string(from: startDate)
        let payload: [String: Any] = [
            "status": "succeeded",
            "title": title,
            "start": isoOut,
            "duration_min": durationMin,
            "calendar": cal.title,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolExecutionResult(success: true, output: json)
    }

    /// Pick a start date from `startIso` (preferred) or `whenText`
    /// (natural-language fallback parsed by NSDataDetector). Mirrors
    /// AddCalendarEventSkill so both calendar entry-points accept the
    /// same args.
    private func resolveStartDate(args: [String: String]) -> Date? {
        if let iso = args["startIso"], !iso.isEmpty,
           let d = parseIso(iso) {
            return d
        }
        if let when = args["whenText"], !when.isEmpty,
           let detector = try? NSDataDetector(
             types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(when.startIndex..., in: when)
            if let match = detector.firstMatch(in: when, options: [], range: range),
               let date = match.date {
                return date
            }
        }
        return nil
    }

    private func parseIso(_ s: String) -> Date? {
        // Accept three common shapes: with seconds + Z, with seconds + offset,
        // or just date+hour+minute (treated as local time).
        let isoZ = ISO8601DateFormatter()
        if let d = isoZ.date(from: s) { return d }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: s) { return d }
        // Local-naive form: "2026-04-29T14:00" → treat as local time.
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        local.timeZone = .current
        local.locale = Locale(identifier: "en_US_POSIX")
        if let d = local.date(from: s) { return d }
        // "2026-04-29T14:00:00" with no Z, also local.
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = local.date(from: s) { return d }
        return nil
    }
}
