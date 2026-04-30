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
            guard let result = results[step.id], result.status == .completed else { return nil }
            if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            // search-web's output ("Search results for: ...") contains
            // the user's query tokens as titles + snippets, which would
            // make the goal-token check below trivially pass. But links
            // are not an answer. Force a full LLM evaluation when the
            // last step is a bare search with no fetch-web-content
            // follow-up — the LLM evaluator will say "shouldReplan" so
            // the planner can chain the fetch.
            let isLastStep = step.id == plan.steps.last?.id
            if isLastStep && Self.isBareSearchResults(result.output) {
                return nil
            }
            let lower = result.output.lowercased()
            // Skip the marker-scan for outputs that are JSON envelopes
            // declaring their own success — `{"status":"succeeded",...}`
            // can legitimately contain the substring "error" inside an
            // inner field name (e.g. `"error":null`) without meaning
            // the step failed.
            let isStructuredSuccess = lower.contains("\"status\"")
                && (lower.contains("\"succeeded\"") || lower.contains("\"ok\""))
            if !isStructuredSuccess {
                for marker in ["error", "failed", "unable", "could not"] where lower.contains(marker) {
                    return nil
                }
            }
        }
        // At least one step output should mention a goal token, a
        // success-criteria token, OR signal structured success — so we
        // know the work is on-target without requiring substring
        // overlap with the goal phrasing.
        let combinedOutput = plan.steps
            .compactMap { results[$0.id]?.output }
            .joined(separator: " ")
            .lowercased()
        let structuredSuccess = combinedOutput.contains("\"status\"")
            && (combinedOutput.contains("\"succeeded\"") || combinedOutput.contains("\"ok\""))
        let goalTokens = Self.tokens(from: plan.goal)
        let criteriaTokens = plan.successCriteria.flatMap { Self.tokens(from: $0) }
        let allTokens = goalTokens + criteriaTokens
        let tokenHit = allTokens.contains { token in
            !token.isEmpty && combinedOutput.contains(token)
        }
        guard tokenHit || structuredSuccess else { return nil }

        return EvaluationResult(
            goalAchieved: true,
            assessment: "triage-shortcut",
            missingItems: [],
            shouldReplan: false,
            failedCriteria: [])
    }

    /// `true` when the output is a search-web results listing with no
    /// fetched page content. Search results contain query tokens that
    /// would trivially satisfy the triage goal-token check, but they're
    /// just links — not an answer. Detected by the formatted header
    /// SearchWebSkill emits ("Search results for: …") combined with the
    /// absence of "Page content from".
    static func isBareSearchResults(_ output: String) -> Bool {
        let lower = output.lowercased()
        guard lower.contains("search results for") else { return false }
        return !lower.contains("page content from")
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
