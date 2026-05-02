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
        // Write-side state changes (calendar add, reminders create, timer
        // start, send-sms/email, share, clipboard write, etc.) must NOT
        // be rubber-stamped by the goal-token check below — the step
        // emits a structured success envelope containing the user's
        // requested title/text, which trivially overlaps goal tokens
        // even when the OS-level write didn't actually persist (the
        // failure mode that hit state-calendar-001 in v1_ios_skills).
        // Force the LLM evaluator so it reads success criteria + step
        // output and either confirms or asks for replan.
        for step in plan.steps where Self.isWriteSideStep(step) {
            return nil
        }
        // Symmetric guard: when the GOAL or success criteria explicitly
        // ask for a state change ("add … to my calendar", "schedule …",
        // "remind me …") but NO step in the plan is write-side, the plan
        // is structurally incomplete — the planner read but never wrote.
        // Force the LLM evaluator so it returns shouldReplan=true and the
        // planner gets a second chance to emit the missing add/set step.
        // Caught by eval: multi-calendar-gap-fill where the planner's
        // own reasoning + criteria mentioned the add step but the JSON
        // only contained the read step.
        if Self.hasWriteIntent(goal: plan.goal, criteria: plan.successCriteria) {
            return nil
        }
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

    /// `true` when the goal or success-criteria contain an action verb
    /// that implies a state change (add/schedule/create/set-reminder/
    /// send/book/save/etc.) — used by `triage` to refuse rubber-stamping
    /// a read-only plan whose stated intent was actually write-side.
    /// Tighter than a plain word-boundary scan: anchored to common
    /// imperative shapes so noun uses ("a set of options", "save mode")
    /// don't trigger false refusals.
    static func hasWriteIntent(goal: String, criteria: [String]) -> Bool {
        let combined = (goal + " " + criteria.joined(separator: " ")).lowercased()
        // Phrases anchored to imperative usage. Each entry is intentionally
        // narrow: better to miss a write-intent and trust the (cheap)
        // triage shortcut than to over-refuse and burn LLM evaluator calls
        // on read-only goals.
        let phrases = [
            "add ",          // "add 'coffee' to my calendar", "add an event"
            "schedule ",     // "schedule a meeting", "schedule the call"
            "create ",       // "create a reminder", "create event"
            "remind me",
            "set a reminder", "set the reminder", "set an alarm",
            "set up",
            "send ",         // "send an SMS"
            "book ",
            "save ",
            "share ",
            "update the",    // "update the existing reminder"
            "is added", "was added", "is scheduled", "is created",
            "successfully added", "successfully scheduled",
            "successfully created", "successfully set",
        ]
        return phrases.contains { combined.contains($0) }
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

    /// `true` when the step performs a write-side state change that
    /// shouldn't be rubber-stamped by the triage goal-token check.
    /// These skills emit structured-success envelopes echoing the
    /// user's requested values, so token overlap with the goal is
    /// trivial — but the OS write may still have silently failed
    /// (sim TCC, denied notification permission downstream of a
    /// "success" return, etc.). Force the LLM judge for these.
    static func isWriteSideStep(_ step: PlanStep) -> Bool {
        guard let raw = step.skillName, !raw.isEmpty else { return false }
        let skill = raw.lowercased()
        // Always write-side: any invocation creates a side effect.
        let alwaysWrite: Set<String> = [
            "reminders",
            "set-reminder",
            "send-sms",
            "send-email",
            "share-content",
            "phone-call",
            "set-alarm",
            "add-calendar-event",
            "open-url",
            "open-settings",
            "launch-app",
            "take-photo",
            "flashlight",
            "volume-control",
            "do-not-disturb",
        ]
        if alwaysWrite.contains(skill) { return true }
        // Action-gated skills: write-side only when args["action"] picks a
        // mutating mode. Default action is read-side for these so we don't
        // over-trigger the gate on plain "what's on my calendar" runs.
        let action = (step.toolArgs["action"] ?? "").lowercased()
        switch skill {
        case "calendar":
            return ["add", "create", "write"].contains(action)
        case "clipboard":
            return action == "write"
        case "timer":
            // Default action is "start" (TimerSkill.swift). Treat
            // anything except `list` as write-side — `cancel` also
            // mutates pending notifications.
            return action != "list"
        default:
            return false
        }
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
            let skill = step.skillName ?? "(llm-only)"
            let action = step.toolArgs["action"].map { " action=\($0)" } ?? ""
            return "- \(step.id) [\(r?.status.rawValue ?? "?")] " +
                   "skill=\(skill)\(action) — \(r?.output ?? "")"
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

        Steps actually executed (in order — this is EVERY action the agent took, NOTHING else ran):
        \(summary)

        IMPORTANT — base goalAchieved STRICTLY on what the steps above actually DID, not on what the goal sounds like or what the read-side step output suggests is possible.

        - If the goal mentions an ACTION (add / schedule / create / set / send / book / save / share / remove) but NO write-side skill (add-calendar-event, set-reminder, send-sms, send-email, share-content, set-alarm, calendar with action=add, clipboard with action=write, timer, etc.) appears in the steps above, the goal was NOT achieved. Set goalAchieved=false, shouldReplan=true, and put the missing write-side skill in missingItems.
        - If the goal is purely informational ("find …", "what is …", "tell me …", "where is …", "when is …", "how many …"), do NOT add a write-side skill name to missingItems even if it seems "useful next" — the agent is supposed to answer the question, not write to the device. A read-only goal whose steps successfully retrieved the answer is goalAchieved=true.
        - A step whose skill is `calendar` with action=read does NOT add events; it only lists them. Hints in its output like "FREE MORNING SLOTS" are SUGGESTIONS for the next step, NOT proof an event was scheduled.
        - Do NOT claim an event was added based on existing entries in the calendar read; only the agent's own write-side step counts.
        - If a step listed above has status=FAILED or output mentions "error"/"unable to"/"could not", treat that step as not achieving its purpose.

        Reply with strict JSON:
        {
          "goalAchieved": true|false,
          "assessment": "short reason",
          "missingItems": [],
          "shouldReplan": true|false,
          "failedCriteria": []
        }
        """

        // No maxOutputTokens cap on the evaluator either — see Planner
        // for why (truncated JSON forces a replan cascade that more
        // than wipes out the decode-time savings).
        let raw = try await llm.generateResponse(
            prompt: prompt,
            enableThinking: policy.evaluator())
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
