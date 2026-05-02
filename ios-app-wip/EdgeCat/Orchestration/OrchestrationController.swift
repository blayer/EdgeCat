import Foundation
import Observation

// Mirrors android-app/.../orchestration/OrchestrationController.kt — composes
// Planner + ExecutionOrchestrator + SelfEvaluator + ResponseFormatter into
// the plan→execute→evaluate→replan loop. Exposes OrchestrationState as
// observable so a SwiftUI view can render progress.

@MainActor
@Observable
public final class OrchestrationController {
    public private(set) var state = OrchestrationState()

    private let planner: Planner
    private let executor: ExecutionOrchestrator
    private let evaluator: SelfEvaluator
    private let formatter: ResponseFormatter
    private let toolExecutor: ToolExecutor
    private let llm: LlmInferenceProvider
    private let trace: TraceRecorder

    public let maxIterations: Int
    public let maxRepair: Int
    public let skillTimeoutSecs: Int
    public let historyWindow: Int
    public let userPortrait: String
    private let memory: MemoryProvider
    private let conversationContextProvider: @Sendable () -> String

    /// Set by `cancel()`, checked at every batch / phase boundary in
    /// `handle(userMessage:)`. Once set, the loop bails out, the inference
    /// provider is told to abort any in-flight LLM call, and `handle`
    /// throws `OrchestrationError.cancelled`. Mirrors Android's
    /// `cancelled.set(true)` + `cancelled.get()` checks.
    private var cancelRequested: Bool = false

    public init(llm: LlmInferenceProvider,
                tools: ToolExecutor,
                policy: ThinkingPolicy = ThinkingPolicy(mode: .auto),
                trace: TraceRecorder? = nil,
                maxIterations: Int = 3,
                maxRepair: Int = 0,
                skillTimeoutSecs: Int = 0,
                historyWindow: Int = 6,
                userPortrait: String = "",
                tracesEnabled: Bool = true,
                memory: MemoryProvider = EmptyMemoryProvider(),
                conversationContext: @Sendable @escaping () -> String = { "" }) {
        let recorder = trace ?? TraceRecorder(enabled: tracesEnabled)
        self.planner = Planner(llm: llm, policy: policy,
                                userPortrait: userPortrait,
                                historyWindow: historyWindow)
        // Diagnostic repair: turn on whenever maxRepair > 0 so the LLM
        // gets a chance to fix bad args / suggest alternatives. Skipped
        // when maxRepair == 0 since the user has explicitly asked for no
        // retries at all.
        let skillCreator = maxRepair > 0
            ? SkillCreator(llm: llm, policy: policy)
            : nil
        self.executor = ExecutionOrchestrator(executor: tools,
                                              trace: recorder,
                                              skillTimeoutSecs: skillTimeoutSecs,
                                              maxRepair: maxRepair,
                                              llm: llm,
                                              policy: policy,
                                              skillCreator: skillCreator)
        self.evaluator = SelfEvaluator(llm: llm, policy: policy)
        self.formatter = ResponseFormatter(llm: llm, policy: policy)
        self.toolExecutor = tools
        self.llm = llm
        self.trace = recorder
        self.maxIterations = maxIterations
        self.maxRepair = maxRepair
        self.skillTimeoutSecs = skillTimeoutSecs
        self.historyWindow = historyWindow
        self.userPortrait = userPortrait
        self.memory = memory
        self.conversationContextProvider = conversationContext
    }

    /// Cancel any in-flight orchestration run. Idempotent — calling more
    /// than once or before `handle()` is a no-op. Matches Android's
    /// `OrchestrationController.cancel()`.
    public func cancel() {
        cancelRequested = true
        llm.cancel()
    }

    private func throwIfCancelled() throws {
        if cancelRequested { throw OrchestrationError.cancelled }
    }

