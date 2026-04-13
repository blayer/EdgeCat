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
import org.json.JSONObject

private const val TAG = "AGSelfEvaluator"

/**
 * Module 3: Self-Evaluator.
 *
 * After execution completes, evaluates whether the user's goal was achieved. If not, indicates what
 * is missing and whether re-planning should occur.
 */
class SelfEvaluator {

  /** Build a prompt asking the LLM to evaluate the execution results against the original goal. */
  fun buildEvaluationPrompt(
    goal: String,
    plan: ExecutionPlan,
    results: Map<String, StepResult>,
  ): String {
    val stepsStr =
      plan.steps.joinToString("\n") { step ->
        val result = results[step.id]
        val status = result?.status?.name ?: "UNKNOWN"
        val output = result?.output?.take(300) ?: "no output"
        val error = if (result?.error != null) " [error: ${result.error}]" else ""
        "- ${step.id} (${step.description}): $status — $output$error"
      }

    // Rubric-based evaluation when the planner emitted success criteria; otherwise fall back
    // to the holistic prompt.
    return if (plan.successCriteria.isNotEmpty()) {
      buildRubricPrompt(goal, plan.successCriteria, stepsStr)
    } else {
      buildHolisticPrompt(goal, stepsStr)
    }
  }

  private fun buildRubricPrompt(goal: String, criteria: List<String>, stepsStr: String): String {
    val criteriaStr = criteria.mapIndexed { i, c -> "${i + 1}. $c" }.joinToString("\n")
    return """
You are a strict QA auditor. Be skeptical.

User's goal: "$goal"

Success criteria (all must be met):
$criteriaStr

Execution results:
$stepsStr

For each criterion, set met=true ONLY if a verbatim substring from a step output supports it; copy that exact substring into `quote`. Otherwise met=false and quote="".
shouldReplan=true only if a revised plan could fix the gaps; false if unrecoverable (missing skill, permission denied).
Output ONLY this JSON — no prose:
```json
{
  "criteria": [
    {"name": "criterion text", "met": true, "quote": "exact substring from a step output", "reason": "short reason"}
  ],
  "failedCriteria": ["criterion text"],
  "shouldReplan": true
}
```
""".trimIndent()
  }

  private fun buildHolisticPrompt(goal: String, stepsStr: String): String {
    return """
You are a strict QA auditor. Be skeptical.

User's goal: "$goal"

Execution results:
$stepsStr

goalAchieved=true ONLY if the core request is clearly satisfied by the step outputs above. missingItems must be empty when true. shouldReplan=true only if a revised plan could plausibly fix the gap.
Output ONLY this JSON — no prose:
```json
{"goalAchieved": false, "missingItems": ["item still needed"], "shouldReplan": true}
```
""".trimIndent()
  }

  /**
   * Parse LLM evaluation output into an [EvaluationResult].
   *
   * Tries JSON parsing first, then falls back to heuristic text analysis.
   * If [stepOutputs] is provided, applies a hallucination guard that overrides
   * goalAchieved=true when the step outputs contain refusal language ("I cannot",
   * "not possible", etc.) — small models sometimes rubber-stamp their own excuses.
   */
  fun parseEvaluation(llmOutput: String, stepOutputs: String = ""): EvaluationResult {
    val parsed = run {
      val jsonStr = extractJson(llmOutput)
      if (jsonStr != null) {
        try {
          return@run parseJsonEvaluation(jsonStr, stepOutputs)
        } catch (e: Exception) {
          Log.w(TAG, "JSON parsing failed for evaluation, using fallback: ${e.message}")
        }
      }
      fallbackParseEvaluation(llmOutput)
    }

    if (parsed.goalAchieved && stepOutputs.isNotEmpty() && REFUSAL_REGEX.containsMatchIn(stepOutputs)) {
      Log.w(TAG, "Hallucination guard: overriding goalAchieved=true (refusal detected in step outputs)")
      return parsed.copy(
        goalAchieved = false,
        shouldReplan = true,
        missingItems = parsed.missingItems.ifEmpty { listOf("Model refused the task — replan with different skills") },
      )
    }
    return parsed
  }

  private companion object {
    private val REFUSAL_REGEX = Regex(
      """(?i)(\bi\s+(?:cannot|can'?t|don'?t\s+have|am\s+unable)\b""" +
        """|\bnot\s+possible\b|\bunable\s+to\b|\bno\s+access\b)"""
    )
  }

