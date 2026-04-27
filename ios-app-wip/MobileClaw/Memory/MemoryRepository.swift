import Foundation

// 1:1 port of android-app/.../memory/MemoryRepository.kt — the protocol the
// orchestration module talks to. Two implementations: InMemory (eval +
// tests, no persistence) and SwiftData-backed (production).

public protocol MemoryRepository: Sendable {
    func save(episode: Episode) async
    func save(repair: RepairRecord) async
    func saveDeviceFact(key: String, value: String, sourceEpisodeId: String?) async
    func recallForPlanning(userMessage: String, tokenBudget: Int) async -> String
    func recallRepairs(skillName: String, error: String, limit: Int) async -> [RepairRecord]
    func getDeviceFacts() async -> [DeviceFact]
    func evictIfNeeded(maxSizeBytes: Int64) async
    func clearAll() async
}

public extension MemoryRepository {
    func recallForPlanning(userMessage: String) async -> String {
        await recallForPlanning(userMessage: userMessage, tokenBudget: 2048)
    }
    func recallRepairs(skillName: String, error: String) async -> [RepairRecord] {
        await recallRepairs(skillName: skillName, error: error, limit: 3)
    }
    func evictIfNeeded() async {
        await evictIfNeeded(maxSizeBytes: 100 * 1024 * 1024)
    }
}

/// Bridge so any `MemoryRepository` can serve as the orchestrator's
/// `MemoryProvider` without leaking the full repo surface (the
/// orchestration module only needs recall + save).
extension MemoryRepository {
    public var asMemoryProvider: MemoryProvider {
        MemoryRepositoryProvider(repo: self)
    }
}

private struct MemoryRepositoryProvider: MemoryProvider {
    let repo: MemoryRepository
    func recallForPlanning(userMessage: String) async -> String {
        await repo.recallForPlanning(userMessage: userMessage)
    }
    func saveEpisode(_ episode: OrchestrationEpisode) async {
        let ep = Episode(
            id: episode.id,
            userMessage: episode.userMessage,
            goal: episode.goal,
            skillsUsed: episode.skillsUsed,
            outcome: episode.outcome,
            stepCount: episode.skillsUsed.count,
            finalOutput: episode.finalOutput)
        await repo.save(episode: ep)
    }
}
