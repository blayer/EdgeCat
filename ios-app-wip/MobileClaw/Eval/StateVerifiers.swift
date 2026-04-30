import Foundation
import EventKit
import Contacts
import Photos
import UserNotifications
import UIKit
#if canImport(HealthKit)
import HealthKit
#endif

// In-process state verifiers driven by `mobileclaw://verify?kind=…&…`.
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
        case "reminder_exists":        return try await reminderExists(params)
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
