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

    /// Cheap rules-first triage. Returns a non-nil `EvaluationResult` when
    /// the answer is obviously yes (skip the LLM call). Mirrors Android's
    /// `triageEvaluation` shortcut — saves ~one inference per successful
    /// turn on the happy path.
    public func triage(userMessage: String,
                        plan: ExecutionPlan,
                        results: [String: StepResult]) -> EvaluationResult? {
        guard !plan.steps.isEmpty else { return nil }
        // Every planned step must have a result and be COMPLETED.
        for step in plan.steps {
            guard let r = results[step.id], r.status == .completed else { return nil }
            if r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            let lower = r.output.lowercased()
            for marker in ["error", "failed", "unable", "could not"] where lower.contains(marker) {
                return nil
            }
        }
        // At least one step output should mention a goal token or a
        // success-criteria token so we know the work is on-target.
        let combinedOutput = plan.steps
            .compactMap { results[$0.id]?.output }
            .joined(separator: " ")
            .lowercased()
        let goalTokens = Self.tokens(from: plan.goal)
        let criteriaTokens = plan.successCriteria.flatMap { Self.tokens(from: $0) }
        let allTokens = goalTokens + criteriaTokens
        let hit = allTokens.contains { token in
            !token.isEmpty && combinedOutput.contains(token)
        }
        guard hit else { return nil }

        return EvaluationResult(
            goalAchieved: true,
            assessment: "triage-shortcut",
            missingItems: [],
            shouldReplan: false,
            failedCriteria: [])
    }

    private static func tokens(from text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 }   // skip "the", "and", articles
    }

    public func evaluate(userMessage: String,
                         plan: ExecutionPlan,
                         results: [String: StepResult]) async throws -> EvaluationResult {
        if let triaged = triage(userMessage: userMessage, plan: plan, results: results) {
            return triaged
        }
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
