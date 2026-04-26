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
