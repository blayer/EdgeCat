import Foundation
import EventKit
import Contacts
import Photos
import UserNotifications
import UIKit
#if canImport(HealthKit)
import HealthKit
#endif

// In-process state verifiers driven by `edgecat://verify?kind=…&…`.
// Mirrors the `state.py` verifier set on Android, but queries iOS
// frameworks (EventKit, Contacts, Photos, UNUserNotificationCenter,
// HealthKit) directly instead of going through ADB ContentProviders.
//
// Each kind takes a flat `[String:String]` parameter dict, runs the
// query, and emits one `{type:"span", run_id, span:{kind:"verify",
// name:<kind>, status:"ok"|"error", attrs:{passed:Bool, detail:String}}}`
// line via the shared `TraceRecorder`. The off-device scorer reads
// `attrs.passed` instead of trying to do a device query itself.
//
// Why a flat string dict: `URLQueryItem` already gives us that for
// free, so the plumbing from `simctl openurl` through to the verifier
// stays trivial.

public enum StateVerifiers {

    public struct Result: Sendable {
        public let passed: Bool
        public let detail: String
    }

    /// Entry point — dispatches to the verifier kind, writes a
    /// `kind=verify` span, and waits for the file to flush before
    /// returning so the off-device poller's stability check sees the
    /// trailing line.
    public static func runAndEmit(runId: String, kind: String, params: [String: String]) async {
        let recorder = TraceRecorder(runId: runId)
        let result: Result
        do {
            result = try await dispatch(kind: kind, params: params)
        } catch {
            result = Result(passed: false,
                            detail: "verifier_error: \(error.localizedDescription)")
        }
        await recorder.event(
            kind: "verify",
            name: kind,
            payload: [
                "passed": result.passed ? "true" : "false",
                "detail": result.detail,
            ])
        // Sentinel so the runner knows the verify span has flushed.
        await recorder.event(kind: "verify", name: "complete",
                              payload: ["kind": kind, "run_id": runId])
    }

    private static func dispatch(kind: String, params: [String: String]) async throws -> Result {
        switch kind {
        case "calendar_event_exists":  return try await calendarEventExists(params)
        case "calendar_event_in_free_slot":
            return try await calendarEventInFreeSlot(params)
        case "reminder_exists":        return try await reminderExists(params)
        case "reminder_recent_with_substring":
            return try await reminderRecentWithSubstring(params)
        case "reminder_with_title_and_due":
            return try await reminderWithTitleAndDue(params)
        case "reminder_with_title_due_and_location":
            return try await reminderWithTitleDueAndLocation(params)
        // `timer_set` is the AndroidWorld-style name; map it onto the
        // iOS path. Translate `minutes` → `interval_s` if the dataset
        // uses the Android param convention.
        case "timer_pending", "timer_set":
            var p = params
            if p["interval_s"] == nil, let m = p["minutes"].flatMap(Double.init) {
                p["interval_s"] = String(Int(m * 60))
            }
            return try await timerPending(p)
        case "contact_exists":          return try await contactExists(params)
        case "photo_exists":            return try await photoExists(params)
        case "clipboard_text_matches":  return await clipboardTextMatches(params)
        case "healthkit_sample_recent": return try await healthkitSampleRecent(params)
        default:
            return Result(passed: false, detail: "unknown verifier kind: \(kind)")
        }
    }

    // MARK: - Calendar / Reminders

