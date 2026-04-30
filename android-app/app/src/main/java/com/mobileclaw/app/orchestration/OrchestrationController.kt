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
import com.mobileclaw.app.memory.Episode
import com.mobileclaw.app.memory.MemoryRepository
import com.mobileclaw.app.memory.RepairRecord
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

private const val TAG = "AGOrchestrationController"

/**
 * True when [output] is a search-web results listing with no fetched page content.
 * Search results contain query tokens that would trivially satisfy the triage
 * goal-token check, but they're just links — not an answer. Detected by the
 * formatted header `OrchestrationBridge` emits ("Search results for: …")
 * combined with the absence of "Page content from" (emitted by fetch-web-content).
 */
internal fun isBareSearchResults(output: String): Boolean {
  val lower = output.lowercase()
  if (!lower.contains("search results for")) return false
  return !lower.contains("page content from")
}

// Common English stop words filtered when extracting goal-relevance tokens for triage.
private val STOP_WORDS = setOf(
  "about", "after", "again", "also", "been", "before", "could", "does", "doing", "from",
  "have", "here", "into", "just", "like", "more", "much", "need", "only", "over", "please",
  "some", "such", "than", "that", "their", "them", "then", "there", "these", "they",
  "this", "those", "through", "want", "were", "what", "when", "where", "which", "while",
  "will", "with", "would", "your",
)

/**
 * Public API for the orchestration module.
 *
 * Wires together [Planner], [ExecutionOrchestrator], and [SelfEvaluator] into a plan → execute →
 * evaluate loop. The app creates this controller, calls [run], observes [state], and optionally
 * calls [cancel].
 *
 * Usage:
 * ```
 * val controller = OrchestrationController(llmProvider, toolExecutor)
 * scope.launch { controller.run("Look up X and generate a QR code") }
 * controller.state.collect { state -> updateUI(state) }
 * ```
 */
