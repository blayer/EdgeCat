import Foundation

// 1:1 port of android-app/.../orchestration/SkillCreator.kt — produces two
// kinds of LLM prompts:
//   1. Diagnostic — when a step fails after `maxRepair` same-args retries,
//      ask the LLM what's wrong and how to fix it. Returned `DiagnosticResult`
//      drives ExecutionOrchestrator's repair loop.
//   2. Skill creation — given a completed orchestration run, produce a
//      reusable SKILL.md so the workflow can be saved as a JS skill.

public struct SkillCreator: Sendable {
    public let llm: LlmInferenceProvider
    public let policy: ThinkingPolicy

    public init(llm: LlmInferenceProvider,
                policy: ThinkingPolicy = ThinkingPolicy(mode: .auto)) {
        self.llm = llm
        self.policy = policy
    }

    // MARK: - Diagnostic (Phase 8 — failed step repair)

    /// Build a prompt that asks the LLM to diagnose a failed step and
    /// propose a fix. Mirrors Android's `buildDiagnosticPrompt`.
    public static func buildDiagnosticPrompt(failedStep: PlanStep,
                                             error: String,
                                             deviceInfo: String = "",
                                             skillInstructions: String = "",
                                             pastRepairs: String = "") -> String {
        let argsLiteral = failedStep.toolArgs.isEmpty
            ? "{}"
            : prettyArgs(failedStep.toolArgs)
        let pastBlock = pastRepairs.isEmpty
            ? ""
            : "\nPrevious repair attempts for this skill:\n\(pastRepairs)\n"
        return """
        You are a diagnostic assistant. A skill step failed during execution. Analyze the error and suggest a fix.

        Failed step: \(failedStep.description)
        Skill name: \(failedStep.skillName ?? "unknown")
        Tool args: \(argsLiteral)
        Error: \(error)

        Device info:
        \(deviceInfo.isEmpty ? "(none provided)" : deviceInfo)

        Current skill instructions:
        \(skillInstructions.isEmpty ? "(none provided)" : skillInstructions)\(pastBlock)
        Analyze the failure and respond with ONLY valid JSON:
        ```json
        {
          "diagnosis": "brief explanation of why the step failed",
          "fixType": "retry_with_different_args" or "update_instructions" or "use_alternative_skill" or "skip" or "unfixable",
          "alternativeSkillName": "skill-name or null",
          "alternativeArgs": {"key": "value"},
          "updatedInstructions": "if fixType is update_instructions, provide corrected full instructions, otherwise null"
        }
        ```

        Rules:
        - "retry_with_different_args": The skill works but was called with wrong args (e.g. malformed date). Provide corrected args.
        - "update_instructions": The skill's instructions themselves are wrong or incomplete for this device. Provide the full corrected instructions.
        - "use_alternative_skill": The skill cannot work on this device. Suggest an alternative skill name.
        - "skip": This step is redundant or unnecessary.
        - "unfixable": Cannot be fixed automatically (e.g. permission denied).
        - DateTimeParseException → retry_with_different_args with yyyy-MM-ddTHH:mm format.
        - Keep the diagnosis concise.
        """
    }

    /// Run a diagnostic LLM call against the planner's `LlmInferenceProvider`.
    public func diagnose(failedStep: PlanStep,
                         error: String,
                         deviceInfo: String = "",
                         skillInstructions: String = "",
                         pastRepairs: String = "") async -> DiagnosticResult {
        let prompt = Self.buildDiagnosticPrompt(failedStep: failedStep,
                                                error: error,
                                                deviceInfo: deviceInfo,
                                                skillInstructions: skillInstructions,
                                                pastRepairs: pastRepairs)
        do {
            let raw = try await llm.generateResponse(prompt: prompt,
                                                     enableThinking: policy.evaluator())
            return Self.parseDiagnostic(raw)
        } catch {
            return DiagnosticResult(diagnosis: "LLM call failed: \(error.localizedDescription)",
                                    fixType: "unfixable")
        }
    }

