import Foundation

// 1:1 port of android-app/.../memory/MemoryTypes.kt — value types the
// orchestration layer uses to consult / record long-term memory.

public struct Episode: Sendable, Equatable, Codable {
    public let id: String
    public let userMessage: String
    public let goal: String
    public let skillsUsed: [String]
    public let outcome: String  // "success" | "partial" | "failure"
    public let stepCount: Int
    public let finalOutput: String

    public init(id: String = UUID().uuidString, userMessage: String, goal: String,
                skillsUsed: [String], outcome: String, stepCount: Int, finalOutput: String) {
        self.id = id; self.userMessage = userMessage; self.goal = goal
        self.skillsUsed = skillsUsed; self.outcome = outcome
        self.stepCount = stepCount; self.finalOutput = finalOutput
    }
}

public struct RepairRecord: Sendable, Equatable, Codable {
    public let id: String
    public let skillName: String
    public let errorSummary: String
    public let fixType: String
    public let fixDescription: String
    public let alternativeSkill: String?
    public let alternativeArgs: [String: String]
    public let success: Bool

    public init(id: String = UUID().uuidString, skillName: String, errorSummary: String,
                fixType: String, fixDescription: String,
                alternativeSkill: String? = nil, alternativeArgs: [String: String] = [:],
                success: Bool) {
        self.id = id; self.skillName = skillName; self.errorSummary = errorSummary
        self.fixType = fixType; self.fixDescription = fixDescription
        self.alternativeSkill = alternativeSkill; self.alternativeArgs = alternativeArgs
        self.success = success
    }
}

public struct DeviceFact: Sendable, Equatable, Codable {
    public let id: String
    public let factKey: String
    public let factValue: String
    public let sourceEpisodeId: String?

    public init(id: String = UUID().uuidString, factKey: String, factValue: String,
                sourceEpisodeId: String? = nil) {
        self.id = id; self.factKey = factKey; self.factValue = factValue
        self.sourceEpisodeId = sourceEpisodeId
    }
}
