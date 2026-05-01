import Foundation
import EventKit

// Creates an EKEvent in the user's default calendar. Companion to the
// existing read-only `calendar` skill — and distinct from `set-reminder`,
// which writes an EKReminder (a different EventKit entity that doesn't
// appear in the Calendar app).
//
// The split mirrors Android's `manageCalendar` with `action=create`, but
// kept as a separate skill name so the planner doesn't need to learn an
// action-arg switch.
//
// args:
//   title       — required
//   startIso    — preferred when caller has a precise ISO 8601 timestamp
//                  (e.g. "2026-04-29T14:00" or "2026-04-29T14:00:00Z").
//                  Local time if no offset.
//   whenText    — natural-language fallback ("tomorrow at 10am", "next Friday
//                  3pm", "in 2 hours"). Parsed via NSDataDetector. Use this
//                  when the planner would otherwise route a relative date
//                  through calculator (which can't parse date arithmetic).
//                  If both are set, startIso wins.
//   durationMin — optional, default 30. The event runs from start time
//                  for this many minutes.
//   notes       — optional event notes/body
//   location    — optional location string

public final class AddCalendarEventSkill: Skill, @unchecked Sendable {
    public var name: String { "add-calendar-event" }
    public var description: String {
        "Create a new event in the user's calendar. Use this for " +
        "appointments, meetings, dentist visits — anything that " +
        "appears in the Calendar app. Distinct from set-reminder " +
        "(which creates a Reminders-app to-do, not a calendar entry). " +
        "args: title=<required>, startIso=<ISO 8601 e.g. 2026-04-29T14:00>, " +
        "whenText=<natural language like 'tomorrow at 10am' if you don't have ISO; " +
        "do NOT route through calculator>, " +
        "durationMin=<N, default 30>, notes=<optional>, location=<optional>"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let title = args["title"], !title.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'title' argument")
        }
        guard let startDate = Self.resolveStartDate(args: args) else {
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
    /// (natural-language fallback parsed by NSDataDetector). The
    /// fallback exists so the planner doesn't have to compute relative
    /// dates via calculator — calculator can't parse "tomorrow + 1 day"
    /// and the run dies with `dependency unmet`.
    static func resolveStartDate(args: [String: String]) -> Date? {
        if let iso = args["startIso"], !iso.isEmpty,
           let d = parseIsoStatic(iso) {
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

    static func parseIsoStatic(_ s: String) -> Date? {
        let isoZ = ISO8601DateFormatter()
        if let d = isoZ.date(from: s) { return d }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: s) { return d }
        let local = DateFormatter()
        local.timeZone = .current
        local.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm",
                     "yyyy-MM-dd'T'HH:mm:ss",
                     "yyyy-MM-dd HH:mm",
                     "yyyy-MM-dd"] {
            local.dateFormat = fmt
            if let d = local.date(from: s) { return d }
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
