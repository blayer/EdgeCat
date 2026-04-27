import Foundation

// Mirrors android-app/.../orchestration/Planner.kt — builds a planner prompt
// from the user message + skill catalog, asks the LLM, parses JSON into an
// ExecutionPlan. The Android version's prompt template is ~600 lines; this
// Swift port keeps the same shape with a tighter prompt.

public struct Planner {
    public let llm: LlmInferenceProvider
    public let policy: ThinkingPolicy
    public let userPortrait: String
    public let historyWindow: Int

    public init(llm: LlmInferenceProvider,
                policy: ThinkingPolicy,
                userPortrait: String = "",
                historyWindow: Int = 6) {
        self.llm = llm
        self.policy = policy
        self.userPortrait = userPortrait
        self.historyWindow = historyWindow
    }

    public func plan(userMessage: String,
                     availableSkills: [SkillSummary],
                     iteration: Int = 0,
                     conversationContext: String = "",
                     memoryContext: String = "") async throws -> ExecutionPlan {
        let prompt = Self.buildPlanPrompt(userMessage: userMessage,
                                           skills: availableSkills,
                                           userPortrait: userPortrait,
                                           memoryContext: memoryContext,
                                           conversationContext: bound(conversationContext))
        let raw = try await llm.generateResponse(prompt: prompt,
                                                 enableThinking: policy.planner(userMessage: userMessage,
                                                                                 iteration: iteration))
        return try parsePlan(raw, defaultGoal: userMessage)
    }

    /// Re-plan after the evaluator says the prior plan didn't satisfy the
    /// user. Different from initial plan: includes prior plan + step
    /// outputs + the evaluator's `failedCriteria` / `missingItems` so the
    /// model knows what to fix.
    public func replan(userMessage: String,
                       availableSkills: [SkillSummary],
                       priorPlan: ExecutionPlan,
                       priorResults: [String: StepResult],
                       evaluation: EvaluationResult,
                       replanAttempt: Int,
                       conversationContext: String = "",
                       memoryContext: String = "") async throws -> ExecutionPlan {
        let prompt = Self.buildReplanPrompt(userMessage: userMessage,
                                             skills: availableSkills,
                                             priorPlan: priorPlan,
                                             priorResults: priorResults,
                                             evaluation: evaluation,
                                             userPortrait: userPortrait,
                                             memoryContext: memoryContext,
                                             conversationContext: bound(conversationContext))
        let raw = try await llm.generateResponse(prompt: prompt,
                                                 enableThinking: policy.replan(replanAttempt: replanAttempt))
        return try parsePlan(raw, defaultGoal: userMessage)
    }

    /// Cap conversation context to roughly `historyWindow` turns (~280 chars
    /// per turn). Keeps the planner prompt within Gemma 4 E2B's working
    /// window without an exact tokenizer dependency.
    private func bound(_ context: String) -> String {
        let limit = max(0, historyWindow) * 280
        if context.count <= limit { return context }
        let start = context.index(context.endIndex, offsetBy: -limit)
        return String(context[start...])
    }

    /// Back-compat shim — older tests + Phase 1 wiring tests call this.
    /// New code should use `buildPlanPrompt` directly.
    static func buildPrompt(userMessage: String,
                            skills: [SkillSummary],
                            iteration: Int,
                            userPortrait: String = "",
                            conversationContext: String = "") -> String {
        buildPlanPrompt(userMessage: userMessage,
                        skills: skills,
                        userPortrait: userPortrait,
                        conversationContext: conversationContext)
    }

    static func buildPlanPrompt(userMessage: String,
                                skills: [SkillSummary],
                                userPortrait: String = "",
                                memoryContext: String = "",
                                conversationContext: String = "") -> String {
        var sections: [String] = [
            "You are a planner that turns user requests into a step-by-step plan.",
            "",
            dateNote(),
            "",
            "Available skills:",
            renderCatalog(skills),
        ]
        appendOptional(&sections,
                       label: "User portrait (what the user has told you about themselves):",
                       value: userPortrait)
        appendOptional(&sections,
                       label: "Relevant prior episodes:",
                       value: memoryContext)
        appendOptional(&sections,
                       label: "Recent conversation:",
                       value: conversationContext)
        sections.append("")
        sections.append(jsonFormatTrailer(userMessage: userMessage))
        return sections.joined(separator: "\n")
    }

