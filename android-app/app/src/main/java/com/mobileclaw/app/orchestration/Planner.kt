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
  fun classifyIntent(
    userMessage: String,
    hasPriorAssistantTurn: Boolean = false,
  ): String {
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
    // Checked BEFORE follow-up markers so "then set an alarm" still routes to task.
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

    // Referential follow-up — pronouns/adverbs that lean on a prior turn and carry no new
    // task of their own. Only routes to chat when a prior assistant reply exists so that a
    // cold-start ambiguous question still gets planned.
    if (hasPriorAssistantTurn) {
      val followUpMarkers = listOf(
        "^(so|then|and|but|ok|okay|well)[,.!?\\s]",
        "\\b(what|how)\\s+(about|else|next|then)\\b",
        "^why(\\s+not)?\\b",
        "^then\\s+what\\b",
        "^(what|which)\\s+(should|do|would|can)\\s+(we|i|you)\\b.*\\b(then|next|now|instead)\\b",
        "\\b(that|those|these|it|they|them|which)\\s+(one|ones)?\\s*[?.!]?$",
      )
      for (pattern in followUpMarkers) {
        if (Regex(pattern).containsMatchIn(lower)) {
          Log.d(TAG, "classifyIntent: '$lower' matched follow-up '$pattern' with prior turn, treating as chat")
          return "chat"
        }
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
  fun buildPlanningPrompt(
    userMessage: String,
    skills: List<SkillSummary>,
    memoryContext: String = "",
    userPortrait: String = "",
    conversationContext: String = "",
    isOnline: Boolean = true,
  ): String {
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
${if (!isOnline) "\n⚠️ OFFLINE: The device has no internet connection. Do NOT plan any steps that require internet (web search, fetching URLs, email). Use only offline skills.\n" else ""}${if (userPortrait.isNotBlank()) "\nAbout the user:\n${userPortrait.trim()}\n" else ""}${if (conversationContext.isNotBlank()) "\nRecent conversation (use as context for the current request):\n${conversationContext.trim()}\n" else ""}
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
   * Result of parsing an LLM planning response. Exposes which repair tier won so
   * the caller can record it in the trace span for attribution.
   */
  data class PlanParseResult(
    val plan: ExecutionPlan,
    val repairApplied: String,
  )

  /**
   * Parse LLM output into an [ExecutionPlan].
   *
   * Tries JSON parsing first, then falls back to regex extraction for malformed output.
   * Kept for call sites that don't care which tier won.
   */
  fun parsePlan(llmOutput: String, originalGoal: String): ExecutionPlan =
    parsePlanWithStatus(llmOutput, originalGoal).plan

  /**
   * Parse LLM output and report which repair tier produced the plan.
   * Tiers in order (returned as [PlanParseResult.repairApplied]):
   *   - "none": valid JSON on first pass
   *   - "commas": light comma cleanup (trailing, stray)
   *   - "quotes": normalize smart/single quotes to ASCII double quotes
   *   - "unquoted-keys": add missing quotes around bareword keys
   *   - "strip-comments": remove `// ...` and `# ...` comment lines
   *   - "balance-braces": append missing closing `}` / `]` for truncated output
   *   - "full": all of the above applied together
   *   - "regex-fallback": none of the JSON tiers worked
   */
  fun parsePlanWithStatus(llmOutput: String, originalGoal: String): PlanParseResult {
    val jsonStr = extractJson(llmOutput)
    if (jsonStr != null) {
      // Ordered list of (tier name, repair fn) pairs. Each is an independent
      // transformation attempted on the ORIGINAL extracted JSON so an earlier
      // tier's half-fix can't mask a later tier's success. "full" is the union
      // of all fixes and wins for pathological cases where a single fix isn't
      // sufficient.
      val tiers = listOf<Pair<String, (String) -> String>>(
        "commas" to ::repairCommas,
        "quotes" to ::repairQuotes,
        "unquoted-keys" to ::repairUnquotedKeys,
        "strip-comments" to ::repairStripComments,
        "balance-braces" to ::repairBalanceBraces,
        "full" to ::repairAll,
      )
      val attempted = mutableListOf("none")
      try {
        return PlanParseResult(parseJsonPlan(jsonStr, originalGoal), "none")
      } catch (e0: Exception) {
        Log.d(TAG, "Plan JSON parse failed (raw): ${e0.message}; trying repairs")
        for ((name, fn) in tiers) {
          val repaired = fn(jsonStr)
          if (repaired == jsonStr) continue
          attempted.add(name)
          try {
            val plan = parseJsonPlan(repaired, originalGoal)
            Log.d(TAG, "Plan JSON parse succeeded after repair tier='$name'")
            return PlanParseResult(plan, name)
          } catch (_: Exception) {
            // Next tier.
          }
        }
        Log.w(TAG, "All JSON repair tiers failed (tried=$attempted), using regex fallback: ${e0.message}")
      }
    }
    return PlanParseResult(regexFallbackParse(llmOutput, originalGoal), "regex-fallback")
  }

  // ---- Repair tiers ----

  /** Small-model comma malformations: trailing commas and stray comma-only gaps. */
  private fun repairCommas(s: String): String {
    var out = s
    var prev: String
    do {
      prev = out
      out = Regex(""",\s*,""").replace(out, ",")
    } while (out != prev)
    out = Regex(""",(\s*[}\]])""").replace(out) { it.groupValues[1] }
    return out
  }

  /** Normalize curly/single quotes the model sometimes emits instead of ASCII ". */
  private fun repairQuotes(s: String): String {
    var out = s
      .replace('\u201C', '"')   // left double
      .replace('\u201D', '"')   // right double
      .replace('\u2018', '"')   // left single → double (JSON has no single-quote strings)
      .replace('\u2019', '"')   // right single
    // If the extracted blob is entirely wrapped with single quotes on keys/values and
    // contains no unescaped double quotes, promote singles to doubles. Guarded on the
    // ratio so we don't stomp legitimate apostrophes inside descriptions.
    val singles = out.count { it == '\'' }
    val doubles = out.count { it == '"' }
    if (singles > 4 && doubles == 0) {
      out = out.replace('\'', '"')
    }
    return out
  }

  /** Add quotes around bareword keys: {goal: "x"} → {"goal": "x"}. */
  private fun repairUnquotedKeys(s: String): String {
    // After { or , (whitespace ok), match an unquoted identifier followed by : — quote it.
    return Regex("""([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:)""")
      .replace(s) { m -> "${m.groupValues[1]}\"${m.groupValues[2]}\"${m.groupValues[3]}" }
  }

  /** Strip `// ...` and `# ...` comment lines some thinking-mode outputs inject. */
  private fun repairStripComments(s: String): String {
    // Only strip when the comment starts a line (guards against `"url":"http://..."`).
    return s.lineSequence()
      .map { line ->
        val trimmed = line.trimStart()
        if (trimmed.startsWith("//") || trimmed.startsWith("#")) "" else line
      }
      .joinToString("\n")
  }

  /** Append missing closing braces/brackets when the model truncated mid-object. */
  private fun repairBalanceBraces(s: String): String {
    // Count structural chars only — naive (ignores chars inside strings) but close enough
    // for small plans where the problem is a clean truncation at the end.
    val opens = s.count { it == '{' }
    val closes = s.count { it == '}' }
    val openBr = s.count { it == '[' }
    val closeBr = s.count { it == ']' }
    if (opens <= closes && openBr <= closeBr) return s
    val sb = StringBuilder(s.trimEnd().trimEnd(','))
    repeat(openBr - closeBr) { sb.append(']') }
    repeat(opens - closes) { sb.append('}') }
    return sb.toString()
  }

  /** All repairs stacked — used as the final tier for pathological outputs. */
  private fun repairAll(s: String): String =
    repairBalanceBraces(
      repairStripComments(
        repairUnquotedKeys(
          repairQuotes(
            repairCommas(s)
          )
        )
      )
    )

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

    // Try raw JSON object — greedy match to capture nested braces. Accept ASCII,
    // smart double, or single quotes around the leading "goal" marker because
    // small models sometimes emit curly quotes or single quotes; the repair
    // pipeline normalizes them later.
    val jsonRegex = Regex(
      "(\\{\\s*[\"\u201C\u201D\u2018\u2019']goal.*\\})",
      RegexOption.DOT_MATCHES_ALL,
    )
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

    val inferredSkill = inferSkillFromGoal(originalGoal)

    val steps =
      if (matches.isNotEmpty() && inferredSkill == null) {
        matches.mapIndexed { index: Int, match: MatchResult ->
          PlanStep(
            id = "step_${index + 1}",
            description = match.groupValues[2].trim().take(200),
            dependsOn = if (index > 0) listOf("step_$index") else emptyList(),
          )
        }
      } else {
        // When we can infer a skill from the goal, prefer a single-step plan with
        // the original goal as the description — garbled LLM output produces
        // junk step descriptions (e.g. "0 PM.\",\n\"reasoning\"...") that are
        // worse than just echoing what the user asked for.
        listOf(
          PlanStep(
            id = "step_1",
            description = "Execute user request: $originalGoal",
            skillName = inferredSkill,
          )
        )
      }

    return ExecutionPlan(
      goal = originalGoal,
      reasoning = "Plan extracted via fallback parsing (inferredSkill=$inferredSkill)",
      steps = steps,
    )
  }

  /**
   * When JSON parsing fails entirely, infer a single skill from the user's goal
   * using simple keyword matching. This lets the orchestrator engage its
   * arg-rescue path (e.g. [ExecutionOrchestrator.rescueCalendarFromDescription])
   * instead of dropping to an LLM-only response that ignores the user's intent.
   */
  private fun inferSkillFromGoal(goal: String): String? {
    val lower = goal.lowercase()
    return when {
      Regex("""\b(calendar|reminder|meeting|appointment|event)\b""").containsMatchIn(lower) -> "calendar"
      Regex("""\b(alarm|timer|countdown|wake me|snooze)\b""").containsMatchIn(lower) -> "timer"
      Regex("""\b(sms|text message|send .*\bto\b)\b""").containsMatchIn(lower) -> "sms"
      Regex("""\bweather\b""").containsMatchIn(lower) -> "weather"
      Regex("""\b(calculate|what is.*[+\-*/]|\d+\s*(?:plus|minus|times|divided))\b""").containsMatchIn(lower) -> "calculator"
      Regex("""\b(search.*web|google|find online|latest news|look up)\b""").containsMatchIn(lower) -> "web_search"
      else -> null
    }
  }
}
