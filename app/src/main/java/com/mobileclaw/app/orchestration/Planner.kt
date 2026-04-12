/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.mobileclaw.app.orchestration

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

private const val TAG = "AGPlanner"

/**
 * Module 1: Planner.
 *
 * Takes a user message + available skills and produces a structured [ExecutionPlan] by asking the
 * LLM to output JSON. Also handles re-planning after a failed evaluation.
 */
class Planner {

  /**
   * Classify whether the user message is an actionable task (requiring device skills/tools)
   * or casual conversation (greeting, chitchat).
   *
   * Uses keyword heuristics to avoid consuming an LLM inference call and corrupting
   * the conversation state.
   *
   * Returns "task" or "chat".
   */
  fun classifyIntent(userMessage: String): String {
    val lower = userMessage.lowercase().trim()

    // Short greetings / small talk patterns.
    val chatPatterns = listOf(
      "^(hi|hey|hello|howdy|yo|sup)\\b",
      "^(good\\s+(morning|afternoon|evening|night))\\b",
      "^how\\s+are\\s+you",
      "^what'?s\\s+up",
      "^thank(s| you)",
      "^(bye|goodbye|see you|later)\\b",
      "^(ok|okay|sure|great|nice|cool|awesome)$",
      "^who\\s+are\\s+you",
      "^what\\s+is\\s+your\\s+name",
      "^tell\\s+me\\s+(about\\s+yourself|a\\s+joke)",
    )
    for (pattern in chatPatterns) {
      if (Regex(pattern).containsMatchIn(lower)) {
        Log.d(TAG, "classifyIntent: '$lower' matched chat pattern '$pattern'")
        return "chat"
      }
    }

    // Task-indicating keywords — actions, device features, skill names.
    val taskKeywords = listOf(
      "search", "find", "look up", "set", "create", "send", "call", "open",
      "calculate", "remind", "alarm", "timer", "weather", "calendar", "email",
      "sms", "message", "photo", "download", "clipboard", "copy", "volume",
      "flashlight", "location", "contacts", "apps", "launch", "share",
      "fetch", "browse", "navigate", "check", "device", "battery",
      "bluetooth", "wifi", "settings", "do not disturb",
      "summarize", "show", "get", "tell me", "what is", "what are",
      "how much", "how many",
    )
    for (keyword in taskKeywords) {
      if (lower.contains(keyword)) {
        Log.d(TAG, "classifyIntent: '$lower' matched task keyword '$keyword'")
        return "task"
      }
    }

    // If the message is a question (contains ?) and longer than a greeting, treat as task.
    if (lower.contains("?") && lower.length > 20) {
      Log.d(TAG, "classifyIntent: '$lower' looks like a substantive question, treating as task")
      return "task"
    }

    // Default: if very short and no task keywords, likely chat.
    val wordCount = lower.split("\\s+".toRegex()).size
    if (wordCount <= 3) {
      Log.d(TAG, "classifyIntent: '$lower' is short ($wordCount words), treating as chat")
      return "chat"
    }

    // Default to task for anything else — better to plan unnecessarily than miss a request.
    Log.d(TAG, "classifyIntent: '$lower' defaulting to task")
    return "task"
  }

  /** Build a prompt that instructs the LLM to output a JSON execution plan. */
  fun buildPlanningPrompt(userMessage: String, skills: List<SkillSummary>, memoryContext: String = ""): String {
    val skillList =
      if (skills.isEmpty()) "No skills available."
      else skills.joinToString("\n") { skill ->
        val base = "- ${skill.name}: ${skill.description}"
        if (skill.instructions.isNotEmpty()) {
          // Extract only data field names from instructions to keep prompt short.
          val fields = extractDataFields(skill.instructions)
          if (fields.isNotEmpty()) "$base (data fields: $fields)" else base
        } else base
      }

    val now = java.time.LocalDateTime.now()
    val dateStr = now.format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"))
    val timeStr = now.format(java.time.format.DateTimeFormatter.ofPattern("HH:mm"))
    val dayOfWeek = now.dayOfWeek.name.lowercase().replaceFirstChar { it.uppercase() }
    val tomorrowDate = now.plusDays(1).format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"))

    return """
You are a task planner. Given a user request and available skills, produce an execution plan as JSON.

Today: $dayOfWeek $dateStr $timeStr. Tomorrow: $tomorrowDate.
IMPORTANT: All date-time values in toolArgs MUST use format yyyy-MM-ddTHH:mm. Examples: "${dateStr}T23:00", "${tomorrowDate}T09:00". Never use "today", "tomorrow", or "11pm" — always convert to this exact format.

Available skills:
$skillList
${if (memoryContext.isNotEmpty()) "\n$memoryContext\n" else ""}
Set "skillName" to the skill name and put input parameters in "toolArgs" as key-value pairs.
For LLM-only steps (like summarize), set skillName to "summarize".

Rules:
- Each step has: id, description, skillName, toolArgs, dependsOn
- dependsOn lists step IDs that must complete first (empty = can run in parallel)
- Keep the plan minimal — fewest steps needed
- Use available skills. Do NOT answer from knowledge alone.

User request: "$userMessage"

Respond with ONLY valid JSON:
```json
{
  "goal": "the user's goal",
  "reasoning": "brief explanation",
  "steps": [
    {
      "id": "step_1",
      "description": "what this step does",
      "skillName": "skill-name or null",
      "toolArgs": {"key":"value"},
      "dependsOn": []
    }
  ]
}
```
""".trimIndent()
  }

