import Foundation

// Mirrors android-app/.../orchestration/Planner.kt — builds a planner prompt
// from the user message + skill catalog, asks the LLM, parses JSON into an
// ExecutionPlan. The Android version's prompt template is ~600 lines; this
// Swift port keeps the same shape with a tighter prompt.

public struct Planner {
    public let llm: LlmInferenceProvider
    public let policy: ThinkingPolicy

    public init(llm: LlmInferenceProvider, policy: ThinkingPolicy) {
        self.llm = llm
        self.policy = policy
    }

    public func plan(userMessage: String,
                     availableSkills: [SkillSummary],
                     iteration: Int = 0) async throws -> ExecutionPlan {
        let prompt = Self.buildPrompt(userMessage: userMessage, skills: availableSkills, iteration: iteration)
        let raw = try await llm.generateResponse(prompt: prompt,
                                                 enableThinking: policy.planner(userMessage: userMessage,
                                                                                 iteration: iteration))
        return try parsePlan(raw, defaultGoal: userMessage)
    }

    static func buildPrompt(userMessage: String, skills: [SkillSummary], iteration: Int) -> String {
        let catalog = skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let header = iteration == 0
            ? "You are a planner that turns user requests into a step-by-step plan."
            : "Your previous plan didn't satisfy the user. Replan."
        return """
        \(header)

        Available skills:
        \(catalog)

        Respond with strict JSON of the form:
        {
          "goal": "...",
          "reasoning": "...",
          "steps": [
            {"id": "s1", "description": "...", "skillName": "<one of above or null>", "toolArgs": {"key": "value"}, "dependsOn": []}
          ],
          "successCriteria": ["..."]
        }

        User request: \(userMessage)
        """
    }

    func parsePlan(_ raw: String, defaultGoal: String) throws -> ExecutionPlan {
        let json = Self.extractJsonObject(from: raw) ?? "{}"
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ExecutionPlan(goal: defaultGoal, reasoning: raw, steps: [])
        }
        let goal = obj["goal"] as? String ?? defaultGoal
        let reasoning = obj["reasoning"] as? String ?? ""
        let stepsArr = obj["steps"] as? [[String: Any]] ?? []
        let steps: [PlanStep] = stepsArr.enumerated().map { idx, stepObj in
            PlanStep(
                id: (stepObj["id"] as? String) ?? "s\(idx + 1)",
                description: (stepObj["description"] as? String) ?? "",
                skillName: stepObj["skillName"] as? String,
                toolName: stepObj["toolName"] as? String,
                toolArgs: stringMap(stepObj["toolArgs"]),
                dependsOn: (stepObj["dependsOn"] as? [String]) ?? []
            )
        }
        let criteria = (obj["successCriteria"] as? [String]) ?? []
        return ExecutionPlan(goal: goal, reasoning: reasoning, steps: steps, successCriteria: criteria)
    }

    private static func extractJsonObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }

    private func stringMap(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.compactMapValues { v in
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
    }
}
