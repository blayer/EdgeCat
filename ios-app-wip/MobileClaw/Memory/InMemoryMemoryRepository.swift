import Foundation

// 1:1 port of android-app/.../memory/InMemoryMemoryRepository.kt — in-memory
// store used by the eval harness and unit tests so a run doesn't persist
// learning across runs.

public actor InMemoryMemoryRepository: MemoryRepository {
    private var episodes: [Episode] = []
    private var repairs: [RepairRecord] = []
    private var facts: [String: DeviceFact] = [:]

    public init() {}

    public func save(episode: Episode) async { episodes.append(episode) }
    public func save(repair: RepairRecord) async { repairs.append(repair) }

    public func saveDeviceFact(key: String, value: String, sourceEpisodeId: String?) async {
        facts[key] = DeviceFact(factKey: key, factValue: value, sourceEpisodeId: sourceEpisodeId)
    }

    public func recallForPlanning(userMessage: String, tokenBudget: Int) async -> String {
        let needle = userMessage.lowercased()
        let recent = episodes.suffix(20)
        let related = recent.filter { ep in
            ep.userMessage.lowercased().contains(needle) || ep.goal.lowercased().contains(needle)
        }.prefix(3)
        if related.isEmpty { return "" }
        return related.map { "Past: \($0.userMessage) → \($0.outcome) (\($0.skillsUsed.joined(separator: ", ")))" }
            .joined(separator: "\n")
    }

    public func recallRepairs(skillName: String, error: String, limit: Int) async -> [RepairRecord] {
        let needle = error.lowercased()
        return repairs.reversed().filter {
            $0.skillName == skillName && $0.errorSummary.lowercased().contains(needle)
        }.prefix(limit).map { $0 }
    }

    public func getDeviceFacts() async -> [DeviceFact] { Array(facts.values) }

    public func evictIfNeeded(maxSizeBytes: Int64) async {
        // Approximate sizing: cap counts. Faithful eviction lands when the
        // SwiftData impl needs it for real disk pressure.
        if episodes.count > 1000 { episodes.removeFirst(episodes.count - 1000) }
        if repairs.count > 1000 { repairs.removeFirst(repairs.count - 1000) }
    }

    public func clearAll() async {
        episodes.removeAll(); repairs.removeAll(); facts.removeAll()
    }
}
