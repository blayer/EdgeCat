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
//   startIso    — required, ISO 8601 (e.g. "2026-04-29T14:00" or
//                  "2026-04-29T14:00:00Z"). Local time if no offset.
//   durationMin — optional, default 30. The event runs from startIso
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
        "durationMin=<N, default 30>, notes=<optional>, location=<optional>"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let title = args["title"], !title.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'title' argument")
        }
        guard let startIso = args["startIso"], !startIso.isEmpty else {
            return ToolExecutionResult(success: false,
                                       error: "missing 'startIso' argument (ISO 8601 datetime)")
        }
        guard let startDate = parseIso(startIso) else {
            return ToolExecutionResult(success: false,
                                       error: "couldn't parse startIso: '\(startIso)' (expected ISO 8601)")
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
        let payload: [String: Any] = [
            "status": "succeeded",
            "title": title,
            "start": startIso,
            "duration_min": durationMin,
            "calendar": cal.title,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolExecutionResult(success: true, output: json)
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