class OrchestrationController(
  private val llmProvider: LlmInferenceProvider,
  private val toolExecutor: ToolExecutor,
  private val memoryRepository: MemoryRepository? = null,
  private val maxIterations: Int = 3,
  private val maxRepairAttempts: Int = 2,
  thinkingMode: ThinkingMode = ThinkingMode.AUTO,
  private val userPortraitProvider: () -> String = { "" },
  private val trace: TraceRecorder? = null,
) {
  private val thinkingPolicy = ThinkingPolicy(thinkingMode)
  private val planner = Planner()
  private val orchestrator = ExecutionOrchestrator(llmProvider, toolExecutor, thinkingPolicy)
  private val evaluator = SelfEvaluator()
  private val skillCreator = SkillCreator()

  private suspend inline fun <T> phase(kind: String, name: String, crossinline block: suspend () -> T): T {
    val handle = trace?.start(kind, name)
    return try {
      val r = block()
      handle?.end(status = "ok")
      r
    } catch (t: Throwable) {
      handle?.end(status = "error", error = t.message)
      throw t
    }
  }

  // Variant that exposes the span handle so the block can tag per-subsystem
  // attrs (prompt_chars, response_chars, thinking, iteration). Handle is nullable
  // so this stays a no-op when tracing is off.
  private suspend inline fun <T> phaseAttr(
    kind: String,
    name: String,
    crossinline block: suspend (TraceRecorder.SpanHandle?) -> T,
  ): T {
    val handle = trace?.start(kind, name)
    return try {
      val r = block(handle)
      handle?.end(status = "ok")
      r
    } catch (t: Throwable) {
      handle?.end(status = "error", error = t.message)
      throw t
    }
  }

  private val _state = MutableStateFlow(OrchestrationState())
  val state: StateFlow<OrchestrationState> = _state.asStateFlow()

  private val cancelled = AtomicBoolean(false)

  /**
   * Main entry point: plan → execute → evaluate → loop.
   *
   * This is a suspending function that runs the full orchestration loop. It updates [state] at each
   * phase so the UI can react.
   */
  suspend fun run(userMessage: String, conversationContext: String = "", isOnline: Boolean = true) {
    cancelled.set(false)
    _state.value =
      OrchestrationState(
        status = OrchestrationStatus.PLANNING,
        maxIterations = maxIterations,
      )

    try {
      // ---- Phase 0: Recall memory ----
      val memoryContext = phase("memory", "recall") {
        try {
          memoryRepository?.recallForPlanning(userMessage) ?: ""
        } catch (e: Exception) {
          Log.w(TAG, "Memory recall failed, continuing without memory", e)
          ""
        }
      }
      val memoryFound = memoryContext.isNotEmpty()
      _state.value = _state.value.copy(memoryRecalled = memoryFound)
      if (memoryFound) {
        Log.d(TAG, "Memory context (${memoryContext.length} chars): ${memoryContext.take(200)}...")
      } else {
        Log.d(TAG, "No memory found for: $userMessage")
      }

      // ---- Phase 1: Plan ----
      Log.d(TAG, "Phase 1: Planning for: $userMessage (online=$isOnline)")
      val rawSkills = toolExecutor.getAvailableSkills()
        .let { all ->
          if (isOnline) all
          else all.filter { it.name !in ConnectivityChecker.INTERNET_SKILLS }
        }
      // Deferred skills loaded via search-skills during this run — upgraded to "base" tier
      // so subsequent plans see their full details.
      val loadedDeferred = mutableSetOf<String>()
      fun skillsForPlanning(): List<SkillSummary> = rawSkills.map {
        if (loadedDeferred.contains(it.name)) it.copy(tier = "base") else it
      }
      var skills = skillsForPlanning()
      val planPrompt = planner.buildPlanningPrompt(userMessage, skills, memoryContext, userPortraitProvider(), conversationContext, isOnline)
      val planningThinking = thinkingPolicy.planner(userMessage, iteration = 0)
      _state.value = _state.value.copy(
        thinkingByPhase = _state.value.thinkingByPhase + ("planning" to planningThinking),
      )
      val plan = phaseAttr("planner", "plan") { h ->
        h?.attr("prompt_chars", planPrompt.length)
        h?.attr("thinking", planningThinking)
        h?.attr("iteration", 0)
        h?.attr("skill_catalog_size", skills.size)
        val planResponse = llmProvider.generateResponse(
          planPrompt,
          enableThinking = planningThinking,
        )
        h?.attr("response_chars", planResponse.length)
        val parsed = planner.parsePlanWithStatus(planResponse, userMessage)
        h?.attr("json_repair", parsed.repairApplied)
        parsed.plan
      }

      Log.d(TAG, "Plan created with ${plan.steps.size} steps")
      _state.value =
        _state.value.copy(
          status = OrchestrationStatus.EXECUTING,
          plan = plan,
          iteration = 1,
        )

      // ---- Phase 2+3: Execute → Evaluate loop ----
      var currentPlan = plan
      for (iteration in 1..maxIterations) {
        if (cancelled.get()) {
          Log.d(TAG, "Cancelled before iteration $iteration")
          _state.value = _state.value.copy(status = OrchestrationStatus.CANCELLED)
          return
        }

        Log.d(TAG, "Iteration $iteration: Executing plan")
        _state.value =
          _state.value.copy(
            status = OrchestrationStatus.EXECUTING,
            plan = currentPlan,
            iteration = iteration,
            stepResults = emptyMap(),
            evaluation = null,
          )

        // Execute.
        val batches = planner.getExecutionBatches(currentPlan)
        val results = phase("orchestrator", "execute_plan.iter_$iteration") {
          orchestrator.executePlan(currentPlan, batches) { stepResult ->
            // Update state as each step completes.
            _state.value =
              _state.value.copy(
                stepResults = _state.value.stepResults + (stepResult.stepId to stepResult)
              )
            trace?.start("step", stepResult.stepId)?.apply {
              attr("skill", stepResult.stepId)
              attr("status", stepResult.status.name)
              attr("duration_ms", stepResult.durationMs)
              if (!stepResult.error.isNullOrEmpty()) attr("error", stepResult.error)
              end(status = if (stepResult.status == StepStatus.COMPLETED) "ok" else "error",
                  error = stepResult.error)
            }
          }
        }

        val repairedResults = results
        _state.value = _state.value.copy(stepResults = repairedResults)

        if (cancelled.get()) {
          _state.value = _state.value.copy(status = OrchestrationStatus.CANCELLED)
          return
        }

        // Detect search-skills usage and absorb loaded deferred skills into the catalog.
        // If the plan was a discovery step (search-skills only), bypass evaluation and force
        // a replan so the model picks a real skill using the newly-loaded details.
        val searchSkillsSteps = currentPlan.steps.filter {
          it.skillName?.replace('_', '-') == "search-skills"
        }
        var newlyLoadedCount = 0
        for (step in searchSkillsSteps) {
          val r = repairedResults[step.id] ?: continue
          if (r.status != StepStatus.COMPLETED) continue
          try {
            val json = org.json.JSONObject(r.output)
            val arr = json.optJSONArray("loaded") ?: continue
            for (i in 0 until arr.length()) {
              val name = arr.optString(i)
              if (name.isNotEmpty() && loadedDeferred.add(name)) newlyLoadedCount++
            }
          } catch (e: Exception) {
            Log.w(TAG, "Failed to parse search-skills output on step ${step.id}", e)
          }
        }
        val onlyDiscovery = searchSkillsSteps.isNotEmpty() &&
          currentPlan.steps.all { it.skillName?.replace('_', '-') == "search-skills" }
        if (onlyDiscovery && newlyLoadedCount > 0 && iteration < maxIterations) {
          Log.d(TAG, "Discovery iteration: loaded $newlyLoadedCount deferred skill(s), forcing replan")
          skills = skillsForPlanning()
          val discoveryReplanPrompt = planner.buildPlanningPrompt(userMessage, skills, memoryContext, userPortraitProvider(), conversationContext)
          val discoveryReplanThinking = thinkingPolicy.planner(userMessage, iteration = iteration)
          _state.value = _state.value.copy(
            thinkingByPhase = _state.value.thinkingByPhase + ("replanning" to discoveryReplanThinking),
          )
          currentPlan = phaseAttr("planner", "replan.discovery.iter_$iteration") { h ->
            h?.attr("prompt_chars", discoveryReplanPrompt.length)
            h?.attr("thinking", discoveryReplanThinking)
            h?.attr("iteration", iteration)
            h?.attr("newly_loaded_skills", newlyLoadedCount)
            val discoveryReplanResponse = llmProvider.generateResponse(
              discoveryReplanPrompt,
              enableThinking = discoveryReplanThinking,
            )
            h?.attr("response_chars", discoveryReplanResponse.length)
            val parsed = planner.parsePlanWithStatus(discoveryReplanResponse, userMessage)
            h?.attr("json_repair", parsed.repairApplied)
            parsed.plan
          }
          _state.value = _state.value.copy(status = OrchestrationStatus.REPLANNING, plan = currentPlan)
          continue
        }

        // Evaluate — skip LLM call when the happy path is obvious (all steps COMPLETED,
        // no error signals in output). Saves one LLM call per successful turn.
        Log.d(TAG, "Iteration $iteration: Evaluating results")
        _state.value = _state.value.copy(status = OrchestrationStatus.EVALUATING)

        val triaged = triageEvaluation(userMessage, currentPlan, repairedResults)
        val evaluation = if (triaged != null) {
          Log.d(TAG, "Short-circuit eval: ${triaged.assessment}")
          trace?.start("evaluator", "triage")?.apply {
            attr("goal_achieved", triaged.goalAchieved)
            attr("should_replan", triaged.shouldReplan)
            end(status = "ok")
          }
          triaged
        } else {
          phaseAttr("evaluator", "judge.iter_$iteration") { h ->
            val evalPrompt = evaluator.buildEvaluationPrompt(userMessage, currentPlan, repairedResults)
            val evalThinking = thinkingPolicy.evaluator()
            _state.value = _state.value.copy(
              thinkingByPhase = _state.value.thinkingByPhase + ("evaluating" to evalThinking),
            )
            h?.attr("prompt_chars", evalPrompt.length)
            h?.attr("thinking", evalThinking)
            h?.attr("iteration", iteration)
            val evalResponse = llmProvider.generateResponse(
              evalPrompt,
              enableThinking = evalThinking,
            )
            h?.attr("response_chars", evalResponse.length)
            val combinedOutputs = repairedResults.values.joinToString("\n") { it.output }
            evaluator.parseEvaluation(evalResponse, combinedOutputs)
          }
        }

        Log.d(TAG, "Evaluation: goalAchieved=${evaluation.goalAchieved}, shouldReplan=${evaluation.shouldReplan}")
        // Preview the replan thinking flag now so the UI's "Re-planning..." label (which fires on
        // evaluation becoming non-null) can reflect it in the same render pass.
        val replanPreviewThinking = if (evaluation.shouldReplan && iteration < maxIterations) {
          thinkingPolicy.replan(replanAttempt = iteration)
        } else null
        _state.value = _state.value.copy(
          evaluation = evaluation,
          thinkingByPhase = if (replanPreviewThinking != null)
            _state.value.thinkingByPhase + ("replanning" to replanPreviewThinking)
          else _state.value.thinkingByPhase,
        )

        if (evaluation.goalAchieved) {
          Log.d(TAG, "Goal achieved on iteration $iteration")
          _state.value = _state.value.copy(status = OrchestrationStatus.FORMATTING)
          val (finalOutput, isHtml) = phase("formatter", "build_final_output") {
            buildFinalOutput(userMessage, currentPlan, repairedResults, evaluation)
          }
          _state.value =
            _state.value.copy(
              status = OrchestrationStatus.COMPLETED,
              finalOutput = finalOutput,
              finalOutputIsHtml = isHtml,
            )
          saveEpisodeToMemory(userMessage, currentPlan, repairedResults, "success")
          return
        }

        if (!evaluation.shouldReplan || iteration == maxIterations) {
          Log.d(TAG, "Stopping: shouldReplan=${evaluation.shouldReplan}, iteration=$iteration/$maxIterations")
          _state.value = _state.value.copy(status = OrchestrationStatus.FORMATTING)
          val (finalOutput, isHtml) = phase("formatter", "build_final_output") {
            buildFinalOutput(userMessage, currentPlan, repairedResults, evaluation)
          }
          _state.value =
            _state.value.copy(
              status = OrchestrationStatus.COMPLETED,
              finalOutput = finalOutput,
              finalOutputIsHtml = isHtml,
            )
          val hasAnySuccess = repairedResults.values.any { it.status == StepStatus.COMPLETED }
          saveEpisodeToMemory(userMessage, currentPlan, repairedResults, if (hasAnySuccess) "partial" else "failure")
          return
        }

        // Build diagnostic notes for any steps that are still failed after repair.
        if (cancelled.get()) {
          _state.value = _state.value.copy(status = OrchestrationStatus.CANCELLED)
          return
        }

        val stillFailedSteps = currentPlan.steps.filter { step ->
          repairedResults[step.id]?.status == StepStatus.FAILED
        }
        val diagnosticNotes = buildDiagnosticNotesForReplan(stillFailedSteps, repairedResults)

        // Replan with diagnostic notes.
        Log.d(TAG, "Re-planning for iteration ${iteration + 1}")
        val replanThinking = thinkingPolicy.replan(replanAttempt = iteration)
        _state.value = _state.value.copy(
          status = OrchestrationStatus.REPLANNING,
          thinkingByPhase = _state.value.thinkingByPhase + ("replanning" to replanThinking),
        )

        skills = skillsForPlanning()
        val replanPrompt =
          planner.buildReplanPrompt(userMessage, currentPlan, repairedResults, evaluation, skills, memoryContext)
        val fullReplanPrompt = if (diagnosticNotes.isNotEmpty()) {
          "$replanPrompt\n\nAuto-diagnostic notes (use these to fix the plan):$diagnosticNotes"
        } else {
          replanPrompt
        }
        currentPlan = phaseAttr("planner", "replan.iter_$iteration") { h ->
          h?.attr("prompt_chars", fullReplanPrompt.length)
          h?.attr("thinking", replanThinking)
          h?.attr("iteration", iteration)
          h?.attr("failed_step_count", stillFailedSteps.size)
          val replanResponse = llmProvider.generateResponse(
            fullReplanPrompt,
            enableThinking = replanThinking,
          )
          h?.attr("response_chars", replanResponse.length)
          val parsed = planner.parsePlanWithStatus(replanResponse, userMessage)
          h?.attr("json_repair", parsed.repairApplied)
          parsed.plan
        }

        Log.d(TAG, "Revised plan has ${currentPlan.steps.size} steps")
      }

      // Should not reach here, but just in case.
      _state.value = _state.value.copy(status = OrchestrationStatus.COMPLETED)
    } catch (e: Exception) {
      Log.e(TAG, "Orchestration failed", e)
      _state.value =
        _state.value.copy(
          status = OrchestrationStatus.ERROR,
          error = e.message ?: "Unknown error",
        )
    }
  }

  /** Cancel the orchestration loop. Safe to call from any thread. */
  fun cancel() {
    Log.d(TAG, "Cancel requested")
    cancelled.set(true)
    orchestrator.cancel()
  }

  /** Reset to idle state. Call before starting a new orchestration run. */
  fun reset() {
    cancelled.set(false)
    _state.value = OrchestrationState()
  }

  /**
   * Rules-first triage of the evaluation step. Returns a deterministic [EvaluationResult] when the
   * outcome is unambiguous and [null] when the LLM judge should decide. Saves an LLM call per turn
   * on both the clean-success and clean-failure paths, and reduces rubber-stamp bias on small
   * models by keeping the judge out of cases where rules are sufficient.
   *
   * - definite_success: every step COMPLETED with non-empty output and no error markers.
   * - definite_failure: at least one step FAILED with no recovery (no other step COMPLETED).
   * - ambiguous: mixed success/failure — fall through to the LLM judge.
   */
  private fun triageEvaluation(
    userMessage: String,
    plan: ExecutionPlan,
    results: Map<String, StepResult>,
  ): EvaluationResult? {
    if (plan.steps.isEmpty()) return null
    val errorMarkers = Regex(
      """(?i)(\b(failed|error|exception|denied|unauthorized|not\s+found|invalid)\b""" +
        """|\bi\s+(?:cannot|can'?t|don'?t\s+have|am\s+unable)\b""" +
        """|\bnot\s+possible\b|\bunable\s+to\b|\bno\s+access\b)"""
    )

    var allClean = true
    val failed = mutableListOf<PlanStep>()
    var anyCompleted = false
    for (step in plan.steps) {
      val r = results[step.id] ?: return null
      when (r.status) {
        StepStatus.FAILED -> { failed.add(step); allClean = false }
        StepStatus.COMPLETED -> {
          anyCompleted = true
          if (r.output.isBlank() || errorMarkers.containsMatchIn(r.output)) allClean = false
        }
        else -> return null
      }
    }

    if (allClean) {
      // Relevance guard: if none of the goal's content words appear in the combined outputs,
      // fall through to the LLM judge rather than rubber-stamping a clean-but-irrelevant run.
      val combined = plan.steps.mapNotNull { results[it.id]?.output }.joinToString("\n").lowercase()
      val goalTokens = userMessage.lowercase()
        .split(Regex("[^a-z0-9]+"))
        .filter { it.length >= 4 && it !in STOP_WORDS }
      val relevant = goalTokens.isEmpty() || goalTokens.any { combined.contains(it) }
      if (!relevant) {
        Log.d(TAG, "Triage: clean steps but no goal tokens in output — deferring to LLM judge")
        return null
      }
      // Bare-search guard: search-web's output ("Search results for: …") contains
      // the user's query tokens as titles + snippets, so the goal-token check above
      // trivially passes. But links are not an answer. When the last step's output
      // is a search-results listing with no fetch-web-content follow-up, defer to
      // the LLM judge so it can say shouldReplan=true and the planner can chain
      // the fetch step.
      val lastOutput = plan.steps.lastOrNull()?.let { results[it.id]?.output }.orEmpty()
      if (isBareSearchResults(lastOutput)) {
        Log.d(TAG, "Triage: last step is bare search results — deferring to LLM judge")
        return null
      }
      return EvaluationResult(
        goalAchieved = true,
        assessment = "All steps completed",
        missingItems = emptyList(),
        shouldReplan = false,
      )
    }

    // Definite failure: at least one step failed and nothing else succeeded → no recovery path.
    if (failed.isNotEmpty() && !anyCompleted) {
      val reasons = failed.map { s ->
        val r = results[s.id]
        val detail = (r?.error ?: r?.output ?: "").take(160)
        "${s.id} (${s.skillName ?: "llm"}): $detail"
      }
      return EvaluationResult(
        goalAchieved = false,
        assessment = "All steps failed with no recovery path",
        missingItems = reasons,
        shouldReplan = true,
        failedCriteria = failed.map { it.id },
      )
    }

    return null
  }

  /**
   * Build replan notes listing each failed step's raw error text. This replaces the older
   * per-step diagnostic LLM call, which research (Claude/Gemini/OpenAI agent guides) shows
   * tends to compound errors on small models. The replan prompt itself is the single place
   * where the LLM reasons about the failure and picks a new plan.
   */
  private fun buildDiagnosticNotesForReplan(
    failedSteps: List<PlanStep>,
    results: Map<String, StepResult>,
  ): String {
    if (failedSteps.isEmpty()) return ""
    return buildString {
      for (failedStep in failedSteps) {
        val r = results[failedStep.id] ?: continue
        val err = (r.error ?: r.output).take(300)
        append("\n- Step '${failedStep.id}' (${failedStep.skillName ?: "llm"}) failed: $err")
      }
    }
  }

  /** Build a summary of the final output from all step results. Returns (output, isHtml). */
  private suspend fun buildFinalOutput(
    userMessage: String,
    plan: ExecutionPlan,
    results: Map<String, StepResult>,
    evaluation: EvaluationResult,
  ): Pair<String, Boolean> {
    // Collect all completed step outputs with their descriptions.
    val completedSteps = plan.steps
      .mapNotNull { step ->
        val result = results[step.id]?.takeIf { it.status == StepStatus.COMPLETED && it.output.isNotBlank() }
        if (result != null) step to result else null
      }

    if (completedSteps.isEmpty()) {
      return "No output produced." to false
    }

    // Build context from all steps so the LLM can produce a coherent response.
    // Single-step budget is larger since search/fetch results carry substantive content.
    val rawOutput = if (completedSteps.size == 1) {
      completedSteps.first().second.output.take(3500)
    } else {
      // The final step in a sequential plan is almost always the answer-bearing one
      // (e.g. get-location → search-web → fetched content). Give it most of the budget
      // so its substantive output isn't truncated away in favor of plumbing steps.
      val lastIdx = completedSteps.lastIndex
      completedSteps.mapIndexed { idx, (step, result) ->
        val budget = if (idx == lastIdx) 2800 else 400
        "Step: ${step.description}\nResult: ${result.output.take(budget)}"
      }.joinToString("\n\n").take(3800)
    }

    // If the output is a full HTML document (not just a snippet with stray tags), return as-is.
    val trimmedRaw = rawOutput.trimStart()
    val isHtml = trimmedRaw.startsWith("<!DOCTYPE", ignoreCase = true) ||
      trimmedRaw.startsWith("<html", ignoreCase = true) ||
      (trimmedRaw.startsWith("<") && Regex("(?i)</(html|body|div|section|article|main)>").containsMatchIn(trimmedRaw))
    if (isHtml) {
      return rawOutput.trim() to true
    }

    // Preprocess Kotlin map-toString into indented key/value text.
    val preprocessed = ResponseFormatter.preprocess(rawOutput)

    // Short-circuit: render trivial outputs directly without an LLM call.
    val trivial = ResponseFormatter.tryTrivialRender(rawOutput)
    if (trivial != null) {
      Log.d(TAG, "Trivial render bypassed formatter LLM (${trivial.length} chars)")
      return trivial to false
    }

    // Format preprocessed output through LLM for a human-friendly response.
    try {
      val formatted = formatResultWithLlm(userMessage, preprocessed)
      if (formatted.isNotBlank()) {
        return formatted to false
      }
    } catch (e: Exception) {
      Log.w(TAG, "Result formatting failed, using preprocessed output", e)
    }

    return preprocessed.trim() to false
  }

  /**
   * Use the LLM to rephrase preprocessed tool output into a human-friendly response.
   * Uses few-shot examples + <msg> wrapper; thinking toggles on only for complex outputs.
   */
  private suspend fun formatResultWithLlm(userMessage: String, preprocessed: String): String {
    val prompt = ResponseFormatter.buildPrompt(userMessage, preprocessed)
    val complex = ResponseFormatter.isComplexOutput(preprocessed)
    val formatThinking = thinkingPolicy.format(complexOutput = complex)
    _state.value = _state.value.copy(
      thinkingByPhase = _state.value.thinkingByPhase + ("formatting" to formatThinking),
    )
    Log.d(TAG, "Formatting (complex=$complex, thinking=$formatThinking, input=${preprocessed.length} chars)")
    return phaseAttr("formatter", "llm") { h ->
      h?.attr("prompt_chars", prompt.length)
      h?.attr("thinking", formatThinking)
      h?.attr("complex_output", complex)
      h?.attr("preprocessed_chars", preprocessed.length)
      val response = llmProvider.generateResponse(
        prompt,
        enableThinking = formatThinking,
      )
      h?.attr("response_chars", response.length)
      val extracted = ResponseFormatter.extractMessage(response)
      h?.attr("extracted_chars", extracted.length)
      Log.d(TAG, "Formatter response raw=${response.length} chars, extracted=${extracted.length} chars")
      extracted
    }
  }

  /** Get basic device info for diagnostic context. */
  private fun getDeviceInfo(): String {
    return "Android ${android.os.Build.VERSION.RELEASE} (SDK ${android.os.Build.VERSION.SDK_INT}), " +
      "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}"
  }

  /** Save an episode to memory after orchestration completes. */
  private suspend fun saveEpisodeToMemory(
    userMessage: String,
    plan: ExecutionPlan,
    results: Map<String, StepResult>,
    outcome: String,
  ) {
    try {
      val skillsUsed = plan.steps.mapNotNull { it.skillName }.distinct()
      val lastOutput = plan.steps
        .mapNotNull { results[it.id]?.takeIf { r -> r.status == StepStatus.COMPLETED } }
        .lastOrNull()?.output ?: ""
      memoryRepository?.saveEpisode(
        Episode(
          id = UUID.randomUUID().toString(),
          userMessage = userMessage,
          goal = plan.goal,
          skillsUsed = skillsUsed,
          outcome = outcome,
          stepCount = plan.steps.size,
          finalOutput = lastOutput.take(500),
        )
      )
      memoryRepository?.evictIfNeeded()
    } catch (e: Exception) {
      Log.w(TAG, "Failed to save episode to memory", e)
    }
  }

  /** Save a repair record to memory. */
  private suspend fun saveRepairToMemory(
    step: PlanStep,
    error: String,
    diagnostic: DiagnosticResult,
    success: Boolean,
  ) {
    try {
      memoryRepository?.saveRepair(
        RepairRecord(
          id = UUID.randomUUID().toString(),
          skillName = step.skillName ?: "unknown",
          errorSummary = error.take(200),
          fixType = diagnostic.fixType,
          fixDescription = diagnostic.diagnosis,
          alternativeSkill = diagnostic.alternativeSkillName,
          alternativeArgs = diagnostic.alternativeArgs,
          success = success,
        )
      )
    } catch (e: Exception) {
      Log.w(TAG, "Failed to save repair to memory", e)
    }
  }

  /** Save a device fact to memory, ignoring failures. */
  private suspend fun saveDeviceFactSafe(key: String, value: String) {
    try {
      memoryRepository?.saveDeviceFact(key, value)
    } catch (e: Exception) {
      Log.w(TAG, "Failed to save device fact to memory", e)
    }
  }
}
