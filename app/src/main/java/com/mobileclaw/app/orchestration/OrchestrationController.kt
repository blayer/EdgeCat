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
) {
  private val thinkingPolicy = ThinkingPolicy(thinkingMode)
  private val planner = Planner()
  private val orchestrator = ExecutionOrchestrator(llmProvider, toolExecutor, thinkingPolicy)
  private val evaluator = SelfEvaluator()
  private val skillCreator = SkillCreator()

  private val _state = MutableStateFlow(OrchestrationState())
  val state: StateFlow<OrchestrationState> = _state.asStateFlow()

  private val cancelled = AtomicBoolean(false)

  /**
   * Main entry point: plan → execute → evaluate → loop.
   *
   * This is a suspending function that runs the full orchestration loop. It updates [state] at each
   * phase so the UI can react.
   */
  suspend fun run(userMessage: String) {
    cancelled.set(false)
    _state.value =
      OrchestrationState(
        status = OrchestrationStatus.PLANNING,
        maxIterations = maxIterations,
      )

    try {
      // ---- Phase 0: Recall memory ----
      val memoryContext = try {
        memoryRepository?.recallForPlanning(userMessage) ?: ""
      } catch (e: Exception) {
        Log.w(TAG, "Memory recall failed, continuing without memory", e)
        ""
      }
      val memoryFound = memoryContext.isNotEmpty()
      _state.value = _state.value.copy(memoryRecalled = memoryFound)
      if (memoryFound) {
        Log.d(TAG, "Memory context (${memoryContext.length} chars): ${memoryContext.take(200)}...")
      } else {
        Log.d(TAG, "No memory found for: $userMessage")
      }

      // ---- Phase 1: Plan ----
      Log.d(TAG, "Phase 1: Planning for: $userMessage")
      val skills = toolExecutor.getAvailableSkills()
      val planPrompt = planner.buildPlanningPrompt(userMessage, skills, memoryContext)
      val planResponse = llmProvider.generateResponse(
        planPrompt,
        enableThinking = thinkingPolicy.planner(userMessage, iteration = 0),
      )
      val plan = planner.parsePlan(planResponse, userMessage)

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
        val results =
          orchestrator.executePlan(currentPlan, batches) { stepResult ->
            // Update state as each step completes.
            _state.value =
              _state.value.copy(
                stepResults = _state.value.stepResults + (stepResult.stepId to stepResult)
              )
          }

        val repairedResults = results
        _state.value = _state.value.copy(stepResults = repairedResults)

        if (cancelled.get()) {
          _state.value = _state.value.copy(status = OrchestrationStatus.CANCELLED)
          return
        }

        // Evaluate — skip LLM call when the happy path is obvious (all steps COMPLETED,
        // no error signals in output). Saves one LLM call per successful turn.
        Log.d(TAG, "Iteration $iteration: Evaluating results")
        _state.value = _state.value.copy(status = OrchestrationStatus.EVALUATING)

        val evaluation = if (canShortCircuitEval(currentPlan, repairedResults)) {
          Log.d(TAG, "Short-circuit eval: all steps completed cleanly")
          EvaluationResult(goalAchieved = true, assessment = "All steps completed", missingItems = emptyList(), shouldReplan = false)
        } else {
          val evalPrompt = evaluator.buildEvaluationPrompt(userMessage, currentPlan, repairedResults)
          val evalResponse = llmProvider.generateResponse(
            evalPrompt,
            enableThinking = thinkingPolicy.evaluator(),
          )
          val combinedOutputs = repairedResults.values.joinToString("\n") { it.output }
          evaluator.parseEvaluation(evalResponse, combinedOutputs)
        }

        Log.d(TAG, "Evaluation: goalAchieved=${evaluation.goalAchieved}, shouldReplan=${evaluation.shouldReplan}")
        _state.value = _state.value.copy(evaluation = evaluation)

        if (evaluation.goalAchieved) {
          Log.d(TAG, "Goal achieved on iteration $iteration")
          _state.value = _state.value.copy(status = OrchestrationStatus.FORMATTING)
          val (finalOutput, isHtml) = buildFinalOutput(userMessage, currentPlan, repairedResults, evaluation)
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
          val (finalOutput, isHtml) = buildFinalOutput(userMessage, currentPlan, repairedResults, evaluation)
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
        _state.value = _state.value.copy(status = OrchestrationStatus.REPLANNING)

        val replanPrompt =
          planner.buildReplanPrompt(userMessage, currentPlan, repairedResults, evaluation, skills, memoryContext)
        val fullReplanPrompt = if (diagnosticNotes.isNotEmpty()) {
          "$replanPrompt\n\nAuto-diagnostic notes (use these to fix the plan):$diagnosticNotes"
        } else {
          replanPrompt
        }
        val replanResponse = llmProvider.generateResponse(
          fullReplanPrompt,
          enableThinking = thinkingPolicy.replan(replanAttempt = iteration),
        )
        currentPlan = planner.parsePlan(replanResponse, userMessage)

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
   * Decide whether evaluation can be skipped. Returns true iff every planned step produced a
   * COMPLETED result with non-empty output and no obvious error markers. Research across
   * Claude/Gemini/OpenAI agent patterns recommends skipping eval when the tool output is
   * self-describing — it cuts one LLM call per turn on the happy path.
   */
  private fun canShortCircuitEval(plan: ExecutionPlan, results: Map<String, StepResult>): Boolean {
    if (plan.steps.isEmpty()) return false
    val errorMarkers = Regex(
      """(?i)(\b(failed|error|exception|denied|unauthorized|not\s+found|invalid)\b""" +
        """|\bi\s+(?:cannot|can'?t|don'?t\s+have|am\s+unable)\b""" +
        """|\bnot\s+possible\b|\bunable\s+to\b|\bno\s+access\b)"""
    )
    for (step in plan.steps) {
      val r = results[step.id] ?: return false
      if (r.status != StepStatus.COMPLETED) return false
      if (r.output.isBlank()) return false
      if (errorMarkers.containsMatchIn(r.output)) return false
    }
    return true
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
    val rawOutput = if (completedSteps.size == 1) {
      completedSteps.first().second.output.take(2000)
    } else {
      completedSteps.joinToString("\n\n") { (step, result) ->
        "Step: ${step.description}\nResult: ${result.output.take(800)}"
      }.take(2000)
    }

    // If the output is HTML, return as-is.
    val isHtml = rawOutput.contains("<") && rawOutput.contains(">") && rawOutput.contains("</")
    if (isHtml) {
      return rawOutput.trim() to true
    }

    // Format raw output through LLM for a human-friendly response.
    try {
      val formatted = formatResultWithLlm(userMessage, rawOutput)
      if (formatted.isNotBlank()) {
        return formatted to false
      }
    } catch (e: Exception) {
      Log.w(TAG, "Result formatting failed, using raw output", e)
    }

    return rawOutput.trim() to false
  }

  /**
   * Use the LLM to rephrase raw tool output into a human-friendly response.
   */
  private suspend fun formatResultWithLlm(userMessage: String, rawOutput: String): String {
    val prompt = """
The user asked: "$userMessage"

Raw result from tools:
$rawOutput

Rewrite into a clear, friendly response. Rules:
- Simple values: brief natural sentence
- Lists: bullet list or table
- Search results: numbered list with titles
- Errors: explain simply
- No raw JSON, no {key=value} syntax, no preamble, no disclaimers
- Be concise and direct
""".trimIndent()

    Log.d(TAG, "Formatting result with LLM, raw output length=${rawOutput.length}")
    val response = llmProvider.generateResponse(
      prompt,
      enableThinking = thinkingPolicy.format(),
    )
    Log.d(TAG, "Formatted result length=${response.length}")
    return response.trim()
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
