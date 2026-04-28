import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

// HealthKit reader. iOS-platform-unique skill — Android has nothing
// equivalent (Health Connect requires API 34+ and a separate user grant
// flow). Reads a single metric over a window and returns both raw
// samples (capped) and a compact summary the planner can route into
// chat without hitting the LLM context budget.
//
// args:
//   metric         — steps | heart_rate | distance | sleep | workouts
//   window_days    — how far back to look (default 1, max 30)
//   max_samples    — cap on raw samples returned (default 50, max 500)
//
// On simulator: HealthKit data is empty by default. The skill still
// returns success with `samples: []` and zeroed summary — eval verifies
// the *query shape*, not data presence (see `StateVerifiers.healthkitSampleRecent`).

public final class ReadHealthSkill: Skill, @unchecked Sendable {
    public var name: String { "read-health" }
    public var description: String {
        "Read a HealthKit metric (steps, heart rate, distance, sleep, workouts) " +
        "over the last N days. " +
        "args: metric=<steps|heart_rate|distance|sleep|workouts>, " +
        "window_days=<N>, max_samples=<N>"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            return ToolExecutionResult(success: false,
                                        error: "HealthKit unavailable on this device")
        }
        let metric = (args["metric"] ?? "steps").lowercased()
        let windowDays = max(1, min(args["window_days"].flatMap(Int.init) ?? 1, 30))
        let maxSamples = max(1, min(args["max_samples"].flatMap(Int.init) ?? 50, 500))

        let store = HKHealthStore()
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -windowDays, to: end) ?? end

        do {
            switch metric {
            case "steps":
                return try await runQuantity(store: store, identifier: .stepCount,
                                              unit: .count(),
                                              start: start, end: end,
                                              metric: metric,
                                              maxSamples: maxSamples)
            case "heart_rate":
                return try await runQuantity(store: store, identifier: .heartRate,
                                              unit: HKUnit.count().unitDivided(by: .minute()),
                                              start: start, end: end,
                                              metric: metric,
                                              maxSamples: maxSamples)
            case "distance":
                return try await runQuantity(store: store, identifier: .distanceWalkingRunning,
                                              unit: .meter(),
                                              start: start, end: end,
                                              metric: metric,
                                              maxSamples: maxSamples)
            case "sleep":
                return try await runSleep(store: store,
                                          start: start, end: end,
                                          maxSamples: maxSamples)
            case "workouts":
                return try await runWorkouts(store: store,
                                             start: start, end: end,
                                             maxSamples: maxSamples)
            default:
                return ToolExecutionResult(success: false,
                                            error: "unknown metric: \(metric). " +
                                                "valid: steps, heart_rate, distance, sleep, workouts")
            }
        } catch {
            return ToolExecutionResult(success: false,
                                        error: "healthkit query failed: \(error.localizedDescription)")
        }
        #else
        return ToolExecutionResult(success: false,
                                    error: "HealthKit not linked")
        #endif
    }

    #if canImport(HealthKit)

    // swiftlint:disable:next function_parameter_count
    private func runQuantity(store: HKHealthStore,
                             identifier: HKQuantityTypeIdentifier,
                             unit: HKUnit,
                             start: Date, end: Date,
                             metric: String,
                             maxSamples: Int) async throws -> ToolExecutionResult {
        guard let qty = HKQuantityType.quantityType(forIdentifier: identifier) else {
            return ToolExecutionResult(success: false,
                                        error: "no quantity type for \(metric)")
        }
        try await store.requestAuthorization(toShare: [], read: [qty])
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: qty, predicate: predicate,
                                   limit: maxSamples,
                                   sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                       ascending: false)]) { _, results, err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: (results as? [HKQuantitySample]) ?? []) }
            }
            store.execute(q)
        }
        let isoFmt = ISO8601DateFormatter()
        let samplesOut = samples.map { s -> [String: Any] in
            [
                "start": isoFmt.string(from: s.startDate),
                "end": isoFmt.string(from: s.endDate),
                "value": s.quantity.doubleValue(for: unit),
            ]
        }
        let total = samples.reduce(0.0) { $0 + $1.quantity.doubleValue(for: unit) }
        let avg = samples.isEmpty ? 0.0 : total / Double(samples.count)
        let payload: [String: Any] = [
            "status": "succeeded",
            "metric": metric,
            "window_start": isoFmt.string(from: start),
            "window_end": isoFmt.string(from: end),
            "unit": unit.unitString,
            "sample_count": samples.count,
            "summary": [
                "total": total,
                "avg": avg,
            ],
            "samples": samplesOut,
        ]
        return jsonResult(payload)
    }

    private func runSleep(store: HKHealthStore,
                          start: Date, end: Date,
                          maxSamples: Int) async throws -> ToolExecutionResult {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return ToolExecutionResult(success: false, error: "no sleepAnalysis type")
        }
        try await store.requestAuthorization(toShare: [], read: [sleepType])
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: sleepType, predicate: predicate,
                                   limit: maxSamples,
                                   sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                       ascending: false)]) { _, results, err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: (results as? [HKCategorySample]) ?? []) }
            }
            store.execute(q)
        }
        let isoFmt = ISO8601DateFormatter()
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let asleepSeconds = samples
            .filter { asleepValues.contains($0.value) }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        let samplesOut = samples.map { s -> [String: Any] in
            [
                "start": isoFmt.string(from: s.startDate),
                "end": isoFmt.string(from: s.endDate),
                "value": s.value,
            ]
        }
        let payload: [String: Any] = [
            "status": "succeeded",
            "metric": "sleep",
            "window_start": isoFmt.string(from: start),
            "window_end": isoFmt.string(from: end),
            "sample_count": samples.count,
            "summary": [
                "asleep_minutes": Int(asleepSeconds / 60),
            ],
            "samples": samplesOut,
        ]
        return jsonResult(payload)
    }

    private func runWorkouts(store: HKHealthStore,
                             start: Date, end: Date,
                             maxSamples: Int) async throws -> ToolExecutionResult {
        let workoutType = HKObjectType.workoutType()
        try await store.requestAuthorization(toShare: [], read: [workoutType])
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: workoutType, predicate: predicate,
                                   limit: maxSamples,
                                   sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                       ascending: false)]) { _, results, err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume(returning: (results as? [HKWorkout]) ?? []) }
            }
            store.execute(q)
        }
        let isoFmt = ISO8601DateFormatter()
        let samplesOut = workouts.map { w -> [String: Any] in
            [
                "start": isoFmt.string(from: w.startDate),
                "end": isoFmt.string(from: w.endDate),
                "activity": w.workoutActivityType.rawValue,
                "duration_s": w.duration,
            ]
        }
        let totalDuration = workouts.reduce(0.0) { $0 + $1.duration }
        let payload: [String: Any] = [
            "status": "succeeded",
            "metric": "workouts",
            "window_start": isoFmt.string(from: start),
            "window_end": isoFmt.string(from: end),
            "sample_count": workouts.count,
            "summary": [
                "total_duration_s": Int(totalDuration),
            ],
            "samples": samplesOut,
        ]
        return jsonResult(payload)
    }

    private func jsonResult(_ payload: [String: Any]) -> ToolExecutionResult {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolExecutionResult(success: true, output: data)
    }

    #endif
}