    static func buildReplanPrompt(userMessage: String,
                                  skills: [SkillSummary],
                                  priorPlan: ExecutionPlan,
                                  priorResults: [String: StepResult],
                                  evaluation: EvaluationResult,
                                  userPortrait: String = "",
                                  memoryContext: String = "",
                                  conversationContext: String = "") -> String {
        var sections: [String] = [
            "Your previous plan didn't fully satisfy the user. Build a NEW plan that fixes the gaps.",
            "",
            dateNote(),
            "",
            "Available skills:",
            renderCatalog(skills),
            "",
            "Previous goal: \(priorPlan.goal)",
            "",
            "Previous step results:",
            priorPlan.steps.map { step -> String in
                let r = priorResults[step.id]
                let status = r?.status.rawValue ?? "?"
                let out = r?.output.prefix(280) ?? ""
                return "- \(step.id) [\(status)] (\(step.skillName ?? "no-skill")) — \(out)"
            }.joined(separator: "\n"),
            "",
            "Evaluator feedback: \(evaluation.assessment)",
        ]
        if !evaluation.missingItems.isEmpty {
            sections.append("Missing: " + evaluation.missingItems.joined(separator: "; "))
        }
        if !evaluation.failedCriteria.isEmpty {
            sections.append("Failed criteria: " + evaluation.failedCriteria.joined(separator: "; "))
        }
        appendOptional(&sections,
                       label: "User portrait:",
                       value: userPortrait)
        appendOptional(&sections,
                       label: "Relevant prior episodes:",
                       value: memoryContext)
        appendOptional(&sections,
                       label: "Recent conversation:",
                       value: conversationContext)
        sections.append("")
        sections.append(jsonFormatTrailer(userMessage: userMessage))
        return sections.joined(separator: "\n")
    }

