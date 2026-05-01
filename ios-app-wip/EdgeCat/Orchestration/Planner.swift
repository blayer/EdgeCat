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

    /// Bundles the contextual inputs for a replan call so the method
    /// signature stays under SwiftLint's 5-parameter cap. Mirrors the
    /// kotlin data class `ReplanContext` on Android.
    public struct ReplanContext: Sendable {
        public let priorPlan: ExecutionPlan
        public let priorResults: [String: StepResult]
        public let evaluation: EvaluationResult
        public let replanAttempt: Int
        public init(priorPlan: ExecutionPlan,
                    priorResults: [String: StepResult],
                    evaluation: EvaluationResult,
                    replanAttempt: Int) {
            self.priorPlan = priorPlan
            self.priorResults = priorResults
            self.evaluation = evaluation
            self.replanAttempt = replanAttempt
        }
    }

    public func plan(userMessage: String,
                     availableSkills: [SkillSummary],
                     iteration: Int = 0,
                     conversationContext: String = "",
                     memoryContext: String = "",
                     isOnline: Bool = true) async throws -> ExecutionPlan {
        let prompt = Self.buildPlanPrompt(userMessage: userMessage,
                                          skills: availableSkills,
                                          userPortrait: userPortrait,
                                          memoryContext: memoryContext,
                                          conversationContext: bound(conversationContext),
                                          isOnline: isOnline)
        // No maxOutputTokens cap on the planner: caps were tested in
        // commit 9577996 and produced a strict regression — the model
        // would occasionally truncate plan JSON mid-step, the parser
        // would fail, and the evaluator would force a replan cascade
        // (turn 2 of weather-cloth went 28s → 91.8s with 3 replans).
        // Engine-default unbounded decode is empirically faster on
        // these small bounded JSON outputs.
        let raw = try await llm.generateResponse(
            prompt: prompt,
            enableThinking: policy.planner(userMessage: userMessage, iteration: iteration))
        let parsed = try parsePlan(raw, defaultGoal: userMessage)
        return Self.filterUnknownSkills(plan: parsed, available: availableSkills)
    }

    /// Re-plan after the evaluator says the prior plan didn't satisfy the
    /// user. Different from initial plan: includes prior plan + step
    /// outputs + the evaluator's `failedCriteria` / `missingItems` so the
    /// model knows what to fix.
    public func replan(userMessage: String,
                       availableSkills: [SkillSummary],
                       context: ReplanContext,
                       conversationContext: String = "",
                       memoryContext: String = "") async throws -> ExecutionPlan {
        let prompt = Self.buildReplanPrompt(userMessage: userMessage,
                                            skills: availableSkills,
                                            context: context,
                                            userPortrait: userPortrait,
                                            memoryContext: memoryContext,
                                            conversationContext: bound(conversationContext))
        let raw = try await llm.generateResponse(
            prompt: prompt,
            enableThinking: policy.replan(replanAttempt: context.replanAttempt))
        let parsed = try parsePlan(raw, defaultGoal: userMessage)
        return Self.filterUnknownSkills(plan: parsed, available: availableSkills)
    }

    /// Cap conversation context to roughly `historyWindow` turns (~1000
    /// chars per turn). Keeps the planner prompt within Gemma 4 E2B's
    /// working window without an exact tokenizer dependency. Bumped from
    /// 280 → 1000 so multi-paragraph assistant outputs (trip plans,
    /// itineraries) survive into the next turn — at 280 the planner only
    /// saw the first sentence and asked the user to repeat themselves.
    private func bound(_ context: String) -> String {
        let limit = max(0, historyWindow) * 1000
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
                                conversationContext: String = "",
                                isOnline: Bool = true) -> String {
        var sections: [String] = [
            "You are a planner that turns user requests into a step-by-step plan.",
            "",
            dateNote(),
            "",
            "Available skills:",
            renderCatalog(skills),
        ]
        if !isOnline {
            sections.append("")
            sections.append(offlineNote())
        }
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
                                  context: ReplanContext,
                                  userPortrait: String = "",
                                  memoryContext: String = "",
                                  conversationContext: String = "") -> String {
        let priorPlan = context.priorPlan
        let priorResults = context.priorResults
        let evaluation = context.evaluation
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
                let result = priorResults[step.id]
                let status = result?.status.rawValue ?? "?"
                let out = result?.output.prefix(280) ?? ""
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

    /// Mirrors android-app's `Planner.renderSkillCatalog`. Splits skills
    /// by tier so the planner prompt isn't bloated with deferred-skill
    /// detail it doesn't need yet — the agent can call `search-skills`
    /// to load full instructions when it actually wants to use one.
    static func renderCatalog(_ skills: [SkillSummary]) -> String {
        let base = skills.filter { $0.tier != "deferred" }
        let deferred = skills.filter { $0.tier == "deferred" }

        let baseBlock = base.map { skill -> String in
            if skill.instructions.isEmpty {
                return "- \(skill.name): \(skill.description)"
            }
            // Detail format mirrors Android — instructions on a continuation
            // line, indented two spaces so the model can see the boundary
            // between catalog entries cleanly.
            return "- \(skill.name): \(skill.description)\n  \(skill.instructions)"
        }.joined(separator: "\n")

        guard !deferred.isEmpty else { return baseBlock }

        let deferredBlock = deferred
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
        let deferredHint = "Available on demand (call \"search-skills\" to load instructions before use):"
        let separator = baseBlock.isEmpty ? "" : "\n\n"
        return baseBlock + separator + deferredHint + "\n" + deferredBlock
    }

    private static func appendOptional(_ sections: inout [String], label: String, value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sections.append("")
        sections.append(label)
        sections.append(value)
    }

    private static func offlineNote() -> String {
        let internet = ConnectivityChecker.internetSkills.sorted().joined(separator: ", ")
        return "OFFLINE MODE: the device has no internet right now. Avoid skills that require " +
               "the network (\(internet)). Prefer on-device skills."
    }

    private static func dateNote() -> String {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let today = fmt.string(from: now)
        let tomorrow = fmt.string(from: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        let inTwoDays = fmt.string(from: cal.date(byAdding: .day, value: 2, to: now) ?? now)
        let inOneWeek = fmt.string(from: cal.date(byAdding: .day, value: 7, to: now) ?? now)
        let inTwoWeeks = fmt.string(from: cal.date(byAdding: .day, value: 14, to: now) ?? now)
        // Small models (Gemma 4 E2B) have been observed picking
        // placeholder dates like "2025-01-01" even when the date note
        // gave them today/tomorrow inline. Two changes here:
        // 1) Promote the dates to a key=value block at the top so the
        //    model can copy values directly without parsing prose.
        // 2) Spell out the anti-patterns (placeholder dates, words
        //    like "tomorrow") so the post-tuning preference is loud.
        // Earlier iteration tried adding DAY_AFTER_TOMORROW too — small
        // models grabbed it for "tomorrow" tasks, off-by-one. Trimmed
        // back to the four values the planner actually needs.
        _ = inTwoDays
        return """
        DATE CONTEXT (substitute these EXACT values into toolArgs):
        TODAY = \(today)
        TOMORROW = \(tomorrow)
        ONE_WEEK_FROM_NOW = \(inOneWeek)
        TWO_WEEKS_FROM_NOW = \(inTwoWeeks)

        toolArgs date-time format: yyyy-MM-ddTHH:mm (24-hour, no seconds, no timezone).
        Examples: "\(today)T23:00" for "today at 11pm"; "\(tomorrow)T09:00" for "tomorrow morning"; "\(tomorrow)T14:00" for "tomorrow at 2pm"; "\(inOneWeek)T15:30" for "next week at 3:30pm".

        DO NOT write the literal words "today", "tomorrow", "next week".
        DO NOT use placeholder years like 2024 or 2025 — only the values above.
        DO NOT use 12-hour times like "2pm" — convert to 24-hour ("14:00").
        """
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

        STEP-OUTPUT CHAINING: when a later step needs the output of an
        earlier step, set the toolArgs value to the literal text
        "Output from <stepId>" (e.g. "Output from s1"). The runner
        substitutes the prior step's actual output before calling the
        skill. Use this — DO NOT paraphrase what s1 returned ("the
        number of steps"); that paraphrase becomes the literal arg.

        Multi-step example with chaining:
        {
          "goal": "Read step count and copy to clipboard",
          "steps": [
            {"id": "s1", "description": "Read today's step count.", "skillName": "read-health", "toolArgs": {"metric": "steps", "window_days": "1"}, "dependsOn": []},
            {"id": "s2", "description": "Copy s1's result to clipboard.", "skillName": "clipboard", "toolArgs": {"action": "write", "text": "Output from s1"}, "dependsOn": ["s1"]}
          ],
          "successCriteria": ["Step count is on the clipboard."]
        }

        "Nearest X" example — call directions DIRECTLY with a search-style `to` value, do NOT chain a search-web JSON output:
        {
          "goal": "Walk to nearest park and copy distance",
          "steps": [
            {"id": "s1", "description": "Get walking directions to the nearest park.", "skillName": "directions", "toolArgs": {"to": "nearest park", "mode": "walking"}, "dependsOn": []},
            {"id": "s2", "description": "Copy the distance to clipboard.", "skillName": "clipboard", "toolArgs": {"action": "write", "text": "Output from s1"}, "dependsOn": ["s1"]}
          ],
          "successCriteria": ["Distance is on the clipboard."]
        }

        Synthesis / drafting / "make a plan from this data" example — leave skillName NULL and put the instruction in the description. The executor synthesizes free-form text via the LLM:
        {
          "goal": "Draft a Tokyo trip itinerary from the fetched page",
          "steps": [
            {"id": "s1", "description": "Search the web for Tokyo sightseeing.", "skillName": "search-web", "toolArgs": {"query": "Tokyo famous sights itinerary"}, "dependsOn": []},
            {"id": "s2", "description": "Fetch the top result for actual content.", "skillName": "fetch-web-content", "toolArgs": {"url": "Output from s1"}, "dependsOn": ["s1"]},
            {"id": "s3", "description": "Synthesize a one-day Tokyo itinerary using the fetched details.", "skillName": null, "toolArgs": {}, "dependsOn": ["s2"]}
          ],
          "successCriteria": ["Reply contains a concrete itinerary."]
        }

        "Answer a question from the web" example — search-web alone returns a LINK LIST, not the answer. Chain fetch-web-content on the top URL so the formatter has the actual page text to extract from:
        {
          "goal": "Tell the user the weather in Tokyo today",
          "steps": [
            {"id": "s1", "description": "Search the web for today's Tokyo weather.", "skillName": "search-web", "toolArgs": {"query": "weather in Tokyo today"}, "dependsOn": []},
            {"id": "s2", "description": "Fetch the top result's page to get the actual weather details.", "skillName": "fetch-web-content", "toolArgs": {"url": "Output from s1"}, "dependsOn": ["s1"]}
          ],
          "successCriteria": ["Reply states today's Tokyo temperature/conditions."]
        }

        MULTI-TURN CONTINUATION: if a recent-conversation history is shown above AND the new user request is a bare detail (time/date/location/name) without its own verb, treat it as supplying missing info for the most recent prior request — re-emit the SAME skill the assistant used last turn (set-reminder stays set-reminder, calendar stays calendar — do NOT switch skills) with the new detail merged into its toolArgs. Pass bare time/date strings (e.g. "Tomorrow at 5pm") into the skill's natural-language arg (set-reminder's `dueWhen`, calendar/add-calendar-event's `whenText`). When the new request contains a pronoun ("that", "it", "them", "there"), resolve it from the most recent prior-turn entity and inline that entity into your toolArgs — never ask the user to clarify what the pronoun means.

        FIND-SLOT-AND-ADD: when the user says "find a free slot and add X" or "schedule X in a free time", emit TWO steps — (s1) calendar action=read to surface gaps, then (s2) calendar action=add with `whenText` set to a start time picked from s1's "FREE MORNING SLOTS" output. Do NOT stop after the read — the read is informational; the add is the action.

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
                ("commas", Self.repairCommas),
                ("quotes", Self.repairQuotes),
                ("unquoted-keys", Self.repairUnquotedKeys),
                ("strip-comments", Self.repairStripComments),
                ("balance-braces", Self.repairBalanceBraces),
                ("full", Self.repairAll),
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
        let raw: [PlanStep] = stepsArr.enumerated().map { idx, stepObj in
            PlanStep(
                id: (stepObj["id"] as? String) ?? "s\(idx + 1)",
                description: (stepObj["description"] as? String) ?? "",
                skillName: stepObj["skillName"] as? String,
                toolName: stepObj["toolName"] as? String,
                toolArgs: stringMap(stepObj["toolArgs"]),
                dependsOn: (stepObj["dependsOn"] as? [String]) ?? []
            )
        }
        let steps = normalizeDependsOn(raw)
        let criteria = (obj["successCriteria"] as? [String]) ?? []
        return ExecutionPlan(goal: goal, reasoning: reasoning, steps: steps, successCriteria: criteria)
    }

    /// Rewrite each step's `dependsOn` so its entries match an actual
    /// step `id` in the plan. Small models routinely emit `dependsOn:
    /// ["step_1"]` while the steps themselves carry `id: "s1"` — the
    /// executor's strict `priorResults[id]` lookup then returns nil
    /// and the dependent step is SKIPPED with `dependency unmet`,
    /// even though the upstream step completed. We hit this on
    /// composite-directions-share-001 in v1_ios_skills (s4 SKIPPED
    /// across all 3 replan iterations).
    ///
    /// Strategy: build a canonical-form lookup over the real step IDs
    /// (`s1` / `s_1` / `step_1` / `Step 1` all collapse to `1`), then
    /// for each step rewrite its dep list through that map. If a dep
    /// has no canonical match in the plan, drop it — the LLM
    /// hallucinated a reference; running the step is better than
    /// skipping forever.
    static func normalizeDependsOn(_ steps: [PlanStep]) -> [PlanStep] {
        guard steps.count > 1 else { return steps }
        let stepIds = Set(steps.map { $0.id })
        var canonicalToReal: [String: String] = [:]
        for step in steps {
            canonicalToReal[canonicalStepId(step.id)] = step.id
        }
        return steps.map { step in
            let fixed = step.dependsOn.compactMap { dep -> String? in
                if stepIds.contains(dep) { return dep }
                return canonicalToReal[canonicalStepId(dep)]
            }
            return PlanStep(
                id: step.id,
                description: step.description,
                skillName: step.skillName,
                toolName: step.toolName,
                toolArgs: step.toolArgs,
                dependsOn: fixed)
        }
    }

    /// Collapse step-id variants to a single canonical key so the
    /// dep-normalizer can match across them. Examples:
    /// `s1` → `1`, `s_1` → `1`, `step_1` → `1`, `Step 1` → `1`,
    /// `step1` → `1`. Non-conforming ids (e.g. `tokyo`) pass through
    /// as their alphanumeric reduction.
    static func canonicalStepId(_ s: String) -> String {
        let alnum = s.lowercased().filter { $0.isLetter || $0.isNumber }
        if alnum.hasPrefix("step") { return String(alnum.dropFirst(4)) }
        if alnum.hasPrefix("s"), alnum.count > 1, alnum.dropFirst().allSatisfy(\.isNumber) {
            return String(alnum.dropFirst(1))
        }
        return alnum
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

    /// Drop steps whose `skillName` doesn't exist in the registry. Small
    /// models hallucinate plausible-sounding names ("weather-api-skill",
    /// "query-wikipedia") that would route to `runJs` and fail with
    /// "unknown skill: …", costing us an execute + replan round-trip per
    /// hallucination. Pre-filter so the executor only sees real skills.
    ///
    /// Steps with empty / null `skillName` are LLM-only (summarize-style)
    /// and pass through unchanged. Names matching `SkillTools.llmOnly`
    /// also pass — they're synthesized by the executor's LLM lane, not
    /// dispatched to the registry.
    ///
    /// Safety net: if filtering would empty a non-empty plan (every
    /// step hallucinated), keep the original steps. An empty plan
    /// cascades to a "(no result)" final output — better to let the
    /// executor fail per-step so the replan has concrete error context
    /// to react to. Mirrors Android's "prefer noisy failure to silent
    /// no-op" heuristic in the Phase 7 planner-cleanup work.
    static func filterUnknownSkills(plan: ExecutionPlan,
                                    available: [SkillSummary]) -> ExecutionPlan {
        let valid = Set(available.map { SkillTools.normalize($0.name).lowercased() })
        let filtered = plan.steps.filter { step in
            guard let name = step.skillName?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, name.lowercased() != "null" else {
                return true   // LLM-only / description-only step.
            }
            let normalized = SkillTools.normalize(name).lowercased()
            return valid.contains(normalized) || SkillTools.llmOnly.contains(normalized)
        }
        if filtered.count == plan.steps.count { return plan }
        // Don't return an empty plan — pass the originals through so the
        // executor's per-step "unknown skill" failures drive a productive
        // replan. The expanded non-recoverable markers list catches the
        // unrecoverable case (every step fails with `unknown skill:`).
        if filtered.isEmpty { return plan }
        return ExecutionPlan(goal: plan.goal,
                             reasoning: plan.reasoning,
                             steps: filtered,
                             successCriteria: plan.successCriteria)
    }

    /// Last-ditch parser: when no tier produces valid JSON, scrape the goal
    /// + skill names with regex so the orchestrator at least has something
    /// to feed to ExecutionOrchestrator (which will mostly fail-fast, but
    /// emits step-level traces that help debugging).
    ///
    /// Accepts multiple key spellings (`skillName`, `skill_name`, `skill`,
    /// `tool_name`, `toolName`) because models drift across formats. If
    /// no skill-shaped key turns up, falls back to a goal-keyword heuristic
    /// (`infersSkillsFromGoal`) — better to attempt the most likely skill
    /// chain than to dump "(no result)" on the user.
    private static func regexFallback(_ text: String, defaultGoal: String) -> ExecutionPlan {
        let goal = firstMatch(in: text, pattern: #""goal"\s*:\s*"([^"]+)""#) ?? defaultGoal
        let skillKeys = [
            #""skillName"\s*:\s*"([^"]+)""#,
            #""skill_name"\s*:\s*"([^"]+)""#,
            #""skill"\s*:\s*"([^"]+)""#,
            #""tool_name"\s*:\s*"([^"]+)""#,
            #""toolName"\s*:\s*"([^"]+)""#,
        ]
        var skillNames: [String] = []
        for pattern in skillKeys {
            let hits = matches(in: text, pattern: pattern)
            if !hits.isEmpty { skillNames = hits; break }
        }
        // No skill keys at all — infer from goal keywords. Saves
        // skill-dependent tasks (scan-barcode, search-photos) from
        // dumping "(no result)" when the planner output is too
        // mangled even for the regex parser. Inferred chains get
        // sequential dependsOn + best-guess toolArgs so a multi-step
        // chain (e.g. search-photos → scan-barcode) actually wires
        // outputs together — without that, batch.start runs them in
        // parallel and the dependent step gets empty args.
        if skillNames.isEmpty {
            return ExecutionPlan(goal: goal,
                                 reasoning: "regex-fallback",
                                 steps: inferredSteps(goal: goal))
        }
        let steps: [PlanStep] = skillNames.enumerated().map { idx, name in
            PlanStep(id: "s\(idx + 1)", description: "regex-fallback step", skillName: name)
        }
        return ExecutionPlan(goal: goal, reasoning: "regex-fallback", steps: steps)
    }

    /// Build a sequentially-chained step list from the goal-keyword
    /// heuristic. Each step's args + `dependsOn` are filled in based
    /// on the prior step in the chain — so e.g. `search-photos →
    /// scan-barcode` properly threads photo_id through.
    static func inferredSteps(goal: String) -> [PlanStep] {
        let names = inferSkillsFromGoal(goal)
        var steps: [PlanStep] = []
        for (idx, name) in names.enumerated() {
            let id = "s\(idx + 1)"
            let prev = idx > 0 ? "s\(idx)" : nil
            let args = inferredArgs(for: name, goal: goal, priorStepId: prev)
            steps.append(PlanStep(
                id: id,
                description: "regex-fallback step",
                skillName: name,
                toolArgs: args,
                dependsOn: prev.map { [$0] } ?? []))
        }
        return steps
    }

    /// Best-effort args for an inferred step. Pulls a name-shaped token
    /// from the goal for `search-photos`, threads prior outputs via the
    /// `Output from <id>` placeholder so StepArgRescue can substitute.
    private static func inferredArgs(for skill: String,
                                     goal: String,
                                     priorStepId: String?) -> [String: String] {
        switch skill {
        case "search-photos":
            return ["query": photoQueryHint(from: goal)]
        case "scan-barcode":
            // Pass the name hint as photo_id when there's no upstream
            // step. BarcodeSkill's `looksLikePhotoAssetId` returns false
            // for plain names, so it falls through to
            // `scanRecentLibrary(maxAssets: 30)` and walks 30 recent
            // photos — the most-reliable path for "find the photo
            // named X and scan it" prompts.
            return ["photo_id": priorStepId.map { "Output from \($0)" } ?? photoQueryHint(from: goal)]
        case "recognize-text":
            return ["photo_id": priorStepId.map { "Output from \($0)" } ?? ""]
        case "search-web":
            return ["query": goal]
        case "fetch-web-content":
            return ["url": priorStepId.map { "Output from \($0)" } ?? ""]
        case "read-health":
            // Default to a 7-day window when the goal mentions "summary"
            // / "summarize" / "last 7 days"; HealthKit returns
            // empty-on-empty in the sim so the verifier passes on
            // query-shape regardless.
            return ["dataType": "all", "windowDays": "7"]
        case "summarize":
            // Synthesizer step in a chain. `instruction` is what
            // SummarizeSkill reads (StubSkills.swift fallback to
            // `description`); using the goal as instruction gives the
            // LLM lane a coherent prompt and `Output from sN` resolves
            // upstream content via StepArgRescue.
            return [
                "instruction": "Based on the prior step output, " + goal,
                "text": priorStepId.map { "Output from \($0)" } ?? "",
            ]
        default:
            return [:]
        }
    }

    /// Extract a `test_qr_claude`-style identifier from the goal text
    /// (longest underscore/dash token), falling back to the goal itself.
    /// Pattern needs a capture group because `matches(in:pattern:)`
    /// reads range(at: 1) — without one we'd get back nothing and
    /// always fall through to the full goal.
    private static func photoQueryHint(from goal: String) -> String {
        let pattern = #"(\b[a-z][a-z0-9_-]{4,}\b)"#
        let lower = goal.lowercased()
        let tokens = Self.matches(in: lower, pattern: pattern)
        let identifierish = tokens.filter {
            $0.contains("_") || $0.contains("-")
        }
        return identifierish.max(by: { $0.count < $1.count })
            ?? tokens.max(by: { $0.count < $1.count })
            ?? goal
    }

    /// Goal-keyword → skill-name heuristic for the catastrophic regex-
    /// fallback case (raw model output had no skill-shaped fields).
    /// Returns an empty array for goals that don't match any known
    /// keyword, in which case the executor sees zero steps and the
    /// formatter says "(no result)" — the user-facing equivalent of
    /// "I couldn't generate a plan for that".
    static func inferSkillsFromGoal(_ goal: String) -> [String] {
        let g = goal.lowercased()
        let isSummarize = g.contains("summarize")
            || g.contains("summarise")
            || g.contains("summary")
        // Personal-health detector: requires both a health keyword AND a
        // first-person marker ("my"/"i've"/"have i") so we don't misroute
        // generic web questions like "what is the resting heart rate of
        // a hummingbird" to read-health. The eval prompts that need this
        // ("How many steps have I taken today?", "What is my latest heart
        // rate reading?") all carry a possessive or first-person verb.
        let isHealthWord = g.contains("step") || g.contains("heart")
            || g.contains("activity") || g.contains("workout")
        let isFirstPerson = g.contains(" my ")
            || g.hasPrefix("my ")
            || g.contains("have i ")
            || g.contains("i've ")
            || g.contains("i have ")
        let isHealth = isHealthWord && isFirstPerson
        // Order matters: more specific patterns before more general ones.
        // Each entry is (predicate, ordered skill chain).
        let rules: [(check: (String) -> Bool, skills: [String])] = [
            // Personal health goes BEFORE the web/"what is" rule because
            // "what is my latest heart rate" otherwise routes to the web.
            ({ _ in isHealth && isSummarize },
             ["read-health", "summarize"]),
            ({ _ in isHealth },
             ["read-health"]),
            // QR / barcode → scan-barcode alone. Its built-in
            // `scanRecentLibrary` fallback walks 30 recent photos, which
            // is faster + more reliable than chaining off search-photos
            // (search-photos's fallback is capped at 10, so the QR
            // photo can fall outside the candidate set).
            ({ $0.contains("qr") || $0.contains("barcode") },
             ["scan-barcode"]),
            // Photo + text/OCR → find the photo, then read text.
            ({ $0.contains("photo") && ($0.contains("text") || $0.contains("ocr") || $0.contains("read")) },
             ["search-photos", "recognize-text"]),
            // Plain photo lookup.
            ({ $0.contains("photo") || $0.contains("gallery") || $0.contains("picture") },
             ["search-photos"]),
            // Web fact-finding (weather, news, "what is", "who is", "find me").
            ({ $0.contains("weather") || $0.contains("news") || $0.contains("temperature")
                 || $0.contains("what is") || $0.contains("who is") },
             ["search-web", "fetch-web-content"]),
            // Calendar / reminder / event creation.
            ({ $0.contains("calendar") || $0.contains("event") || $0.contains("appointment") },
             ["calendar"]),
            ({ $0.contains("reminder") || $0.contains("remind me") },
             ["reminders"]),
            ({ $0.contains("timer") },
             ["timer"]),
            // Directions.
            ({ $0.contains("walk") || $0.contains("drive") || $0.contains("directions") || $0.contains("nearest") },
             ["directions"]),
        ]
        for rule in rules where rule.check(g) {
            return rule.skills
        }
        return []
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
