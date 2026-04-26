import Foundation
import SwiftData

// SwiftData-backed MemoryRepository. Substring matching today; an FTS5
// indexed companion table comes later when search recall budget matters.

@MainActor
public final class SwiftDataMemoryRepository: MemoryRepository {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public nonisolated func save(episode: Episode) async {
        await MainActor.run {
            context.insert(EpisodeEntity(episode: episode))
            try? context.save()
        }
    }

    public nonisolated func save(repair: RepairRecord) async {
        await MainActor.run {
            context.insert(RepairRecordEntity(repair: repair))
            try? context.save()
        }
    }

    public nonisolated func saveDeviceFact(key: String, value: String, sourceEpisodeId: String?) async {
        await MainActor.run {
            // Upsert by factKey.
            let descriptor = FetchDescriptor<DeviceFactEntity>(
                predicate: #Predicate { $0.factKey == key }
            )
            if let existing = (try? context.fetch(descriptor))?.first {
                existing.factValue = value
                existing.sourceEpisodeId = sourceEpisodeId
            } else {
                context.insert(DeviceFactEntity(fact: DeviceFact(factKey: key, factValue: value, sourceEpisodeId: sourceEpisodeId)))
            }
            try? context.save()
        }
    }

    public nonisolated func recallForPlanning(userMessage: String, tokenBudget: Int) async -> String {
        await MainActor.run {
            let descriptor = FetchDescriptor<EpisodeEntity>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let recent = (try? context.fetch(descriptor))?.prefix(40) ?? []
            let needle = userMessage.lowercased()
            let related = recent.filter {
                $0.userMessage.lowercased().contains(needle) || $0.goal.lowercased().contains(needle)
            }.prefix(3)
            if related.isEmpty { return "" }
            return related.map { e in
                "Past: \(e.userMessage) → \(e.outcome)"
            }.joined(separator: "\n")
        }
    }

    public nonisolated func recallRepairs(skillName: String, error: String, limit: Int) async -> [RepairRecord] {
        await MainActor.run {
            let descriptor = FetchDescriptor<RepairRecordEntity>(
                predicate: #Predicate { $0.skillName == skillName },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let recent = (try? context.fetch(descriptor)) ?? []
            let needle = error.lowercased()
            return recent.filter { $0.errorSummary.lowercased().contains(needle) }
                .prefix(limit)
                .map { $0.asValue }
        }
    }

    public nonisolated func getDeviceFacts() async -> [DeviceFact] {
        await MainActor.run {
            let descriptor = FetchDescriptor<DeviceFactEntity>()
            return ((try? context.fetch(descriptor)) ?? []).map { $0.asValue }
        }
    }

    public nonisolated func evictIfNeeded(maxSizeBytes: Int64) async {
        await MainActor.run {
            // Keep counts bounded; size-based eviction is a follow-up.
            let cap = 1000
            if let eps = try? context.fetch(FetchDescriptor<EpisodeEntity>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)])),
               eps.count > cap {
                eps.prefix(eps.count - cap).forEach { context.delete($0) }
            }
            if let reps = try? context.fetch(FetchDescriptor<RepairRecordEntity>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)])),
               reps.count > cap {
                reps.prefix(reps.count - cap).forEach { context.delete($0) }
            }
            try? context.save()
        }
    }

    public nonisolated func clearAll() async {
        await MainActor.run {
            (try? context.fetch(FetchDescriptor<EpisodeEntity>()))?.forEach { context.delete($0) }
            (try? context.fetch(FetchDescriptor<RepairRecordEntity>()))?.forEach { context.delete($0) }
            (try? context.fetch(FetchDescriptor<DeviceFactEntity>()))?.forEach { context.delete($0) }
            try? context.save()
        }
    }
}