    private static func renderCatalog(_ skills: [SkillSummary]) -> String {
        skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    private static func appendOptional(_ sections: inout [String], label: String, value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sections.append("")
        sections.append(label)
        sections.append(value)
    }

    private static func dateNote() -> String {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: now)
        let tomorrow = fmt.string(from: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        return "IMPORTANT: date-time values in toolArgs MUST be yyyy-MM-ddTHH:mm " +
               "(e.g. \"\(today)T23:00\", \"\(tomorrow)T09:00\"). Never use \"today\"/\"tomorrow\"/\"11pm\"."
    }

    private static func jsonFormatTrailer(userMessage: String) -> String {
        """
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

    /// Result of parsing an LLM plan response, including which repair tier
    /// won. The tier is logged as a TraceRecorder attr so we can spot
    /// chronically-broken model outputs in eval runs.
    public struct PlanParseResult: Sendable, Equatable {
        public let plan: ExecutionPlan
        public let repairTier: String
        public init(plan: ExecutionPlan, repairTier: String) {
            self.plan = plan; self.repairTier = repairTier
        }
    }

    public func parsePlan(_ raw: String, defaultGoal: String) throws -> ExecutionPlan {
        parsePlanWithStatus(raw, defaultGoal: defaultGoal).plan
    }

    /// Parse with a 7-tier repair pipeline mirroring Android's
    /// `Planner.parsePlanWithStatus`. Tiers are tried in order on the
    /// originally-extracted JSON (not stacked) so an earlier tier's half-
    /// fix can't mask a later tier's success. "full" stacks them all and
    /// wins for pathological cases.
    public func parsePlanWithStatus(_ raw: String, defaultGoal: String) -> PlanParseResult {
        if let extracted = Self.extractJsonObject(from: raw) {
            // Tier 0 — try as-is.
            if let plan = Self.tryParse(extracted, defaultGoal: defaultGoal) {
                return PlanParseResult(plan: plan, repairTier: "none")
            }
            let tiers: [(String, (String) -> String)] = [
                ("commas",         Self.repairCommas),
                ("quotes",         Self.repairQuotes),
                ("unquoted-keys",  Self.repairUnquotedKeys),
                ("strip-comments", Self.repairStripComments),
                ("balance-braces", Self.repairBalanceBraces),
                ("full",           Self.repairAll),
            ]
            for (name, fn) in tiers {
                let repaired = fn(extracted)
                if repaired == extracted { continue }
                if let plan = Self.tryParse(repaired, defaultGoal: defaultGoal) {
                    return PlanParseResult(plan: plan, repairTier: name)
                }
            }
        }
        return PlanParseResult(
            plan: Self.regexFallback(raw, defaultGoal: defaultGoal),
            repairTier: "regex-fallback")
    }

    private static func tryParse(_ json: String, defaultGoal: String) -> ExecutionPlan? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
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
        guard let start = text.firstIndex(of: "{") else { return nil }
        // Tolerate a missing closing brace — the balance-braces repair tier
        // will append it. We just need a starting brace to know we're
        // looking at structured output.
        let end = text.lastIndex(of: "}") ?? text.index(before: text.endIndex)
        guard start <= end else { return nil }
        return String(text[start...end])
    }

    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.compactMapValues { v in
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
    }

    // MARK: - Repair tiers (1:1 with android-app/.../Planner.kt:331-407)

    /// Collapse `,\s*,` runs, drop trailing commas before `}` / `]`.
    static func repairCommas(_ s: String) -> String {
        var out = s
        var prev: String
        // Iterate to stability — `,,,` collapses to `,` over multiple passes.
        repeat {
            prev = out
            out = out.replacingOccurrences(of: #",\s*,"#, with: ",", options: .regularExpression)
        } while out != prev
        out = out.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        return out
    }

    /// Normalize curly/single quotes; promote singles to doubles when no
    /// doubles present (ratio guard against legit apostrophes in prose).
    static func repairQuotes(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "\"")
            .replacingOccurrences(of: "\u{2019}", with: "\"")
        let singles = out.filter { $0 == "'" }.count
        let doubles = out.filter { $0 == "\"" }.count
        if singles > 4 && doubles == 0 {
            out = out.replacingOccurrences(of: "'", with: "\"")
        }
        return out
    }

    /// Add quotes around bareword keys: `{goal: "x"}` → `{"goal": "x"}`.
    static func repairUnquotedKeys(_ s: String) -> String {
        s.replacingOccurrences(
            of: #"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)"#,
            with: "$1\"$2\"$3",
            options: .regularExpression)
    }

    /// Strip `//` and `#` comment lines that thinking-mode outputs inject.
    /// Only when the comment starts a line — guards against URLs.
    static func repairStripComments(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop(while: { $0.isWhitespace })
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") { return "" }
                return String(line)
            }
            .joined(separator: "\n")
    }

    /// Append missing closing braces/brackets for clean truncation at the end.
    /// Naive (ignores chars inside strings) but good enough for short plans.
    static func repairBalanceBraces(_ s: String) -> String {
        let opens = s.filter { $0 == "{" }.count
        let closes = s.filter { $0 == "}" }.count
        let openBr = s.filter { $0 == "[" }.count
        let closeBr = s.filter { $0 == "]" }.count
        if opens <= closes && openBr <= closeBr { return s }
        var trimmed = String(s.reversed().drop(while: { $0.isWhitespace || $0 == "," }).reversed())
        if openBr > closeBr {
            trimmed.append(String(repeating: "]", count: openBr - closeBr))
        }
        if opens > closes {
            trimmed.append(String(repeating: "}", count: opens - closes))
        }
        return trimmed
    }

    /// Stack of all repairs — final tier for pathological outputs.
    static func repairAll(_ s: String) -> String {
        repairBalanceBraces(
            repairStripComments(
                repairUnquotedKeys(
                    repairQuotes(
                        repairCommas(s)))))
    }

    /// Last-ditch parser: when no tier produces valid JSON, scrape the goal
    /// + skill names with regex so the orchestrator at least has something
    /// to feed to ExecutionOrchestrator (which will mostly fail-fast, but
    /// emits step-level traces that help debugging).
    private static func regexFallback(_ text: String, defaultGoal: String) -> ExecutionPlan {
        let goal = firstMatch(in: text, pattern: #""goal"\s*:\s*"([^"]+)""#) ?? defaultGoal
        let skillNames = matches(in: text, pattern: #""skillName"\s*:\s*"([^"]+)""#)
        let steps: [PlanStep] = skillNames.enumerated().map { idx, name in
            PlanStep(id: "s\(idx + 1)", description: "regex-fallback step", skillName: name)
        }
        return ExecutionPlan(goal: goal, reasoning: "regex-fallback", steps: steps)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, options: [], range: range).compactMap { m in
            guard m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}