  /** Build a prompt for re-planning after a failed evaluation. */
  fun buildReplanPrompt(
    userMessage: String,
    prevPlan: ExecutionPlan,
    results: Map<String, StepResult>,
    evaluation: EvaluationResult,
    skills: List<SkillSummary> = emptyList(),
    memoryContext: String = "",
  ): String {
    val resultsStr =
      results.entries.joinToString("\n") { (id, r) ->
        "- $id (${r.status}): ${r.output.take(200)}${if (r.error != null) " [error: ${r.error}]" else ""}"
      }

    val missingStr = evaluation.missingItems.joinToString("\n") { "- $it" }

    val skillList =
      if (skills.isEmpty()) ""
      else "\nAvailable skills (you MUST use these exact skill names):\n" +
        skills.joinToString("\n") { skill ->
          val base = "- ${skill.name}: ${skill.description}"
          if (skill.instructions.isNotEmpty()) {
            val fields = extractDataFields(skill.instructions)
            if (fields.isNotEmpty()) "$base (data fields: $fields)" else base
          } else base
        } + "\n"

    val now = java.time.LocalDateTime.now()
    val dateStr = now.format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"))
    val tomorrowDate = now.plusDays(1).format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"))

    return """
You are a task planner. A previous plan did not fully achieve the user's goal. Create a revised plan.

Today: $dateStr. Tomorrow: $tomorrowDate.
IMPORTANT: All date-time values in toolArgs MUST use format yyyy-MM-ddTHH:mm. Examples: "${dateStr}T23:00", "${tomorrowDate}T09:00". Never use "today", "tomorrow", or "11pm" — always convert to this exact format.

User request: "$userMessage"
$skillList${if (memoryContext.isNotEmpty()) "\n$memoryContext\n" else ""}
Previous plan: ${prevPlan.reasoning}

Previous results:
$resultsStr

Evaluation: ${evaluation.assessment}

Missing items:
$missingStr

Fix the errors from the previous attempt. Use ONLY skill names from the list above.
Put input parameters in toolArgs as key-value pairs.

Respond with ONLY valid JSON:
```json
{
  "goal": "the user's goal",
  "reasoning": "explanation of revised plan",
  "steps": [
    {
      "id": "step_1",
      "description": "what this step does",
      "skillName": "skill-name or null",
      "toolArgs": {"key":"value"},
      "dependsOn": []
    }
  ]
}
```
""".trimIndent()
  }

  /**
   * Parse LLM output into an [ExecutionPlan].
   *
   * Tries JSON parsing first, then falls back to regex extraction for malformed output.
   */
  fun parsePlan(llmOutput: String, originalGoal: String): ExecutionPlan {
    // Try to extract JSON from the output (may be wrapped in markdown code blocks).
    val jsonStr = extractJson(llmOutput)
    if (jsonStr != null) {
      try {
        return parseJsonPlan(jsonStr, originalGoal)
      } catch (e: Exception) {
        Log.w(TAG, "JSON parsing failed, trying regex fallback: ${e.message}")
      }
    }

    // Regex fallback: try to extract steps from semi-structured text.
    return regexFallbackParse(llmOutput, originalGoal)
  }

  /**
   * Topologically sort plan steps and group independent steps into parallel batches.
   *
   * Returns a list of batches. Steps within a batch have no mutual dependencies and can run in
   * parallel. Batches must execute sequentially.
   */
  fun getExecutionBatches(plan: ExecutionPlan): List<List<PlanStep>> {
    if (plan.steps.isEmpty()) return emptyList()

    val stepsById = plan.steps.associateBy { it.id }
    val inDegree = mutableMapOf<String, Int>()
    val dependents = mutableMapOf<String, MutableList<String>>()

    // Initialize.
    for (step in plan.steps) {
      inDegree[step.id] = 0
      dependents[step.id] = mutableListOf()
    }

    // Build dependency graph.
    for (step in plan.steps) {
      for (dep in step.dependsOn) {
        if (stepsById.containsKey(dep)) {
          inDegree[step.id] = (inDegree[step.id] ?: 0) + 1
          dependents[dep]?.add(step.id)
        }
      }
    }

    val batches = mutableListOf<List<PlanStep>>()
    val remaining = inDegree.toMutableMap()

    while (remaining.isNotEmpty()) {
      // Collect all steps with in-degree 0 — these form the next parallel batch.
      val ready = remaining.filter { it.value == 0 }.keys.toList()

      if (ready.isEmpty()) {
        // Cycle detected — break it by taking all remaining steps.
        Log.w(TAG, "Cycle detected in plan dependencies, forcing remaining steps into one batch")
        batches.add(remaining.keys.mapNotNull { stepsById[it] })
        break
      }

      batches.add(ready.mapNotNull { stepsById[it] })

      // Remove ready steps and decrement dependents.
      for (id in ready) {
        remaining.remove(id)
        for (depId in dependents[id] ?: emptyList()) {
          remaining[depId] = (remaining[depId] ?: 1) - 1
        }
      }
    }

    return batches
  }