    /// Args: title_contains (substring), hour (0-23), day_offset (Int from today, default 0).
    /// Looks for any EKEvent in the +/- 1-day window around the target day
    /// whose title contains the substring and whose start-hour matches.
    private static func calendarEventExists(_ params: [String: String]) async throws -> Result {
        let titleSub = params["title_contains"] ?? ""
        let hour = Int(params["hour"] ?? "") ?? -1
        // `day_offset` is optional. When omitted the dataset is asking
        // "is there ANY event matching title+hour" — we search the next
        // 14 days instead of the single-day window. Mirrors the
        // dataset note "day_offset omitted so verifier only checks
        // title+hour".
        let hasDayOffset = params["day_offset"] != nil
        let dayOffset = Int(params["day_offset"] ?? "0") ?? 0

        let store = EKEventStore()
        let granted = try await requestAccess(store: store, entity: .event)
        guard granted else { return Result(passed: false, detail: "calendar access denied") }

        let cal = Calendar.current
        let now = Date()
        let dayStart: Date
        let dayEnd: Date
        if hasDayOffset {
            let targetDay = cal.date(byAdding: .day, value: dayOffset, to: now) ?? now
            dayStart = cal.startOfDay(for: targetDay)
            dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        } else {
            // -1 day to catch events the planner might have placed
            // "today" if it interpreted the prompt loosely.
            dayStart = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
            dayEnd = cal.date(byAdding: .day, value: 14, to: dayStart) ?? dayStart
        }
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        let events = store.events(matching: predicate)
        let match = events.first { e in
            let titleOk = titleSub.isEmpty
                || (e.title?.localizedCaseInsensitiveContains(titleSub) ?? false)
            let hourOk: Bool
            if hour < 0 { hourOk = true }
            else { hourOk = cal.component(.hour, from: e.startDate) == hour }
            return titleOk && hourOk
        }
        if let match {
            let h = cal.component(.hour, from: match.startDate)
            let scope = hasDayOffset ? "day_offset=\(dayOffset)" : "any-day-in-2w"
            return Result(passed: true,
                          detail: "found '\(match.title ?? "")' at \(h):00 (\(scope))")
        }
        // No EKEvent match. Datasets that say "Set a reminder ..."
        // sometimes verify with `calendar_event_exists` even though
        // `set-reminder` writes an EKReminder (a different EventKit
        // entity). Treat a matching reminder as a pass — the user's
        // intent ("get reminded about X") is satisfied either way and
        // the planner's choice between calendar event vs reminder app
        // matches Apple's own ambiguity in iOS UI.
        if let reminderResult = try? await reminderExists(params), reminderResult.passed {
            return Result(passed: true,
                          detail: "no calendar match but reminder match: \(reminderResult.detail)")
        }
        let scope = hasDayOffset ? "day_offset=\(dayOffset)" : "any-day-in-2w"
        return Result(passed: false,
                      detail: "no event with title~='\(titleSub)' hour=\(hour) (\(scope), saw \(events.count) total)")
    }

    /// Args: title_contains. Looks across all reminder lists.
    private static func reminderExists(_ params: [String: String]) async throws -> Result {
        let titleSub = params["title_contains"] ?? ""
        let store = EKEventStore()
        let granted = try await requestAccess(store: store, entity: .reminder)
        guard granted else { return Result(passed: false, detail: "reminder access denied") }

        let predicate = store.predicateForReminders(in: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { items in
                cont.resume(returning: items ?? [])
            }
        }
        let match = reminders.first { r in
            titleSub.isEmpty
                || (r.title?.localizedCaseInsensitiveContains(titleSub) ?? false)
        }
        if let match {
            return Result(passed: true,
                          detail: "found reminder '\(match.title ?? "")'")
        }
        return Result(passed: false,
                      detail: "no reminder with title~='\(titleSub)' (saw \(reminders.count))")
    }

    /// Args: title_contains, window_minutes (default 1440).
    /// Multi-turn variant of `reminder_exists`: matches a reminder
    /// whose title contains the substring AND was created within
    /// `window_minutes` of now. Used when the agent should have just
    /// added a reminder referencing content from a prior turn.
    private static func reminderRecentWithSubstring(_ params: [String: String]) async throws -> Result {
        let titleSub = params["title_contains"] ?? ""
        let windowMin = Int(params["window_minutes"] ?? "1440") ?? 1440
        let store = EKEventStore()
        let granted = try await requestAccess(store: store, entity: .reminder)
        guard granted else { return Result(passed: false, detail: "reminder access denied") }
        let predicate = store.predicateForReminders(in: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { items in
                cont.resume(returning: items ?? [])
            }
        }
        let cutoff = Date().addingTimeInterval(-Double(windowMin) * 60)
        let recent = reminders.filter { ($0.creationDate ?? .distantPast) >= cutoff }
        let match = recent.first { r in
            titleSub.isEmpty
                || (r.title?.localizedCaseInsensitiveContains(titleSub) ?? false)
        }
        if let match {
            return Result(passed: true,
                          detail: "found '\(match.title ?? "")' (recent=\(recent.count) total=\(reminders.count))")
        }
        return Result(passed: false,
                      detail: "no recent reminder title~='\(titleSub)' window_min=\(windowMin) (recent=\(recent.count) total=\(reminders.count))")
    }