    /// Run one user message through the orchestration loop.
    public func handle(userMessage: String) async throws -> String {
        cancelRequested = false
        var s = OrchestrationState()
        s.iteration = 0
        s.maxIterations = maxIterations
        state = s

        let skills = toolExecutor.getAvailableSkills()
        let memoryContext = await memory.recallForPlanning(userMessage: userMessage)
        state.memoryRecalled = !memoryContext.isEmpty
        let conversationContext = conversationContextProvider()
        let isOnline = ConnectivityChecker.isOnline()

        var plan: ExecutionPlan?
        var results: [String: StepResult] = [:]
        var lastEvaluation: EvaluationResult?
        var lastIterationFingerprint: String?

        while state.iteration < state.maxIterations {
            try throwIfCancelled()
            // Plan or replan based on iteration.
            state.status = .planning
            let p: ExecutionPlan
            if state.iteration == 0 {
                p = try await trace.phase(kind: "phase", name: "plan") {
                    try await planner.plan(
                        userMessage: userMessage,
                        availableSkills: skills,
                        iteration: 0,
                        conversationContext: conversationContext,
                        memoryContext: memoryContext,
                        isOnline: isOnline)
                }
            } else if let priorPlan = plan, let priorEval = lastEvaluation {
                let replanContext = Planner.ReplanContext(
                    priorPlan: priorPlan,
                    priorResults: results,
                    evaluation: priorEval,
                    replanAttempt: state.iteration)
                p = try await trace.phase(kind: "phase", name: "replan") {
                    try await planner.replan(
                        userMessage: userMessage,
                        availableSkills: skills,
                        context: replanContext,
                        conversationContext: conversationContext,
                        memoryContext: memoryContext)
                }
            } else {
                // Defensive: shouldn't happen because iteration > 0 implies a
                // prior loop set plan + evaluation. Fall back to a fresh plan.
                p = try await trace.phase(kind: "phase", name: "plan") {
                    try await planner.plan(
                        userMessage: userMessage,
                        availableSkills: skills,
                        iteration: state.iteration,
                        conversationContext: conversationContext,
                        memoryContext: memoryContext,
                        isOnline: isOnline)
                }
            }
            plan = p
            state.plan = p

            try throwIfCancelled()
            // Execute
            state.status = .executing
            results = await trace.phase(kind: "phase", name: "execute") {
                await executor.execute(plan: p,
                                        conversationContext: conversationContext)
            }
            state.stepResults = results

            try throwIfCancelled()
            // Evaluate
            state.status = .evaluating
            let evalResult = try await trace.phase(kind: "phase", name: "evaluate") {
                try await evaluator.evaluate(userMessage: userMessage, plan: p, results: results)
            }
            state.evaluation = evalResult
            lastEvaluation = evalResult
            if evalResult.goalAchieved || !evalResult.shouldReplan { break }
            // Early-exit on non-recoverable step failures: if every
            // failed step in this iteration carries an error keyword
            // that won't change on retry (permission/auth gates, hard
            // platform stubs), there's no point burning another
            // ~25-30s on a replan. The replan would re-emit the same
            // skill, hit the same OS-level deny, and we'd waste an
            // LLM round-trip plus another execute phase. Bail out and
            // let the formatter explain.
            if Self.allFailuresAreNonRecoverable(results) { break }
            // Idempotent-replan guard: if this iteration's plan +
            // outcomes match the previous iteration's, the replan
            // produced the same broken plan as before and another
            // round won't help. Burns ~25-30s for nothing. Common
            // pattern when the skill catalog can't satisfy the
            // request (e.g. "find photo by filename" — PhotoKit has
            // no name-based lookup, so search-photos + scan-barcode
            // fails identically across iterations).
            let fingerprint = Self.iterationFingerprint(plan: p, results: results)
            if let prior = lastIterationFingerprint, prior == fingerprint { break }
            lastIterationFingerprint = fingerprint
            state.status = .replanning
            state.iteration += 1
        }

        guard var finalPlan = plan else {
            state.status = .error
            state.error = "No plan produced"
            throw OrchestrationError.noPlan
        }

        try throwIfCancelled()
        // Last-mile write-step injector: when the LLM evaluator flagged a
        // specific write-side skill as missing AND no plan iteration ever
        // emitted it, derive minimal args from the user request + goal
        // and execute the skill directly. Catches the Gemma 4 E2B failure
        // mode where the planner reasons correctly ("two steps: read,
        // then add") but the JSON output truncates to the read step,
        // and the replan repeats the same incomplete plan despite the
        // 🚨 REQUIRED SKILL directive. Safer than falling through to a
        // bullshit "I'd be happy to add it" formatter response.
        if let priorEval = lastEvaluation,
           !priorEval.goalAchieved,
           let injected = await injectMissingWriteStepIfNeeded(
            evaluation: priorEval,
            plan: finalPlan,
            userMessage: userMessage,
            conversationContext: conversationContext) {
            results[injected.stepId] = injected.result
            // Append the synthetic step to plan.steps so the formatter
            // (which enumerates plan.steps) actually surfaces the
            // injected result rather than echoing the prior compose
            // step's "what would you like to add?" clarification.
            let injectedStep = PlanStep(
                id: injected.stepId,
                description: "Inject missing \(injected.skillName) action",
                skillName: injected.skillName,
                toolArgs: [:],
                dependsOn: [])
            finalPlan = ExecutionPlan(
                goal: finalPlan.goal,
                reasoning: finalPlan.reasoning,
                steps: finalPlan.steps + [injectedStep],
                successCriteria: finalPlan.successCriteria)
        }

        // Format
        state.status = .formatting
        let formatted = try await trace.phase(kind: "phase", name: "format") {
            try await formatter.format(userMessage: userMessage,
                                       plan: finalPlan,
                                       results: results)
        }
        state.finalOutput = formatted.text
        state.finalOutputIsHtml = formatted.isHtml
        state.status = .completed

        // Memory write-back. Persist the run so future plans can recall it.
        // Only on goalAchieved — partial / failed runs would pollute recall.
        // Mirrors android-app's `MemoryRepository.save(episode:)` in
        // OrchestrationController.run after a successful turn.
        if let priorEval = lastEvaluation, priorEval.goalAchieved {
            let outcome = formatted.text.isEmpty ? "partial" : "success"
            let episode = OrchestrationEpisode(
                userMessage: userMessage,
                goal: finalPlan.goal,
                skillsUsed: finalPlan.steps.compactMap { $0.skillName },
                outcome: outcome,
                finalOutput: formatted.text)
            await memory.saveEpisode(episode)
        }
        return formatted.text
    }
}

