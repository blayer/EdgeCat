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

  private fun dateNote(dateStr: String, tomorrowDate: String): String =
    "IMPORTANT: date-time values in toolArgs MUST be yyyy-MM-ddTHH:mm " +
      "(e.g. \"${dateStr}T23:00\", \"${tomorrowDate}T09:00\"). Never use \"today\"/\"tomorrow\"/\"11pm\"."


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
    val skillList = renderSkillCatalog(skills)

    val now = java.time.LocalDateTime.now()
    val dateStr = now.format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"))
    val timeStr = now.format(java.time.format.DateTimeFormatter.ofPattern("HH:mm"))
    val dayOfWeek = now.dayOfWeek.name.lowercase().replaceFirstChar { it.uppercase() }
    val tomorrowDate = now.plusDays(1).format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"))

    return """
You are a task planner. Given a user request and available skills, produce an execution plan as JSON.

Today: $dayOfWeek $dateStr $timeStr. Tomorrow: $tomorrowDate.
${dateNote(dateStr, tomorrowDate)}

Available skills:
$skillList
${if (memoryContext.isNotEmpty()) "\n$memoryContext\n" else ""}
Rules:
- Each step: id, description, skillName (must exist in the catalog — do NOT invent), toolArgs, dependsOn.
- dependsOn lists step IDs that must complete first (empty = parallel). Keep the plan minimal.
- Use available skills. Do NOT answer from knowledge alone.
- `calculate` is math ONLY (e.g. "47*0.15"). For long-form text (itineraries, reports, emails) use `compose`. For condensing text use `summarize`.
- If the request joins TWO actions with "and"/"then"/comma, produce two steps with dependsOn linking them.
- If only a deferred (name-only) skill fits, output a SINGLE step calling `search-skills` with a keyword query; the system re-plans with the loaded skill.

Example — research + synthesize:
Request: "Make a 3-day Tokyo itinerary with weather and events"
Steps: [
  {"id":"step_1","description":"Tokyo weather","skillName":"search-web","toolArgs":{"query":"Tokyo weather forecast next 3 days"},"dependsOn":[]},
  {"id":"step_2","description":"Tokyo seasonal events","skillName":"search-web","toolArgs":{"query":"Tokyo seasonal events April sightseeing"},"dependsOn":[]},
  {"id":"step_3","description":"Write itinerary from step_1 and step_2","skillName":"compose","toolArgs":{"instruction":"Produce a 3-day Tokyo itinerary with hour-by-hour blocks, referencing step_1 weather and step_2 events."},"dependsOn":["step_1","step_2"]}
]

User request: "$userMessage"

Respond with ONLY valid JSON:
```json
{
  "goal": "the user's goal",
  "reasoning": "brief explanation",
  "successCriteria": ["concrete outcome 1 that means the user's request is satisfied", "outcome 2"],
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

successCriteria: 1–3 short, concrete, verifiable outcomes (e.g. "an alarm is set for 7:00 AM tomorrow", "the weather for Tokyo on Friday is shown"). These are judged against the actual step outputs — they should describe observable results, not actions.
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
        renderSkillCatalog(skills) + "\n"

    val now = java.time.LocalDateTime.now()
    val dateStr = now.format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"))
    val tomorrowDate = now.plusDays(1).format(java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"))

    return """
You are a task planner. A previous plan did not fully achieve the user's goal. Create a revised plan.