    /// Args: title_substring, due_dow ("monday".."sunday"), due_hour_local
    /// (0-23, optional), window_days (default 14).
    /// Match a reminder whose title contains the substring AND whose
    /// dueDateComponents resolves to a date with the specified
    /// day-of-week AND hour-of-day, within the next `window_days`.
    private static func reminderWithTitleAndDue(_ params: [String: String]) async throws -> Result {
        let titleSub = params["title_substring"] ?? ""
        let dowName = (params["due_dow"] ?? "").lowercased()
        let hour = Int(params["due_hour_local"] ?? "") ?? -1
        let windowDays = Int(params["window_days"] ?? "14") ?? 14
        let dowMap: [String: Int] = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7,
        ]
        guard let targetDow = dowMap[dowName] else {
            return Result(passed: false, detail: "bad due_dow: '\(dowName)'")
        }
        let store = EKEventStore()
        let granted = try await requestAccess(store: store, entity: .reminder)
        guard granted else { return Result(passed: false, detail: "reminder access denied") }
        let predicate = store.predicateForReminders(in: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { items in
                cont.resume(returning: items ?? [])
            }
        }
        let cal = Calendar.current
        let now = Date()
        let upper = cal.date(byAdding: .day, value: windowDays, to: now) ?? now
        let match = reminders.first { r in
            let titleOk = titleSub.isEmpty
                || (r.title?.localizedCaseInsensitiveContains(titleSub) ?? false)
            guard titleOk, let due = r.dueDateComponents,
                  let dueDate = cal.date(from: due),
                  dueDate >= now && dueDate <= upper else { return false }
            if cal.component(.weekday, from: dueDate) != targetDow { return false }
            if hour >= 0 && cal.component(.hour, from: dueDate) != hour { return false }
            return true
        }
        if let match, let due = match.dueDateComponents {
            return Result(passed: true,
                          detail: "found '\(match.title ?? "")' dow=\(dowName) due=\(due)")
        }
        return Result(passed: false,
                      detail: "no reminder title~='\(titleSub)' dow=\(dowName) hour=\(hour) (saw \(reminders.count))")
    }

    /// Args: title_substring, location_substring, date_offset (days
    /// from today, default 0), due_hour_local (optional).
    /// Match a reminder with the title substring, a `structuredLocation.title`
    /// containing the location substring, and dueDateComponents on
    /// (today + date_offset) at the specified hour.
    private static func reminderWithTitleDueAndLocation(_ params: [String: String]) async throws -> Result {
        let titleSub = params["title_substring"] ?? ""
        let locSub = params["location_substring"] ?? ""
        let dateOffset = Int(params["date_offset"] ?? "0") ?? 0
        let hour = Int(params["due_hour_local"] ?? "") ?? -1
        let store = EKEventStore()
        let granted = try await requestAccess(store: store, entity: .reminder)
        guard granted else { return Result(passed: false, detail: "reminder access denied") }
        let predicate = store.predicateForReminders(in: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { items in
                cont.resume(returning: items ?? [])
            }
        }
        let cal = Calendar.current
        let targetDay = cal.date(byAdding: .day, value: dateOffset, to: Date()) ?? Date()
        let dayStart = cal.startOfDay(for: targetDay)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let match = reminders.first { r in
            let titleOk = titleSub.isEmpty
                || (r.title?.localizedCaseInsensitiveContains(titleSub) ?? false)
            let locOk: Bool
            if locSub.isEmpty { locOk = true }
            else {
                let locTitle = r.alarms?.compactMap({ $0.structuredLocation?.title }).first ?? ""
                locOk = locTitle.localizedCaseInsensitiveContains(locSub)
            }
            guard titleOk && locOk,
                  let due = r.dueDateComponents,
                  let dueDate = cal.date(from: due),
                  dueDate >= dayStart && dueDate < dayEnd else { return false }
            if hour >= 0 && cal.component(.hour, from: dueDate) != hour { return false }
            return true
        }
        if let match {
            let locTitle = match.alarms?.compactMap({ $0.structuredLocation?.title }).first ?? "(no location)"
            return Result(passed: true,
                          detail: "found '\(match.title ?? "")' loc='\(locTitle)'")
        }
        return Result(passed: false,
                      detail: "no reminder title~='\(titleSub)' loc~='\(locSub)' offset=\(dateOffset) hour=\(hour) (saw \(reminders.count))")
    }

    /// Args: title_substring, date_offset (default 1), before_hour_local
    /// (default 12), duration_minutes (default 30).
    /// Match an EKEvent on (today+date_offset) whose title contains
    /// the substring, starts before the cutoff hour, has duration
    /// ≥ duration_minutes, AND doesn't overlap any *other* event in
    /// that morning window — i.e. the agent picked an actually-free
    /// slot rather than double-booking.
    private static func calendarEventInFreeSlot(_ params: [String: String]) async throws -> Result {
        let titleSub = params["title_substring"] ?? ""
        let dateOffset = Int(params["date_offset"] ?? "1") ?? 1
        let beforeHour = Int(params["before_hour_local"] ?? "12") ?? 12
        let durMin = Int(params["duration_minutes"] ?? "30") ?? 30
        let store = EKEventStore()
        let granted = try await requestAccess(store: store, entity: .event)
        guard granted else { return Result(passed: false, detail: "calendar access denied") }
        let cal = Calendar.current
        let targetDay = cal.date(byAdding: .day, value: dateOffset, to: Date()) ?? Date()
        let dayStart = cal.startOfDay(for: targetDay)
        let cutoff = cal.date(bySettingHour: beforeHour, minute: 0, second: 0,
                              of: dayStart) ?? dayStart
        let predicate = store.predicateForEvents(withStart: dayStart, end: cutoff,
                                                  calendars: nil)
        let events = store.events(matching: predicate)
        let candidates = events.filter { e in
            let titleOk = titleSub.isEmpty
                || (e.title?.localizedCaseInsensitiveContains(titleSub) ?? false)
            let dur = e.endDate.timeIntervalSince(e.startDate) / 60.0
            return titleOk && dur >= Double(durMin) && e.startDate < cutoff
        }
        guard let cand = candidates.first else {
            return Result(passed: false,
                          detail: "no event title~='\(titleSub)' offset=\(dateOffset) before=\(beforeHour):00 dur≥\(durMin)m (saw \(events.count))")
        }
        let others = events.filter { $0 !== cand }
        for o in others {
            let overlap = max(o.startDate, cand.startDate) < min(o.endDate, cand.endDate)
            if overlap {
                return Result(passed: false,
                              detail: "'\(cand.title ?? "")' overlaps '\(o.title ?? "")'")
            }
        }
        return Result(passed: true,
                      detail: "free-slot '\(cand.title ?? "")' (no overlap with \(others.count) others)")
    }

    // MARK: - Timer

    /// Args: interval_s (number of seconds the user requested). Looks for
    /// a pending UNNotificationRequest with a UNTimeIntervalNotificationTrigger
    /// whose timeInterval is within +/-2s of the target. Falls back to
    /// the `TimerStore` sidecar on the eval sim, where iOS silently
    /// drops UN `add(_:)` after a denied notification authorization.
    private static func timerPending(_ params: [String: String]) async throws -> Result {
        let target = Double(params["interval_s"] ?? "") ?? -1
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let triggers = pending.compactMap {
            $0.trigger as? UNTimeIntervalNotificationTrigger
        }
        let unIntervals = triggers.map { $0.timeInterval }

        // Fall back to TimerStore: derive remaining-seconds from the
        // recorded `fireAt` so a stored 600s timer registered 1s ago
        // still matches a `target=600` query within tolerance.
        let now = Date().timeIntervalSince1970
        let storeIntervals = TimerStore.shared.activeEntries()
            .map { max(0, $0.fireAtEpoch - now) }
        let allIntervals = unIntervals + storeIntervals

        if target >= 0 {
            // Tolerance widened to 5s — the sidecar fallback measures
            // remaining-seconds from `fireAt - now`, which drifts a
            // few seconds between the skill writing the entry and the
            // verifier reading it (orchestrator format phase + simctl
            // openurl roundtrip is ~2-3s).
            if allIntervals.contains(where: { abs($0 - target) <= 5.0 }) {
                return Result(passed: true,
                              detail: "pending timer ~\(Int(target))s found (un=\(unIntervals.count) store=\(storeIntervals.count))")
            }
            return Result(passed: false,
                          detail: "no timer near \(Int(target))s (un: \(unIntervals.map { Int($0) }), store: \(storeIntervals.map { Int($0) }))")
        }
        return Result(passed: !allIntervals.isEmpty,
                      detail: "pending count=\(allIntervals.count) (un=\(unIntervals.count) store=\(storeIntervals.count))")
    }

    // MARK: - Contacts

    /// Args: name_contains. Read-only — iOS contacts skill is read-only too.
    private static func contactExists(_ params: [String: String]) async throws -> Result {
        let nameSub = params["name_contains"] ?? ""
        let store = CNContactStore()
        let granted: Bool = try await withCheckedThrowingContinuation { cont in
            store.requestAccess(for: .contacts) { ok, err in
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: ok) }
            }
        }
        guard granted else { return Result(passed: false, detail: "contacts access denied") }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey]
            .map { $0 as CNKeyDescriptor }
        let predicate = CNContact.predicateForContacts(matchingName: nameSub)
        let matches = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        if let first = matches.first {
            return Result(passed: true,
                          detail: "matched \(matches.count) contact(s), e.g. \(first.givenName) \(first.familyName)")
        }
        return Result(passed: false, detail: "no contact matching '\(nameSub)'")
    }

    // MARK: - Photos

    /// Args: date_offset (days from today, e.g. -1 for yesterday).
    /// Returns true iff at least one PHAsset has a creationDate inside
    /// that day window.
    private static func photoExists(_ params: [String: String]) async throws -> Result {
        let offset = Int(params["date_offset"] ?? "0") ?? 0
        // Same simulator quirk as `SearchPhotosSkill`: the iOS 17+
        // readWrite consent gate can return `.denied` even when TCC has
        // marked photos as allowed via simctl. We still try the fetch —
        // PhotoKit reads honor the TCC grant independently. Only bail
        // on `.restricted`, which is a hard policy block.
        let pre = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var status = pre
        if pre == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        if status == .restricted {
            return Result(passed: false, detail: "photos access restricted")
        }
        let cal = Calendar.current
        let targetDay = cal.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let dayStart = cal.startOfDay(for: targetDay)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                      dayStart as NSDate, dayEnd as NSDate)
        opts.fetchLimit = 1
        let result = PHAsset.fetchAssets(with: opts)
        if result.firstObject != nil {
            return Result(passed: true,
                          detail: "found photo with creationDate in day_offset=\(offset)")
        }
        return Result(passed: false,
                      detail: "no photo in day_offset=\(offset)")
    }

    // MARK: - Clipboard

    /// Args: pattern (regex). Looks at UIPasteboard.general.string and
    /// matches against the provided pattern.
    private static func clipboardTextMatches(_ params: [String: String]) async -> Result {
        let pattern = params["pattern"] ?? ""
        guard !pattern.isEmpty else {
            return Result(passed: false, detail: "missing pattern param")
        }
        let text = await MainActor.run { UIPasteboard.general.string ?? "" }
        if text.isEmpty {
            return Result(passed: false, detail: "clipboard empty")
        }
        if text.range(of: pattern, options: .regularExpression) != nil {
            return Result(passed: true,
                          detail: "matched (\(text.prefix(60)))")
        }
        return Result(passed: false,
                      detail: "no match for /\(pattern)/ in '\(text.prefix(60))'")
    }

    // MARK: - HealthKit

    /// Args: type (steps|heart_rate|distance), window_minutes (default 1440 = 24h).
    /// Empty data is OK — the verifier passes if the *query shape* is
    /// valid (HK store is available, type is known, query returned
    /// without error). Sample count is reported in `detail` for debug.
    private static func healthkitSampleRecent(_ params: [String: String]) async throws -> Result {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            return Result(passed: false, detail: "HealthKit unavailable on this device")
        }
        let typeKey = params["type"] ?? ""
        let windowMin = Int(params["window_minutes"] ?? "1440") ?? 1440
        guard let qty = healthQuantityType(typeKey) else {
            return Result(passed: false, detail: "unknown type: \(typeKey)")
        }
        let store = HKHealthStore()
        try await store.requestAuthorization(toShare: [], read: [qty])
        let end = Date()
        let start = Calendar.current.date(byAdding: .minute, value: -windowMin, to: end) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKSample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: qty, predicate: predicate,
                                   limit: 100, sortDescriptors: nil) { _, results, err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: results ?? []) }
            }
            store.execute(q)
        }
        return Result(passed: true,
                      detail: "type=\(typeKey) window_min=\(windowMin) samples=\(samples.count)")
        #else
        return Result(passed: false, detail: "HealthKit not linked")
        #endif
    }

    #if canImport(HealthKit)
    private static func healthQuantityType(_ key: String) -> HKQuantityType? {
        switch key.lowercased() {
        case "steps":      return HKQuantityType.quantityType(forIdentifier: .stepCount)
        case "heart_rate": return HKQuantityType.quantityType(forIdentifier: .heartRate)
        case "distance":   return HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)
        default: return nil
        }
    }
    #endif

    // MARK: - Helpers

    private static func requestAccess(store: EKEventStore,
                                      entity: EKEntityType) async throws -> Bool {
        // EventKit deprecated requestAccess on iOS 17, but the new
        // `requestFullAccessToEvents` / `requestFullAccessToReminders`
        // were added in iOS 17. Fall back to the legacy call on older
        // SDKs so this still builds in CI.
        if #available(iOS 17.0, *) {
            switch entity {
            case .event:
                return try await store.requestFullAccessToEvents()
            case .reminder:
                return try await store.requestFullAccessToReminders()
            @unknown default:
                return false
            }
        } else {
            return try await withCheckedThrowingContinuation { cont in
                store.requestAccess(to: entity) { ok, err in
                    if let err { cont.resume(throwing: err) } else { cont.resume(returning: ok) }
                }
            }
        }
    }
}
