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
) {
  private val planner = Planner()
  private val orchestrator = ExecutionOrchestrator(llmProvider, toolExecutor)
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
      if (memoryContext.isNotEmpty()) {
        Log.d(TAG, "Memory context (${memoryContext.length} chars): ${memoryContext.take(200)}...")
      }

      // ---- Phase 1: Plan ----
      Log.d(TAG, "Phase 1: Planning for: $userMessage")
      val skills = toolExecutor.getAvailableSkills()
      val planPrompt = planner.buildPlanningPrompt(userMessage, skills, memoryContext)
      val planResponse = llmProvider.generateResponse(planPrompt)
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

        // Repair: attempt to fix and retry failed skill steps before evaluation.
        val repairedResults = repairFailedSteps(currentPlan, results, skills)

        _state.value = _state.value.copy(stepResults = repairedResults)

        if (cancelled.get()) {
          _state.value = _state.value.copy(status = OrchestrationStatus.CANCELLED)
          return
        }

        // Evaluate.
        Log.d(TAG, "Iteration $iteration: Evaluating results")
        _state.value = _state.value.copy(status = OrchestrationStatus.EVALUATING)

        val evalPrompt = evaluator.buildEvaluationPrompt(userMessage, currentPlan, repairedResults)
        val evalResponse = llmProvider.generateResponse(evalPrompt)
        val evaluation = evaluator.parseEvaluation(evalResponse)

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
        val diagnosticNotes = buildDiagnosticNotesForReplan(stillFailedSteps, repairedResults, skills)

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
        val replanResponse = llmProvider.generateResponse(fullReplanPrompt)
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
   * Attempt to repair and retry failed skill steps.
   *
   * For each failed step, diagnoses the failure via LLM, applies the fix (update instructions,
   * adjust args), and retries. Returns the updated results map with repaired steps.
   */
  private suspend fun repairFailedSteps(
    plan: ExecutionPlan,
    results: Map<String, StepResult>,
    skills: List<SkillSummary>,
  ): Map<String, StepResult> {
    val failedSteps = plan.steps.filter { step ->
      results[step.id]?.status == StepStatus.FAILED && step.skillName != null
    }

    if (failedSteps.isEmpty()) return results

    Log.d(TAG, "Attempting repair for ${failedSteps.size} failed skill steps")
    val repairedResults = results.toMutableMap()

    for (failedStep in failedSteps) {
      if (cancelled.get()) break

      val repaired = attemptRepairAndRetry(failedStep, repairedResults, skills)
      repairedResults[failedStep.id] = repaired
    }

    return repairedResults
  }

  /**
   * Diagnose a failed step, apply fix, and retry up to [maxRepairAttempts] times.
   */
  private suspend fun attemptRepairAndRetry(
    step: PlanStep,
    allResults: Map<String, StepResult>,
    skills: List<SkillSummary>,
  ): StepResult {
    var currentResult = allResults[step.id] ?: return StepResult(
      stepId = step.id, status = StepStatus.FAILED, error = "No result found",
    )

    val skillSummary = skills.find { it.name == step.skillName }

    for (attempt in 1..maxRepairAttempts) {
      if (cancelled.get()) break

      Log.d(TAG, "Repair attempt $attempt/$maxRepairAttempts for step ${step.id} (${step.skillName})")
      _state.value = _state.value.copy(status = OrchestrationStatus.REPAIRING)

      // 1. Diagnose.
      val error = currentResult.error ?: currentResult.output
      val skillInstructions = skillSummary?.instructions ?: ""

      // Recall past repairs for this skill from memory
      val pastRepairsStr = try {
        val pastRepairs = memoryRepository?.recallRepairs(step.skillName ?: "", error)
        pastRepairs?.joinToString("\n") { r ->
          val successStr = if (r.success) "worked" else "did not work"
          "- ${r.fixType}: ${r.fixDescription} ($successStr)"
        } ?: ""
      } catch (e: Exception) { "" }

      val diagnostic: DiagnosticResult
      try {
        val diagPrompt = skillCreator.buildDiagnosticPrompt(
          failedStep = step,
          error = error,
          deviceInfo = getDeviceInfo(),
          skillInstructions = skillInstructions,
          pastRepairs = pastRepairsStr,
        )
        val diagResponse = llmProvider.generateResponse(diagPrompt)
        diagnostic = skillCreator.parseDiagnostic(diagResponse)
        Log.d(TAG, "Diagnosis: fixType=${diagnostic.fixType}, diagnosis=${diagnostic.diagnosis}")
      } catch (e: Exception) {
        Log.w(TAG, "Failed to diagnose step ${step.id}", e)
        break
      }

      // 2. Apply fix based on type.
      var retryStep = step
      when (diagnostic.fixType) {
        "retry_with_different_args" -> {
          if (diagnostic.alternativeArgs.isNotEmpty()) {
            retryStep = step.copy(toolArgs = step.toolArgs + diagnostic.alternativeArgs)
            Log.d(TAG, "Retrying with adjusted args: ${retryStep.toolArgs}")
          }
        }
        "update_instructions" -> {
          val newInstructions = diagnostic.updatedInstructions
          if (newInstructions != null && step.skillName != null) {
            val updated = toolExecutor.updateSkillInstructions(step.skillName, newInstructions)
            if (updated) {
              Log.d(TAG, "Updated instructions for skill '${step.skillName}'")
            } else {
              Log.w(TAG, "Could not update skill '${step.skillName}' (built-in or not found)")
            }
          }
          // Also apply arg changes if provided.
          if (diagnostic.alternativeArgs.isNotEmpty()) {
            retryStep = step.copy(toolArgs = step.toolArgs + diagnostic.alternativeArgs)
          }
        }
        "use_alternative_skill" -> {
          // Save device fact about skill swap for future runs
          if (step.skillName != null && diagnostic.alternativeSkillName != null) {
            saveDeviceFactSafe(
              "alt_skill_${step.skillName}",
              "Skill '${step.skillName}' does not work on this device; use '${diagnostic.alternativeSkillName}' instead",
            )
          }
          saveRepairToMemory(step, error, diagnostic, false)
          Log.d(TAG, "Fix type '${diagnostic.fixType}' not retriable, skipping repair")
          break
        }
        "unfixable", "skip" -> {
          saveRepairToMemory(step, error, diagnostic, false)
          Log.d(TAG, "Fix type '${diagnostic.fixType}' not retriable, skipping repair")
          break
        }
      }

      // 3. Retry the step.
      _state.value = _state.value.copy(status = OrchestrationStatus.EXECUTING)
      try {
        val retryPlan = ExecutionPlan(
          goal = "repair retry",
          reasoning = "Retrying step ${step.id} after repair attempt $attempt",
          steps = listOf(retryStep),
        )
        val retryBatches = listOf(listOf(retryStep))
        val retryResults = orchestrator.executePlan(retryPlan, retryBatches) { stepResult ->
          _state.value = _state.value.copy(
            stepResults = _state.value.stepResults + (stepResult.stepId to stepResult),
          )
        }

        val retryResult = retryResults[step.id]
        if (retryResult != null && retryResult.status == StepStatus.COMPLETED) {
          Log.d(TAG, "Repair succeeded for step ${step.id} on attempt $attempt")
          saveRepairToMemory(step, error, diagnostic, true)
          return retryResult
        }
        if (retryResult != null) {
          currentResult = retryResult
        }
        saveRepairToMemory(step, error, diagnostic, false)
        Log.d(TAG, "Repair attempt $attempt failed for step ${step.id}: ${currentResult.error}")
      } catch (e: Exception) {
        Log.w(TAG, "Repair retry execution failed for step ${step.id}", e)
        break
      }
    }

    return currentResult
  }

  /**
   * Build diagnostic notes string for steps that are still failed after repair attempts.
   * These notes are injected into the replan prompt as context.
   */
  private suspend fun buildDiagnosticNotesForReplan(
    failedSteps: List<PlanStep>,
    results: Map<String, StepResult>,
    skills: List<SkillSummary>,
  ): String {
    if (failedSteps.isEmpty()) return ""

    var diagnosticNotes = ""
    for (failedStep in failedSteps) {
      val stepResult = results[failedStep.id] ?: continue
      val error = stepResult.error ?: stepResult.output
      val skillInstructions = failedStep.skillName?.let { name ->
        skills.find { it.name == name }?.instructions ?: ""
      } ?: ""

      try {
        val diagPrompt = skillCreator.buildDiagnosticPrompt(
          failedStep = failedStep,
          error = error,
          deviceInfo = getDeviceInfo(),
          skillInstructions = skillInstructions,
        )
        val diagResponse = llmProvider.generateResponse(diagPrompt)
        val diagnostic = skillCreator.parseDiagnostic(diagResponse)

        diagnosticNotes += "\n\nDiagnostic for failed step '${failedStep.id}' (${failedStep.skillName}):"
        diagnosticNotes += "\n- Diagnosis: ${diagnostic.diagnosis}"
        when (diagnostic.fixType) {
          "use_alternative_skill" -> {
            diagnosticNotes += "\n- Suggested fix: Use skill '${diagnostic.alternativeSkillName}' instead"
            if (diagnostic.alternativeArgs.isNotEmpty()) {
              diagnosticNotes += " with args: ${diagnostic.alternativeArgs}"
            }
          }
          "retry_with_different_args", "update_instructions" -> {
            diagnosticNotes += "\n- Suggested fix: Retry with different args: ${diagnostic.alternativeArgs}"
          }
          "skip" -> {
            diagnosticNotes += "\n- Suggested fix: Skip this step, it is not needed"
          }
          else -> {
            diagnosticNotes += "\n- This step cannot be fixed automatically"
          }
        }
      } catch (e: Exception) {
        Log.w(TAG, "Failed to diagnose step ${failedStep.id} for replan", e)
      }
    }
    return diagnosticNotes
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
You are a helpful assistant. The user asked: "$userMessage"

The system executed tools and produced this raw result:
$rawOutput

Rewrite this into a clear, friendly response for the user. Follow these rules:
- For simple values (e.g. a number, a short answer), write a brief natural sentence.
- For lists of items (e.g. apps, contacts, files), use a clean markdown table or bullet list.
- For device info or status data, summarize the key details in a readable way.
- For search results, present them as a numbered list with titles and brief descriptions.
- For errors or failures, explain what went wrong simply.
- Do NOT include raw JSON, map syntax like {key=value}, or technical formatting.
- Do NOT add disclaimers, caveats, or extra commentary. Just present the result clearly.
- Keep it concise. No preamble like "Here is..." or "Based on...".
""".trimIndent()

    Log.d(TAG, "Formatting result with LLM, raw output length=${rawOutput.length}")
    val response = llmProvider.generateResponse(prompt)
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