  // ---- Private helpers ----

  /**
   * Extract data field names and types from skill instructions.
   * Looks for patterns like "- **fieldName**: description" or "- fieldName: description".
   */
  private fun extractDataFields(instructions: String): String {
    val fieldRegex = Regex("""[-*]\s*\*?\*?(\w+)\*?\*?\s*:\s*([^.\n]{0,60})""")
    val matches = fieldRegex.findAll(instructions)
    val fields = matches.mapNotNull { match ->
      val name = match.groupValues[1].lowercase()
      val desc = match.groupValues[2].trim()
      // Filter out common non-field headings.
      if (name in setOf("instructions", "examples", "constraints", "description", "name")) null
      else "$name ($desc)"
    }.take(5).toList()
    return fields.joinToString(", ")
  }

  /** Extract JSON object from LLM output, handling markdown code fences. */
  private fun extractJson(text: String): String? {
    // Try markdown code block first — capture everything between fences.
    val codeBlockRegex = Regex("```(?:json)?\\s*\\n?(\\{.*\\})\\s*```", RegexOption.DOT_MATCHES_ALL)
    codeBlockRegex.find(text)?.let { return it.groupValues[1].trim() }

    // Try raw JSON object — greedy match to capture nested braces.
    val jsonRegex = Regex("(\\{\\s*\"goal\".*\\})", RegexOption.DOT_MATCHES_ALL)
    jsonRegex.find(text)?.let { return it.groupValues[1].trim() }

    return null
  }

  /** Parse a clean JSON string into an ExecutionPlan. */
  private fun parseJsonPlan(jsonStr: String, originalGoal: String): ExecutionPlan {
    val json = JSONObject(jsonStr)
    val goal = json.optString("goal", originalGoal)
    val reasoning = json.optString("reasoning", "")
    val stepsArray = json.getJSONArray("steps")

    val steps = mutableListOf<PlanStep>()
    for (i in 0 until stepsArray.length()) {
      val stepJson = stepsArray.getJSONObject(i)
      val toolArgs = mutableMapOf<String, String>()
      val argsJson = stepJson.optJSONObject("toolArgs")
      if (argsJson != null) {
        for (key in argsJson.keys()) {
          toolArgs[key] = argsJson.getString(key)
        }
      }

      val dependsOn = mutableListOf<String>()
      val depsArray = stepJson.optJSONArray("dependsOn")
      if (depsArray != null) {
        for (j in 0 until depsArray.length()) {
          dependsOn.add(depsArray.getString(j))
        }
      }

      steps.add(
        PlanStep(
          id = stepJson.getString("id"),
          description = stepJson.optString("description", ""),
          skillName = stepJson.optString("skillName").takeIf { it.isNotEmpty() && it != "null" },
          toolName = stepJson.optString("toolName").takeIf { it.isNotEmpty() && it != "null" },
          toolArgs = toolArgs,
          dependsOn = dependsOn,
        )
      )
    }

    Log.d(TAG, "Parsed plan: goal=$goal, ${steps.size} steps")
    for (step in steps) {
      Log.d(TAG, "  Step ${step.id}: tool=${step.toolName}, skill=${step.skillName}, args=${step.toolArgs}, deps=${step.dependsOn}")
    }
    return ExecutionPlan(goal = goal, reasoning = reasoning, steps = steps)
  }

  /** Fallback parser for when the LLM produces semi-structured but not valid JSON output. */
  private fun regexFallbackParse(text: String, originalGoal: String): ExecutionPlan {
    Log.d(TAG, "Using regex fallback to parse plan")

    // Try to extract individual step-like patterns.
    val stepRegex = Regex("(?:step|\\d+)[_\\s]*(\\d+)[:\\s]+(.+?)(?=(?:step|\\d+)[_\\s]*\\d+[:]|$)", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    val matches: List<MatchResult> = stepRegex.findAll(text).toList()

    val steps =
      if (matches.isNotEmpty()) {
        matches.mapIndexed { index: Int, match: MatchResult ->
          PlanStep(
            id = "step_${index + 1}",
            description = match.groupValues[2].trim().take(200),
            dependsOn = if (index > 0) listOf("step_$index") else emptyList(),
          )
        }
      } else {
        // Last resort: treat the entire output as a single step.
        listOf(
          PlanStep(
            id = "step_1",
            description = "Execute user request: $originalGoal",
          )
        )
      }

    return ExecutionPlan(
      goal = originalGoal,
      reasoning = "Plan extracted via fallback parsing",
      steps = steps,
    )
  }
}