public enum OrchestrationError: Error {
    case noPlan
    case cancelled
}

extension OrchestrationController {
    /// True when every failed step's error matches a known
    /// non-recoverable pattern (auth/permission denials, platform
    /// stubs, missing files). A replan with the same skill catalog
    /// will hit the same wall, so we save the round-trip.
    /// Stable string fingerprint of an iteration's plan + outcomes.
    /// Two iterations with the same fingerprint produced the same skill
    /// calls with the same args and got the same per-step status — the
    /// loop is stuck and another replan won't help.
    static func iterationFingerprint(plan: ExecutionPlan,
                                     results: [String: StepResult]) -> String {
        let parts = plan.steps.map { step -> String in
            let skill = step.skillName ?? ""
            let argPairs = step.toolArgs
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            let status = results[step.id]?.status.rawValue ?? "?"
            return "\(skill)|\(argPairs)|\(status)"
        }
        return parts.joined(separator: ";")
    }

    /// Result wrapper for the injected step.
    struct InjectedStep {
        let stepId: String
        let skillName: String
        let result: StepResult
    }

    /// When the LLM evaluator reports a specific write-side skill in
    /// `missingItems` and the final plan never invoked it, run that skill
    /// directly with args derived from the user message + plan goal.
    /// Returns nil when nothing is injectable (no missing skill named, the
    /// skill is unknown to the executor, or arg extraction yielded
    /// nothing useful). The injected step is recorded in `results` so
    /// the formatter sees a real success envelope rather than a hedge.
    func injectMissingWriteStepIfNeeded(
        evaluation: EvaluationResult,
        plan: ExecutionPlan,
        userMessage: String,
        conversationContext: String,
    ) async -> InjectedStep? {
        // Only inject for the write-side skills we know how to construct
        // args for — anything else risks calling a skill with garbage.
        let injectable: Set<String> = [
            "add-calendar-event",
            "set-reminder",
        ]
        let alreadyCalled = Set(plan.steps.compactMap {
            $0.skillName?.lowercased().replacingOccurrences(of: "_", with: "-")
        })
        let candidate = evaluation.missingItems
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { injectable.contains($0) && !alreadyCalled.contains($0) })
        guard let skillName = candidate else { return nil }

        // Symmetric gate with the planner's replan REQUIRED-SKILL
        // directive: only inject when the user's request OR the
        // planner's goal has write-intent. Checking both because the
        // planner sometimes paraphrases "Add it to my calendar" into
        // "Provide details for the user to add the event" which
        // strips the verb and would skip injection. Without this gate
        // an LLM evaluator that hallucinates `missingItems:
        // [add-calendar-event]` on a truly read-only goal ("Find a
        // free yoga class") would trigger a stray write that
        // pollutes the simulator's calendar across cases.
        let writeIntent = SelfEvaluator.hasWriteIntent(
            goal: plan.goal, criteria: plan.successCriteria)
            || SelfEvaluator.hasWriteIntent(
                goal: userMessage, criteria: [])
        guard writeIntent else { return nil }

