package com.edgecat.app.orchestration

import android.util.Log

private const val TAG = "AGSkillCreator"

/**
 * Generates a SKILL.md from a completed orchestration run.
 *
 * Takes the original user request, the execution plan, and step results,
 * then asks the LLM to produce a reusable SKILL.md with parameterized inputs.
 */
class SkillCreator {

  /**
   * Build a prompt that asks the LLM to generate SKILL.md content from a completed orchestration.
   */
  fun buildSkillCreationPrompt(
    skillName: String,
    userMessage: String,
    plan: ExecutionPlan,
    results: Map<String, StepResult>,
  ): String {
    val stepsStr = plan.steps.joinToString("\n") { step ->
      val result = results[step.id]
      val status = result?.status?.name ?: "UNKNOWN"
      val skill = step.skillName ?: "LLM"
      val args = if (step.toolArgs.isNotEmpty()) step.toolArgs.toString() else "{}"
      val deps = if (step.dependsOn.isNotEmpty()) " (depends on: ${step.dependsOn.joinToString(", ")})" else ""
      "- ${step.id}: skill=$skill, args=$args, status=$status$deps"
    }

    return """
You are a skill template generator. Given a completed multi-step orchestration, create a reusable SKILL.md file.

The user ran this request: "$userMessage"

The system executed this plan:
Goal: ${plan.goal}
Steps:
$stepsStr

Now create a SKILL.md that captures this workflow as a reusable skill. The skill should be parameterized so it can be reused with different inputs.

Rules:
- Use EXACTLY this format (the --- delimiters are required):
---
name: $skillName
description: <one-line description of what this workflow does>
---

# Instructions
<describe the multi-step workflow the planner should execute>
<list each step with the skill name and what args to use>
<identify which values should be parameters (e.g., city, date, topic) vs hardcoded>
<use {parameter_name} syntax for variable parts>

Parameters:
- **parameter_name**: description of the parameter

- The name MUST be exactly: $skillName
- Keep instructions concise — the planner will read them to create a plan
- Focus on WHAT skills to call and in WHAT order, not implementation details
- Identify 1-3 key parameters that make this workflow reusable
- Use the exact skill names from the original plan (e.g., search-web, create-calendar-event)
- If a step depends on a previous step's output, describe that dependency

Respond with ONLY the SKILL.md content, starting with --- and ending after the instructions.
""".trimIndent()
  }

  /**
   * Build a prompt for diagnosing and fixing a failed skill step.
   *
   * Given a failed step with its error, device info, and the skill's current instructions,
   * asks the LLM to diagnose the failure and suggest an alternative approach that the
   * planner should use on the next attempt.
   */
  fun buildDiagnosticPrompt(
    failedStep: PlanStep,
    error: String,
    deviceInfo: String,
    skillInstructions: String,
    pastRepairs: String = "",
  ): String {
    val args = if (failedStep.toolArgs.isNotEmpty()) failedStep.toolArgs.toString() else "{}"

    return """
You are a diagnostic assistant. A skill step failed during execution on an Android device. Analyze the error and suggest a fix.

Failed step: ${failedStep.description}
Skill name: ${failedStep.skillName ?: "unknown"}
Tool args: $args
Error: $error

Device info:
$deviceInfo

Current skill instructions:
$skillInstructions
${if (pastRepairs.isNotEmpty()) "\nPrevious repair attempts for this skill:\n$pastRepairs\n" else ""}
Analyze the failure and respond with ONLY valid JSON:
```json
{
  "diagnosis": "brief explanation of why the step failed",
  "fixType": "retry_with_different_args" or "update_instructions" or "use_alternative_skill" or "skip" or "unfixable",
  "alternativeSkillName": "skill-name or null",
  "alternativeArgs": {"key": "value"},
  "updatedInstructions": "if fixType is update_instructions, provide the corrected full skill instructions here, otherwise null"
}
```

Rules:
- "retry_with_different_args": The skill works but was called with wrong args (e.g., malformed date). Provide corrected args.
- "update_instructions": The skill's instructions themselves are wrong or incomplete for this device (e.g., wrong content provider, missing format hints). Provide the full corrected instructions. The system will persist the fix for future use.
- "use_alternative_skill": The skill cannot work on this device (e.g., no clock app for set-alarm). Suggest an alternative.
- "skip": This step is redundant or unnecessary.
- "unfixable": Cannot be fixed automatically (e.g., permission denied).
- If the error is a missing app, suggest an alternative skill
- If the error is bad arguments, use retry_with_different_args
- If the skill instructions are incomplete or wrong for this device, use update_instructions
- If the error is a permission issue, the fix is "unfixable"
- Common patterns: ActivityNotFoundException → use_alternative_skill. DateTimeParseException → retry_with_different_args with yyyy-MM-ddTHH:mm format.
- Keep the diagnosis concise
""".trimIndent()
  }

  /**
   * Parse the LLM diagnostic output into a [DiagnosticResult].
   */
  fun parseDiagnostic(llmOutput: String): DiagnosticResult {
    val jsonStr = extractJson(llmOutput)
    if (jsonStr != null) {
      try {
        val json = org.json.JSONObject(jsonStr)
        val altArgs = mutableMapOf<String, String>()
        val argsJson = json.optJSONObject("alternativeArgs")
        if (argsJson != null) {
          for (key in argsJson.keys()) {
            altArgs[key] = argsJson.optString(key, "")
          }
        }
        return DiagnosticResult(
          diagnosis = json.optString("diagnosis", ""),
          fixType = json.optString("fixType", "unfixable"),
          alternativeSkillName = json.optString("alternativeSkillName").takeIf { it.isNotEmpty() && it != "null" },
          alternativeArgs = altArgs,
          updatedInstructions = json.optString("updatedInstructions").takeIf { it.isNotEmpty() && it != "null" },
        )
      } catch (e: Exception) {
        Log.w(TAG, "Failed to parse diagnostic JSON: ${e.message}")
      }
    }

    // Fallback: unfixable.
    return DiagnosticResult(
      diagnosis = llmOutput.take(200),
      fixType = "unfixable",
    )
  }

  private fun extractJson(text: String): String? {
    val codeBlockRegex = Regex("```(?:json)?\\s*\\n?(\\{.*?\\})\\s*```", RegexOption.DOT_MATCHES_ALL)
    codeBlockRegex.find(text)?.let { return it.groupValues[1].trim() }

    val jsonRegex = Regex("(\\{\\s*\"diagnosis\".*\\})", RegexOption.DOT_MATCHES_ALL)
    jsonRegex.find(text)?.let { return it.groupValues[1].trim() }

    return null
  }

  /**
   * Parse the LLM output to extract clean SKILL.md content.
   * Handles markdown code blocks and extra text around the content.
   */
  fun parseSkillMd(llmOutput: String): String {
    var content = llmOutput.trim()

    // Remove markdown code block wrappers if present.
    val codeBlockRegex = Regex("```(?:markdown|yaml|md)?\\s*\\n?(---.*?)\\s*```", RegexOption.DOT_MATCHES_ALL)
    codeBlockRegex.find(content)?.let {
      content = it.groupValues[1].trim()
    }

    // Ensure it starts with ---.
    if (!content.startsWith("---")) {
      val startIdx = content.indexOf("---")
      if (startIdx >= 0) {
        content = content.substring(startIdx)
      } else {
        Log.w(TAG, "No --- delimiter found in LLM output")
        return content
      }
    }

    Log.d(TAG, "Parsed SKILL.md (${content.length} chars)")
    return content
  }
}
