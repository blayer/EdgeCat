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

/// One-line `{"type":"run", "run":{…}}` summary written at the end of an
/// eval run. Mirrors android-app's `Run` record so off-device scorers
/// (`test/eval/scorers/`) can read it field-for-field.
public struct RunSummary: Sendable {
    public let runId: String
    public let schemaVersion: Int
    public let userMessage: String
    /// "ok" | "error" | "cancelled" | "incomplete"
    public let finalStatus: String
    public let finalOutput: String
    public let iteration: Int
    public let startMs: Int64
    public let endMs: Int64
    public let plan: ExecutionPlan?
    public let stepResults: [String: StepResult]
    public let evaluation: EvaluationResult?
    /// `model_name`, `thinking_mode`, `memory_isolated`, etc.
    public let extras: [String: Any]
    /// `manufacturer`, `model`, `system_version`, `idfv`.
    public let device: [String: Any]
    public let error: String?

    public init(runId: String,
                schemaVersion: Int = 1,
                userMessage: String,
                finalStatus: String,
                finalOutput: String,
                iteration: Int,
                startMs: Int64,
                endMs: Int64,
                plan: ExecutionPlan? = nil,
                stepResults: [String: StepResult] = [:],
                evaluation: EvaluationResult? = nil,
                extras: [String: Any] = [:],
                device: [String: Any] = [:],
                error: String? = nil) {
        self.runId = runId
        self.schemaVersion = schemaVersion
        self.userMessage = userMessage
        self.finalStatus = finalStatus
        self.finalOutput = finalOutput
        self.iteration = iteration
        self.startMs = startMs
        self.endMs = endMs
        self.plan = plan
        self.stepResults = stepResults
        self.evaluation = evaluation
        self.extras = extras
        self.device = device
        self.error = error
    }

    /// Build the JSON-serializable dictionary that goes inside the
    /// `{"type":"run","run":{…}}` envelope.
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "run_id": runId,
            "schema_version": schemaVersion,
            "user_message": userMessage,
            "final_status": finalStatus,
            "final_output": finalOutput,
            "iteration": iteration,
            "start_ms": startMs,
            "end_ms": endMs,
            "duration_ms": endMs - startMs,
            "extras": extras,
            "device": device,
        ]
        if let plan {
            dict["plan"] = Self.encodePlan(plan)
        }
        if !stepResults.isEmpty {
            dict["step_results"] = Self.encodeStepResults(stepResults)
        }
        if let evaluation {
            dict["evaluation"] = Self.encodeEvaluation(evaluation)
        }
        if let error {
            dict["error"] = error
        }
        return dict
    }

    private static func encodePlan(_ plan: ExecutionPlan) -> [String: Any] {
        [
            "goal": plan.goal,
            "reasoning": plan.reasoning,
            "steps": plan.steps.map { step -> [String: Any] in
                var s: [String: Any] = [
                    "id": step.id,
                    "description": step.description,
                    "depends_on": step.dependsOn,
                ]
                if let skill = step.skillName { s["skill_name"] = skill }
                if let tool = step.toolName { s["tool_name"] = tool }
                if !step.toolArgs.isEmpty { s["tool_args"] = step.toolArgs }
                return s
            },
            "success_criteria": plan.successCriteria,
        ]
    }

    private static func encodeStepResults(_ results: [String: StepResult]) -> [String: Any] {
        results.mapValues { result -> [String: Any] in
            var dict: [String: Any] = [
                "step_id": result.stepId,
                "status": result.status.rawValue.uppercased(), // Match Android enum casing
                "output": result.output,
                "duration_ms": result.durationMs,
            ]
            if let error = result.error { dict["error"] = error }
            return dict
        }
    }

    private static func encodeEvaluation(_ eval: EvaluationResult) -> [String: Any] {
        [
            "goal_achieved": eval.goalAchieved,
            "assessment": eval.assessment,
            "missing_items": eval.missingItems,
            "should_replan": eval.shouldReplan,
            "failed_criteria": eval.failedCriteria,
        ]
    }
}
