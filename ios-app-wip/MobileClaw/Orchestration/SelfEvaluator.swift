import Foundation

// Mirrors android-app/.../orchestration/SelfEvaluator.kt — asks the LLM to
// judge whether the executed plan met the user's goal, returns an
// EvaluationResult with replan signal.

public struct SelfEvaluator {
    public let llm: LlmInferenceProvider
    public let policy: ThinkingPolicy

    public init(llm: LlmInferenceProvider, policy: ThinkingPolicy) {
        self.llm = llm
        self.policy = policy
    }

    public func evaluate(userMessage: String,
                         plan: ExecutionPlan,
                         results: [String: StepResult]) async throws -> EvaluationResult {
        let summary = plan.steps.map { step -> String in
            let r = results[step.id]
            return "- \(step.id) [\(r?.status.rawValue ?? "?")] — \(r?.output ?? "")"
        }.joined(separator: "\n")

        let criteriaSection = plan.successCriteria.isEmpty ? "" : """

        Success criteria:
        \(plan.successCriteria.enumerated().map { "  \($0 + 1). \($1)" }.joined(separator: "\n"))
        """

        let prompt = """
        You are evaluating whether a multi-step plan satisfied a user request.

        User request: \(userMessage)
        Goal: \(plan.goal)
        \(criteriaSection)
        Step results:
        \(summary)

        Reply with strict JSON:
        {
          "goalAchieved": true|false,
          "assessment": "short reason",
          "missingItems": [],
          "shouldReplan": true|false,
          "failedCriteria": []
        }
        """

        let raw = try await llm.generateResponse(prompt: prompt, enableThinking: policy.evaluator())
        return parse(raw)
    }

    private func parse(_ raw: String) -> EvaluationResult {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return EvaluationResult(goalAchieved: true, assessment: raw)
        }
        return EvaluationResult(
            goalAchieved: obj["goalAchieved"] as? Bool ?? true,
            assessment: obj["assessment"] as? String ?? "",
            missingItems: obj["missingItems"] as? [String] ?? [],
            shouldReplan: obj["shouldReplan"] as? Bool ?? false,
            failedCriteria: obj["failedCriteria"] as? [String] ?? []
        )
    }
}