    /// Parse the LLM's diagnostic JSON into a `DiagnosticResult`. Falls
    /// back to "unfixable" when the response can't be parsed so the
    /// orchestrator gives up cleanly instead of looping.
    public static func parseDiagnostic(_ raw: String) -> DiagnosticResult {
        guard let jsonStr = extractJson(from: raw),
              let data = jsonStr.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return DiagnosticResult(
                diagnosis: String(raw.prefix(200)),
                fixType: "unfixable")
        }
        let altArgs: [String: String] = (obj["alternativeArgs"] as? [String: Any] ?? [:])
            .compactMapValues {
                if let s = $0 as? String { return s }
                if let n = $0 as? NSNumber { return n.stringValue }
                return nil
            }
        let altName = (obj["alternativeSkillName"] as? String).flatMap {
            ($0.isEmpty || $0 == "null") ? nil : $0
        }
        let updated = (obj["updatedInstructions"] as? String).flatMap {
            ($0.isEmpty || $0 == "null") ? nil : $0
        }
        return DiagnosticResult(
            diagnosis: obj["diagnosis"] as? String ?? "",
            fixType: obj["fixType"] as? String ?? "unfixable",
            alternativeSkillName: altName,
            alternativeArgs: altArgs,
            updatedInstructions: updated)
    }

    // MARK: - Skill creation (Phase 8 — save as skill)

    /// Build a prompt that asks the LLM to generate a SKILL.md template
    /// from a completed orchestration run. Mirrors Android's
    /// `buildSkillCreationPrompt`.
    public static func buildSkillCreationPrompt(skillName: String,
                                                userMessage: String,
                                                plan: ExecutionPlan,
                                                results: [String: StepResult]) -> String {
        let stepsStr = plan.steps.map { step -> String in
            let result = results[step.id]
            let status = result?.status.rawValue ?? "UNKNOWN"
            let skill = step.skillName ?? "LLM"
            let args = step.toolArgs.isEmpty ? "{}" : prettyArgs(step.toolArgs)
            let deps = step.dependsOn.isEmpty
                ? ""
                : " (depends on: \(step.dependsOn.joined(separator: ", ")))"
            return "- \(step.id): skill=\(skill), args=\(args), status=\(status)\(deps)"
        }.joined(separator: "\n")

        return """
        You are a skill template generator. Given a completed multi-step orchestration, create a reusable SKILL.md file.

        The user ran this request: "\(userMessage)"

        The system executed this plan:
        Goal: \(plan.goal)
        Steps:
        \(stepsStr)

        Now create a SKILL.md that captures this workflow as a reusable skill, parameterized so it can be reused with different inputs.

        Rules:
        - Use EXACTLY this format (the --- delimiters are required):
        ---
        name: \(skillName)
        description: <one-line description of what this workflow does>
        ---

        # Instructions
        <describe the multi-step workflow the planner should execute>
        <list each step with the skill name and what args to use>
        <identify which values should be parameters (e.g., city, date, topic) vs hardcoded>
        <use {parameter_name} syntax for variable parts>

        Parameters:
        - **parameter_name**: description of the parameter

        - The name MUST be exactly: \(skillName)
        - Keep instructions concise — the planner will read them to create a plan
        - Focus on WHAT skills to call and in WHAT order, not implementation details
        - Identify 1-3 key parameters that make this workflow reusable
        - Use the exact skill names from the original plan
        - If a step depends on a previous step's output, describe that dependency

        Respond with ONLY the SKILL.md content, starting with --- and ending after the instructions.
        """
    }

    /// Run a skill-creation LLM call.
    public func createSkill(skillName: String,
                            userMessage: String,
                            plan: ExecutionPlan,
                            results: [String: StepResult]) async throws -> String {
        let prompt = Self.buildSkillCreationPrompt(
            skillName: skillName,
            userMessage: userMessage,
            plan: plan,
            results: results)
        return try await llm.generateResponse(prompt: prompt,
                                              enableThinking: policy.saveAsSkill())
    }

    // MARK: - Helpers

    /// Pretty-render `[String: String]` as a JSON-like string the LLM will
    /// recognize. We use this in both prompts so the formatting is
    /// consistent with what the planner emits in its plan output.
    private static func prettyArgs(_ args: [String: String]) -> String {
        let entries = args.keys.sorted().map { key in
            "\"\(key)\": \"\(args[key] ?? "")\""
        }
        return "{" + entries.joined(separator: ", ") + "}"
    }

    /// Extract a JSON object from a possibly-prose LLM reply. Same shape
    /// as `Planner.parsePlanWithStatus` — tolerate code fences and prose.
    private static func extractJson(from text: String) -> String? {
        // Try ```json ... ``` block first.
        if let fenced = text.range(of: #"```(?:json)?\s*\n?(\{[\s\S]*?\})\s*```"#,
                                    options: .regularExpression) {
            let block = String(text[fenced])
            if let inner = block.range(of: "{"),
               let end = block.range(of: "}", options: .backwards),
               inner.lowerBound < end.upperBound {
                return String(block[inner.lowerBound..<end.upperBound])
            }
        }
        // Look for the first balanced { ... } pair containing "diagnosis".
        guard let start = text.firstIndex(of: "{") else { return nil }
        let end = text.lastIndex(of: "}") ?? text.index(before: text.endIndex)
        guard start < end else { return nil }
        return String(text[start...end])
    }
}
