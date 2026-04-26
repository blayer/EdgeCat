import Foundation

// 1:1 port of android-app/.../orchestration/OrchestrationTypes.kt

public struct PlanStep: Sendable, Equatable {
    public let id: String
    public let description: String
    public let skillName: String?
    public let toolName: String?
    public let toolArgs: [String: String]
    public let dependsOn: [String]

    public init(id: String, description: String, skillName: String? = nil,
                toolName: String? = nil, toolArgs: [String: String] = [:],
                dependsOn: [String] = []) {
        self.id = id; self.description = description; self.skillName = skillName
        self.toolName = toolName; self.toolArgs = toolArgs; self.dependsOn = dependsOn
    }
}

public struct ExecutionPlan: Sendable, Equatable {
    public let goal: String
    public let reasoning: String
    public let steps: [PlanStep]
    public let successCriteria: [String]
    public init(goal: String, reasoning: String, steps: [PlanStep], successCriteria: [String] = []) {
        self.goal = goal; self.reasoning = reasoning; self.steps = steps; self.successCriteria = successCriteria
    }
}

public enum StepStatus: String, Sendable {
    case pending, running, completed, failed, skipped
}

public struct StepResult: Sendable, Equatable {
    public let stepId: String
    public let status: StepStatus
    public let output: String
    public let error: String?
    public let durationMs: Int64
    public init(stepId: String, status: StepStatus, output: String = "", error: String? = nil, durationMs: Int64 = 0) {
        self.stepId = stepId; self.status = status; self.output = output; self.error = error; self.durationMs = durationMs
    }
}

public enum OrchestrationStatus: String, Sendable {
    case idle, planning, executing, evaluating, repairing, replanning, formatting, completed, cancelled, error
}

public struct OrchestrationState: Sendable {
    public var status: OrchestrationStatus = .idle
    public var plan: ExecutionPlan?
    public var stepResults: [String: StepResult] = [:]
    public var evaluation: EvaluationResult?
    public var iteration: Int = 0
    public var maxIterations: Int = 3
    public var finalOutput: String?
    public var finalOutputIsHtml: Bool = false
    public var error: String?
    public var memoryRecalled: Bool?
    public var thinkingByPhase: [String: Bool] = [:]
    public init() {}
}

public struct EvaluationResult: Sendable, Equatable {
    public let goalAchieved: Bool
    public let assessment: String
    public let missingItems: [String]
    public let shouldReplan: Bool
    public let failedCriteria: [String]
    public init(goalAchieved: Bool, assessment: String, missingItems: [String] = [],
                shouldReplan: Bool = false, failedCriteria: [String] = []) {
        self.goalAchieved = goalAchieved; self.assessment = assessment
        self.missingItems = missingItems; self.shouldReplan = shouldReplan
        self.failedCriteria = failedCriteria
    }
}

public struct SkillSummary: Sendable, Equatable {
    public let name: String
    public let description: String
    public let instructions: String
    /// "base" = always in planner catalog. "deferred" = name-only until search-skills loads it.
    public let tier: String
    public init(name: String, description: String, instructions: String = "", tier: String = "base") {
        self.name = name; self.description = description; self.instructions = instructions; self.tier = tier
    }
}

public struct DiagnosticResult: Sendable, Equatable {
    public let diagnosis: String
    public let fixType: String   // retry_with_different_args / use_alternative_skill / skip / unfixable
    public let alternativeSkillName: String?
    public let alternativeArgs: [String: String]
    public let updatedInstructions: String?
    public init(diagnosis: String, fixType: String, alternativeSkillName: String? = nil,
                alternativeArgs: [String: String] = [:], updatedInstructions: String? = nil) {
        self.diagnosis = diagnosis; self.fixType = fixType
        self.alternativeSkillName = alternativeSkillName; self.alternativeArgs = alternativeArgs
        self.updatedInstructions = updatedInstructions
    }
}
