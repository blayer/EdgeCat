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
        "whenText=<natural language like 'tomorrow at 10am', 'next Friday 3pm'>, " +
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
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: days, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = Array(store.events(matching: predicate).prefix(25))

        let dtFmt = DateFormatter()
        dtFmt.dateFormat = "yyyy-MM-dd HH:mm"
        dtFmt.timeZone = .current

        var sections: [String] = []
        if events.isEmpty {
            sections.append("EVENTS: (none in next \(days) days)")
        } else {
            let evLines = events.map { ev -> String in
                let s = dtFmt.string(from: ev.startDate)
                let e = dtFmt.string(from: ev.endDate)
                return "- \(s) – \(e) — \(ev.title ?? "(untitled)")"
            }
            sections.append("EVENTS (start – end — title):")
            sections.append(evLines.joined(separator: "\n"))
        }

        // Surface FREE morning slots for tomorrow + the next two days
        // so the planner doesn't have to reason about gaps from raw
        // events. Window: 08:00–12:00 local, slots ≥ 30 min. The
        // free-slot output is what unblocks "find a free slot before
        // noon and add X" requests on small models — they were
        // concluding "no slots available" from the events list alone.
        let freeBlocks = morningFreeSlots(
            store: store, daysAhead: min(3, max(1, days)), cal: cal, now: now)
        if !freeBlocks.isEmpty {
            sections.append("")
            sections.append("FREE MORNING SLOTS (≥30 min, 08:00–12:00 local):")
            sections.append(freeBlocks.joined(separator: "\n"))
        }
        return ToolExecutionResult(success: true,
                                    output: sections.joined(separator: "\n"))
    }

    /// Compute free morning windows (≥30 min, 08:00–12:00 local) for
    /// each of the next `daysAhead` days. Each line surfaces a
    /// ready-to-paste `startIso=yyyy-MM-ddTHH:mm` so the planner
    /// doesn't have to assemble a timestamp itself — small models
    /// were fabricating the start arg ("now-ish") even when the gap
    /// was visible in the human-readable form.
    private func morningFreeSlots(store: EKEventStore,
                                  daysAhead: Int,
                                  cal: Calendar,
                                  now: Date) -> [String] {
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.timeZone = .current
        let hmFmt = DateFormatter()
        hmFmt.dateFormat = "HH:mm"
        hmFmt.timeZone = .current
        let isoFmt = DateFormatter()
        isoFmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        isoFmt.timeZone = .current

        var lines: [String] = []
        for offset in 1...max(1, daysAhead) {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            let dayStart = cal.startOfDay(for: day)
            guard let windowStart = cal.date(bySettingHour: 8, minute: 0, second: 0,
                                              of: dayStart),
                  let windowEnd = cal.date(bySettingHour: 12, minute: 0, second: 0,
                                            of: dayStart) else { continue }
            let predicate = store.predicateForEvents(
                withStart: windowStart, end: windowEnd, calendars: nil)
            let dayEvents = store.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
            var cursor = windowStart
            for ev in dayEvents {
                let evStart = max(ev.startDate, windowStart)
                if cursor < evStart {
                    let mins = Int(evStart.timeIntervalSince(cursor) / 60)
                    if mins >= 30 {
                        lines.append(formatSlot(start: cursor, end: evStart,
                                                 dayFmt: dayFmt, hmFmt: hmFmt, isoFmt: isoFmt))
                    }
                }
                cursor = max(cursor, ev.endDate)
            }
            if cursor < windowEnd {
                let mins = Int(windowEnd.timeIntervalSince(cursor) / 60)
                if mins >= 30 {
                    lines.append(formatSlot(start: cursor, end: windowEnd,
                                             dayFmt: dayFmt, hmFmt: hmFmt, isoFmt: isoFmt))
                }
            }
        }
        return lines
    }

    private func formatSlot(start: Date, end: Date,
                            dayFmt: DateFormatter,
                            hmFmt: DateFormatter,
                            isoFmt: DateFormatter) -> String {
        let mins = Int(end.timeIntervalSince(start) / 60)
        // Format: "- 2026-05-02 08:00–10:00 (120m free) → startIso=2026-05-02T08:00"
        // The arrow + key=value pair gives the planner a literal
        // string to lift into toolArgs; the leading human-readable
        // form keeps the trace readable.
        return "- \(dayFmt.string(from: start)) "
             + "\(hmFmt.string(from: start))–\(hmFmt.string(from: end)) "
             + "(\(mins)m free) → startIso=\(isoFmt.string(from: start))"
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