  // ---- Private helpers ----

  private fun extractJson(text: String): String? {
    val codeBlockRegex = Regex("```(?:json)?\\s*\\n?(\\{.*?\\})\\s*```", RegexOption.DOT_MATCHES_ALL)
    codeBlockRegex.find(text)?.let { return it.groupValues[1].trim() }

    // Try any JSON object with a recognizable eval field.
    for (key in listOf("criteria", "goalAchieved", "failedCriteria")) {
      val jsonRegex = Regex("(\\{[^{}]*\"$key\"[\\s\\S]*\\})", RegexOption.DOT_MATCHES_ALL)
      jsonRegex.find(text)?.let { return it.groupValues[1].trim() }
    }
    return null
  }

  private fun parseJsonEvaluation(jsonStr: String, stepOutputs: String = ""): EvaluationResult {
    val json = JSONObject(jsonStr)

    // Rubric schema: derive goalAchieved from per-criterion verdicts.
    val criteriaArr = json.optJSONArray("criteria")
    if (criteriaArr != null) {
      val failed = mutableListOf<String>()
      var anyCriterion = false
      val haystack = stepOutputs.lowercase()
      for (i in 0 until criteriaArr.length()) {
        val c = criteriaArr.optJSONObject(i) ?: continue
        anyCriterion = true
        val claimedMet = c.optBoolean("met", false)
        val quote = c.optString("quote", "").trim()
        val name = c.optString("name").ifEmpty { c.optString("reason", "criterion ${i + 1}") }
        // Evidence grounding: when the model claims met=true, the quote must appear verbatim in
        // the step outputs. Small models fabricate evidence; this rejects hallucinated passes.
        val groundedMet = if (claimedMet && haystack.isNotEmpty()) {
          val q = quote.lowercase()
          if (q.length >= 4 && haystack.contains(q)) {
            true
          } else {
            Log.w(TAG, "Evidence grounding rejected criterion '$name' (quote=\"$quote\" not in outputs)")
            false
          }
        } else claimedMet
        if (!groundedMet) failed.add(name)
      }
      // Explicit failedCriteria list also merged (model may emit it even with criteria array).
      val explicitFailed = json.optJSONArray("failedCriteria")
      if (explicitFailed != null) {
        for (i in 0 until explicitFailed.length()) {
          val item = explicitFailed.optString(i).trim()
          if (item.isNotEmpty() && item !in failed) failed.add(item)
        }
      }
      if (anyCriterion) {
        val goalAchieved = failed.isEmpty()
        return EvaluationResult(
          goalAchieved = goalAchieved,
          assessment = if (goalAchieved) "All criteria met" else "Unmet criteria: ${failed.joinToString("; ")}",
          missingItems = failed,
          shouldReplan = !goalAchieved && json.optBoolean("shouldReplan", true),
          failedCriteria = failed,
        )
      }
    }

    // Holistic schema fallback.
    val missingItems = mutableListOf<String>()
    val missingArray = json.optJSONArray("missingItems")
    if (missingArray != null) {
      for (i in 0 until missingArray.length()) {
        missingItems.add(missingArray.getString(i))
      }
    }

    return EvaluationResult(
      goalAchieved = json.optBoolean("goalAchieved", false),
      assessment = json.optString("assessment", ""),
      missingItems = missingItems,
      shouldReplan = json.optBoolean("shouldReplan", false),
    )
  }

  /** Heuristic fallback: check for positive/negative keywords in the text. */
  private fun fallbackParseEvaluation(text: String): EvaluationResult {
    Log.d(TAG, "Using fallback evaluation parsing")
    val lower = text.lowercase()

    val positiveSignals =
      listOf("achieved", "success", "completed", "satisfied", "goal met", "true")
    val negativeSignals = listOf("not achieved", "failed", "missing", "incomplete", "false")

    val positiveCount = positiveSignals.count { lower.contains(it) }
    val negativeCount = negativeSignals.count { lower.contains(it) }

    val goalAchieved = positiveCount > negativeCount

    return EvaluationResult(
      goalAchieved = goalAchieved,
      assessment = text.take(300),
      missingItems = if (!goalAchieved) listOf("Could not parse specific missing items") else emptyList(),
      shouldReplan = !goalAchieved,
    )
  }
}
