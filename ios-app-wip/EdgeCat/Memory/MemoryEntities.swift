import Foundation
import SwiftData

// SwiftData @Model peers for the memory value types. Episode/Repair/Fact
// each gets its own entity. Substring-match search today; FTS5 wrapper is a
// follow-up (SwiftData has no FTS support so we'd drop to raw SQLite).

@Model
public final class EpisodeEntity {
    public var episodeId: String
    public var userMessage: String
    public var goal: String
    public var skillsUsedJson: String
    public var outcome: String
    public var stepCount: Int
    public var finalOutput: String
    public var createdAt: Date

    public init(episode: Episode) {
        self.episodeId = episode.id
        self.userMessage = episode.userMessage
        self.goal = episode.goal
        self.skillsUsedJson = (try? String(data: JSONEncoder().encode(episode.skillsUsed),
                                           encoding: .utf8)) ?? "[]"
        self.outcome = episode.outcome
        self.stepCount = episode.stepCount
        self.finalOutput = episode.finalOutput
        self.createdAt = Date()
    }

    public var asValue: Episode {
        let skills = (try? JSONDecoder().decode([String].self,
                                                from: Data(skillsUsedJson.utf8))) ?? []
        return Episode(id: episodeId, userMessage: userMessage, goal: goal,
                       skillsUsed: skills, outcome: outcome,
                       stepCount: stepCount, finalOutput: finalOutput)
    }
}

@Model
public final class RepairRecordEntity {
    public var repairId: String
    public var skillName: String
    public var errorSummary: String
    public var fixType: String
    public var fixDescription: String
    public var alternativeSkill: String?
    public var alternativeArgsJson: String
    public var success: Bool
    public var createdAt: Date

    public init(repair: RepairRecord) {
        self.repairId = repair.id
        self.skillName = repair.skillName
        self.errorSummary = repair.errorSummary
        self.fixType = repair.fixType
        self.fixDescription = repair.fixDescription
        self.alternativeSkill = repair.alternativeSkill
        self.alternativeArgsJson = (try? String(data: JSONEncoder().encode(repair.alternativeArgs),
                                                encoding: .utf8)) ?? "{}"
        self.success = repair.success
        self.createdAt = Date()
    }

    public var asValue: RepairRecord {
        let args = (try? JSONDecoder().decode([String: String].self,
                                              from: Data(alternativeArgsJson.utf8))) ?? [:]
        return RepairRecord(id: repairId, skillName: skillName, errorSummary: errorSummary,
                            fixType: fixType, fixDescription: fixDescription,
                            alternativeSkill: alternativeSkill, alternativeArgs: args,
                            success: success)
    }
}

@Model
public final class DeviceFactEntity {
    @Attribute(.unique) public var factKey: String
    public var factValue: String
    public var sourceEpisodeId: String?
    public var createdAt: Date

    public init(fact: DeviceFact) {
        self.factKey = fact.factKey
        self.factValue = fact.factValue
        self.sourceEpisodeId = fact.sourceEpisodeId
        self.createdAt = Date()
    }

    public var asValue: DeviceFact {
        DeviceFact(factKey: factKey, factValue: factValue, sourceEpisodeId: sourceEpisodeId)
    }
}
