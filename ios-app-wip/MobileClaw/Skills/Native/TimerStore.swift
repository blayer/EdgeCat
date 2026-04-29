import Foundation

// Sidecar persistence for `TimerSkill`. Mirrors what
// `UNUserNotificationCenter.pendingNotificationRequests` returns, but
// survives the eval-sim case where iOS silently drops `add(_:)` after
// a denied notification authorization. Read by both `TimerSkill.list`
// and `StateVerifiers.timerPending` so the user-visible "what timers
// are scheduled?" answer matches across real-device and eval-sim
// deployments.
//
// File format: JSON array, one entry per scheduled timer. Expired
// entries are pruned on every read. Single shared instance — the file
// path is fixed so concurrent skill calls within a process serialize
// through the in-process lock, and across-process serialization isn't
// needed (skill runs are sequential per task).

public final class TimerStore: @unchecked Sendable {
    public static let shared = TimerStore()

    public struct Entry: Codable, Sendable {
        public let id: String
        public let label: String
        public let intervalS: Double
        public let fireAtEpoch: Double
        public var fireAt: Date { Date(timeIntervalSince1970: fireAtEpoch) }
    }

    private let url: URL
    private let queue = DispatchQueue(label: "TimerStore")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                             in: .userDomainMask).first!
        self.url = docs.appendingPathComponent("timer-store.json")
    }

    public func upsert(id: String, label: String, intervalS: Double, fireAt: Date) {
        queue.sync {
            var entries = readLocked().filter { $0.id != id }
            entries.append(Entry(id: id,
                                  label: label,
                                  intervalS: intervalS,
                                  fireAtEpoch: fireAt.timeIntervalSince1970))
            writeLocked(entries)
        }
    }

    public func remove(id: String) {
        queue.sync {
            writeLocked(readLocked().filter { $0.id != id })
        }
    }

    /// Active = fireAt is in the future (with 1s slack for clock skew).
    /// Expired entries are pruned from the file on read.
    public func activeEntries() -> [Entry] {
        queue.sync {
            let now = Date().timeIntervalSince1970
            let kept = readLocked().filter { $0.fireAtEpoch > now - 1 }
            writeLocked(kept)
            return kept
        }
    }

    // MARK: - Private (must be called inside `queue`)

    private func readLocked() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func writeLocked(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