        let args = Self.injectorArgs(
            forSkill: skillName,
            userMessage: userMessage,
            goal: plan.goal,
            conversationContext: conversationContext)
        guard !args.isEmpty else { return nil }
        // Reject obvious junk titles ("an unspecified item to the user's
        // calendar" — derived from a hallucinated goal). The agent's
        // intent should resolve to a quoted-phrase title or a short
        // user-supplied entity name, not a 50-character generic phrase.
        if let title = args["title"], title.count > 60 || title.contains("unspecified") {
            return nil
        }

        let stepId = "injected-\(skillName)"
        // Emit step.start span with `skill` attr so trace_assertions see
        // the injected skill in the per-turn bucket. Without the attr the
        // scorer's _bucket_steps_by_turn falls back to "(llm-only)".
        var spanAttrs: [String: Any] = ["skill": skillName, "injected": "1"]
        for (k, v) in args { spanAttrs["arg.\(k)"] = v }
        let result = await trace.phase(
            kind: "step.start",
            name: stepId,
            attrs: spanAttrs,
        ) {
            await self.toolExecutor.executeTool(toolName: skillName, args: args)
        }
        // Surface the result into state.stepResults so the format step +
        // run summary see it (otherwise the injection is invisible to
        // scorers that read step_results from the run row).
        await trace.event(kind: "step.end", name: stepId, payload: [
            "ok": result.success ? "1" : "0",
            "result": (result.output ?? result.error ?? "").prefix(280).description,
        ])
        let status: StepStatus = result.success ? .completed : .failed
        let stepResult = StepResult(
            stepId: stepId,
            status: status,
            output: result.output ?? "",
            error: result.error)
        return InjectedStep(stepId: stepId, skillName: skillName, result: stepResult)
    }

    /// Heuristic arg extractor for the small set of injectable skills.
    /// Pulls a quoted-phrase title from the user request and a temporal
    /// hint from the goal (or defaults to "tomorrow"). Better than
    /// nothing — a default-time event the user can correct beats a
    /// "I'd happily schedule that" hedge from the formatter.
    static func injectorArgs(
        forSkill skill: String,
        userMessage: String,
        goal: String,
        conversationContext: String = "",
    ) -> [String: String] {
        let combined = userMessage + " " + goal
        // Title resolution priority:
        //  1. Quoted phrase in the current user message ("'coffee with Sam'")
        //  2. Quoted phrase in the planner's goal text
        //  3. Quoted/Title-shaped phrase in the most recent prior-turn
        //     assistant message — needed when the user uses a pronoun
        //     ("Remind me one hour before it starts") and the entity
        //     was established earlier in the conversation.
        //  4. Strip the action-verb prefix from the goal as a last resort.
        let title = extractQuotedTitle(from: userMessage)
            ?? extractQuotedTitle(from: goal)
            ?? extractEntityFromConversation(conversationContext)
            ?? defaultTitleFromGoal(goal, skill: skill)
        guard !title.isEmpty else { return [:] }
        let whenText = extractTemporalHint(
            from: combined + " " + conversationContext) ?? "tomorrow morning"
        // Derive a concrete startIso anchor as a fallback for cases where
        // NSDataDetector can't parse the bare phrase. The skill prefers
        // startIso when present so this just makes the call robust to
        // whenText resolution variance.
        let isoFallback = isoForWhenText(whenText)
        switch skill {
        case "add-calendar-event":
            var args = ["title": title, "whenText": whenText, "durationMin": "30"]
            if let iso = isoFallback { args["startIso"] = iso }
            return args
        case "set-reminder":
            var args = ["title": title, "dueWhen": whenText]
            if let iso = isoFallback { args["dueIso"] = iso }
            return args
        default:
            return [:]
        }
    }

    /// Convert a temporal hint phrase to an ISO 8601 timestamp anchored
    /// to "now". Covers the same vocabulary as `extractTemporalHint`.
    /// Falls back to nil when the phrase needs more parsing than this
    /// helper provides — caller can still pass `whenText` to the skill.
    static func isoForWhenText(_ phrase: String) -> String? {
        let cal = Calendar.current
        let now = Date()
        let lower = phrase.lowercased()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        fmt.timeZone = .current
        fmt.locale = Locale(identifier: "en_US_POSIX")

        // Pull a target day offset from common phrases.
        var dayOffset = 0
        if lower.contains("tomorrow") { dayOffset = 1 }
        else if lower.contains("next ") {
            // "next Friday" etc. — find day-of-week offset 1..7.
            let dow = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
                       "thursday": 5, "friday": 6, "saturday": 7]
            if let weekday = dow.first(where: { lower.contains("next \($0.key)") })?.value {
                let today = cal.component(.weekday, from: now)
                var diff = weekday - today
                if diff <= 0 { diff += 7 }
                dayOffset = diff
            }
        } else if lower.contains("this saturday") {
            let today = cal.component(.weekday, from: now)
            var diff = 7 - today  // Saturday is weekday 7
            if diff < 0 { diff += 7 }
            dayOffset = diff
        }

        // Pull a target hour from common time-of-day phrases or "at Npm".
        var hour = 9   // default morning anchor
        if lower.contains("morning") { hour = 9 }
        else if lower.contains("noon") { hour = 11 }   // before noon → 11am
        else if lower.contains("afternoon") { hour = 14 }
        else if lower.contains("evening") { hour = 18 }
        else if lower.contains("night") { hour = 20 }
        // Explicit "at Hpm" / "at H:MM am" override.
        if let r = try? NSRegularExpression(
            pattern: #"at\s+(\d{1,2})(?::(\d{2}))?\s?(am|pm)?"#,
            options: .caseInsensitive),
           let m = r.firstMatch(
            in: lower,
            range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
           let hRange = Range(m.range(at: 1), in: lower),
           let h = Int(lower[hRange]) {
            var hh = h
            if let amRange = Range(m.range(at: 3), in: lower) {
                let suffix = String(lower[amRange])
                if suffix == "pm" && hh < 12 { hh += 12 }
                else if suffix == "am" && hh == 12 { hh = 0 }
            } else if hh < 8 {
                // Bare "at 5" without am/pm is almost always evening for
                // calendar events ("at 5pm").
                hh += 12
            }
            hour = hh
        }
        guard let target = cal.date(byAdding: .day, value: dayOffset,
                                     to: cal.startOfDay(for: now)),
              let stamped = cal.date(bySettingHour: hour, minute: 0, second: 0,
                                      of: target) else { return nil }
        return fmt.string(from: stamped)
    }

    static func extractQuotedTitle(from text: String) -> String? {
        // Prefer single-quoted, then double-quoted phrases.
        let patterns = [#"'([^']{2,80})'"#, #""([^"]{2,80})""#]
        for p in patterns {
            if let r = try? NSRegularExpression(pattern: p),
               let m = r.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)),
               let inner = Range(m.range(at: 1), in: text) {
                return String(text[inner])
            }
        }
        return nil
    }

    /// When the current request uses a pronoun ("Add IT to my calendar",
    /// "Remind me one hour before IT starts"), the title needs to come
    /// from the most recent prior-turn assistant text. Looks for, in
    /// order: a `Title: X` field (the formatter emits this for
    /// add-calendar-event success envelopes), a quoted phrase, or the
    /// first capitalized noun phrase. Returns nil when nothing matches.
    static func extractEntityFromConversation(_ context: String) -> String? {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Walk assistant blocks newest-to-oldest so the most recent
        // entity wins, but fall back to earlier turns (e.g. yoga case
        // turn 3: latest assistant is a clarification ask, but turn 1
        // established "Yoga for Harmony & Peace" — that's the binding).
        let assistantBlocks = trimmed.components(separatedBy: "Assistant:")
            .dropFirst()                        // drop the "User:" prefix
            .map { $0.components(separatedBy: "User:").first ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for block in assistantBlocks.reversed() {
            if let entity = entityCandidates(in: block) { return entity }
        }
        return nil
    }

    /// Pull an entity-shaped substring out of one assistant text block.
    /// Tries, in order: a `Title: X` field (formatter-emitted),
    /// quoted-phrase, then a 1–4-word TitleCase noun phrase. Filters
    /// out single-word lead-ins ("To", "The") and stopwords.
    static func entityCandidates(in text: String) -> String? {
        if let r = try? NSRegularExpression(
            pattern: #"Title:\s*([^,\n]{2,60})"#, options: .caseInsensitive),
           let m = r.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let inner = Range(m.range(at: 1), in: text) {
            return String(text[inner]).trimmingCharacters(in: .whitespaces)
        }
        if let q = extractQuotedTitle(from: text) { return q }
        // Prefer multi-word TitleCase phrases (more specific) over
        // single-word matches; both are TitleCase but a single word
        // alone is often a sentence start ("Yoga is a practice…")
        // rather than a named entity.
        let stop: Set<String> = [
            "the", "this", "that", "you", "we", "today",
            "tomorrow", "yesterday", "user", "assistant", "no",
            "yes", "ok", "sure", "to", "for", "and", "or",
            "i", "in", "on", "at", "by", "of", "an", "a",
        ]
        if let multi = try? NSRegularExpression(
            pattern: #"\b([A-Z][a-z]+(?:\s+(?:&\s+)?[A-Z][a-z]+){1,4})\b"#) {
            let nsr = NSRange(text.startIndex..<text.endIndex, in: text)
            for m in multi.matches(in: text, range: nsr) {
                guard let inner = Range(m.range(at: 1), in: text)
                else { continue }
                let candidate = String(text[inner])
                if !stop.contains(candidate.lowercased()),
                   candidate.count >= 4 {
                    return candidate
                }
            }
        }
        // Single-word fallback: pick a non-stopword TitleCase noun.
        if let single = try? NSRegularExpression(
            pattern: #"\b([A-Z][a-z]{2,})\b"#) {
            let nsr = NSRange(text.startIndex..<text.endIndex, in: text)
            for m in single.matches(in: text, range: nsr) {
                guard let inner = Range(m.range(at: 1), in: text)
                else { continue }
                let candidate = String(text[inner])
                if !stop.contains(candidate.lowercased()) {
                    return candidate
                }
            }
        }
        return nil
    }

    static func defaultTitleFromGoal(_ goal: String, skill: String) -> String {
        // Last-resort: strip the action verb prefix and use what remains
        // as the title. E.g. "Add coffee with Sam" → "coffee with Sam".
        let lower = goal.lowercased()
        let prefixes = ["add ", "schedule ", "create ", "set a reminder to ",
                        "set a reminder for ", "remind me to ", "remind me about "]
        for p in prefixes where lower.hasPrefix(p) {
            return String(goal.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return skill == "set-reminder" ? "Reminder" : "Event"
    }

    static func extractTemporalHint(from text: String) -> String? {
        let lower = text.lowercased()
        // "tomorrow at 5pm" / "next friday at 5pm" — capture verb + time
        // first because they're the most specific.
        let timeRe = try? NSRegularExpression(
            pattern: #"(tomorrow|today|tonight|next \w+|this \w+)\s+at\s+\d{1,2}(:\d{2})?\s?(am|pm)?"#,
            options: .caseInsensitive)
        if let r = timeRe,
           let m = r.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)),
           let range = Range(m.range, in: text) {
            return String(text[range])
        }
        // Try common bare phrases NSDataDetector can resolve.
        let phrases = [
            "tomorrow morning", "tomorrow afternoon",
            "tomorrow evening", "tomorrow night",
            "this saturday morning", "this sunday morning",
            "this saturday", "this sunday", "this morning",
            "next friday", "next monday", "next tuesday",
            "next wednesday", "next thursday", "next saturday", "next sunday",
            "tomorrow",
        ]
        for p in phrases where lower.contains(p) {
            return p
        }
        // "before noon" / "in the morning" lack a day anchor — promote
        // them to "tomorrow morning" so NSDataDetector can resolve.
        if lower.contains("before noon") || lower.contains("in the morning")
            || lower.contains("morning slot") {
            return "tomorrow morning"
        }
        return nil
    }

    static func allFailuresAreNonRecoverable(_ results: [String: StepResult]) -> Bool {
        let failures = results.values.filter { $0.status == .failed }
        guard !failures.isEmpty else { return false }
        // Permission/auth gates and platform stubs won't change on retry.
        // Planner-shape failures ("unknown skill:", missing-arg) won't
        // change either when every step in the iteration carries one —
        // the model is producing the same hallucination or stripped-args
        // plan, and another replan burns ~25-30s for the same result.
        let markers = [
            "permission denied",
            "access denied",
            "access restricted",
            "not_supported_on_ios",
            "not supported on ios",
            "not allowed on ios",
            "no such file",
            "file not found",
            "unknown skill:",
            "missing '",
            "missing required argument",
            "not a calculator expression",
            "could not extract numeric expression",
        ]
        for f in failures {
            let lower = (f.error ?? "").lowercased()
            if !markers.contains(where: { lower.contains($0) }) { return false }
        }
        return true
    }
}
