package com.mobileclaw.app.orchestration

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