Today: $dateStr. Tomorrow: $tomorrowDate.
${dateNote(dateStr, tomorrowDate)}

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
  "successCriteria": ["concrete outcome 1", "outcome 2"],
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
        // Small models commonly emit trailing commas and stray commas after string values.
        // Try a light-touch cleanup before giving up on the strict JSON path.
        val repaired = repairJson(jsonStr)
        if (repaired != jsonStr) {
          try {
            return parseJsonPlan(repaired, originalGoal)
          } catch (e2: Exception) {
            Log.w(TAG, "JSON parsing failed after repair, trying regex fallback: ${e2.message}")
          }
        } else {
          Log.w(TAG, "JSON parsing failed, trying regex fallback: ${e.message}")
        }
      }
    }

    // Regex fallback: try to extract steps from semi-structured text.
    return regexFallbackParse(llmOutput, originalGoal)
  }

  /**
   * Light JSON repair for common small-model malformations:
   * - trailing commas before `}` or `]`
   * - stray double/extra commas (e.g. `"skillName":"x",    ,\n"toolArgs":`), which appear when the
   *   model tries to emit a field and abandons it mid-token.
   */
  private fun repairJson(s: String): String {
    var out = s
    // Collapse stray comma-only lines: `, <ws> ,` → `,`
    var prev: String
    do {
      prev = out
      out = Regex(""",\s*,""").replace(out, ",")
    } while (out != prev)
    // Remove trailing commas: ,} or ,]
    out = Regex(""",(\s*[}\]])""").replace(out) { it.groupValues[1] }
    return out
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
   * Render the skill catalog split by tier.
   * - Base skills: full detail (description + extracted data fields).
   * - Deferred skills: name + one-line description only, with a note that the agent can call
   *   `search-skills` to load details before using them.
   */
  private fun renderSkillCatalog(skills: List<SkillSummary>): String {
    val base = skills.filter { it.tier != "deferred" }
    val deferred = skills.filter { it.tier == "deferred" }

    val baseBlock = base.joinToString("\n") { skill ->
      val line = "- ${skill.name}: ${skill.description}"
      if (skill.instructions.isNotEmpty()) {
        val fields = extractDataFields(skill.instructions)
        if (fields.isNotEmpty()) "$line (data fields: $fields)" else line
      } else line
    }

    // Always-available LLM synthesis skills. These are not tool calls — the orchestrator
    // routes them to the LLM with the dependency outputs in context. Listing them explicitly
    // stops the planner from abusing `calculate` or hallucinating skills like `generate_X`
    // for text-generation steps.
    val synthesisBlock = """
- summarize: Condense text from a previous step into a short summary. Use for shortening/extracting. Args: {"text":"..."} (or reference a step via dependsOn — the step output is passed automatically)
- compose: Generate new structured text (itinerary, report, plan, email, explanation) from the goal and previous step outputs. Use for any "make", "write", "produce", "generate", or "build a plan" task that needs long-form text. Args: {"instruction":"what to write"} (dependency outputs are passed automatically)
    """.trimIndent()

    val searchSkillsEntry = """
- search-skills: Look up additional skills by keyword. Use ONLY when no skill above matches the user's request. After running search-skills, the system will re-plan with the matching skills loaded. Args: {"query":"keywords"}
    """.trimIndent()

    val head = if (baseBlock.isBlank()) synthesisBlock else "$baseBlock\n$synthesisBlock"

    if (deferred.isEmpty()) return "$head\n$searchSkillsEntry"

    val deferredBlock = deferred.joinToString("\n") { "- ${it.name}: ${it.description}" }
    return "$head\n$searchSkillsEntry\n\nAdditional skills (name-only — call search-skills first to load details before using):\n$deferredBlock"
  }

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
          toolArgs = toolArgs,
          dependsOn = dependsOn,
        )
      )
    }

    val successCriteria = mutableListOf<String>()
    val criteriaArray = json.optJSONArray("successCriteria")
    if (criteriaArray != null) {
      for (i in 0 until criteriaArray.length()) {
        val item = criteriaArray.optString(i).trim()
        if (item.isNotEmpty()) successCriteria.add(item)
      }
    }

    Log.d(TAG, "Parsed plan: goal=$goal, ${steps.size} steps, ${successCriteria.size} criteria")
    for (step in steps) {
      Log.d(TAG, "  Step ${step.id}: tool=${step.toolName}, skill=${step.skillName}, args=${step.toolArgs}, deps=${step.dependsOn}")
    }
    return ExecutionPlan(goal = goal, reasoning = reasoning, steps = steps, successCriteria = successCriteria)
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
