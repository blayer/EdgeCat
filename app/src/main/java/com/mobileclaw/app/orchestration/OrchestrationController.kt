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
  private val maxIterations: Int = 3,
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
      // ---- Phase 1: Plan ----
      Log.d(TAG, "Phase 1: Planning for: $userMessage")
      val skills = toolExecutor.getAvailableSkills()
      val planPrompt = planner.buildPlanningPrompt(userMessage, skills)
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

        _state.value = _state.value.copy(stepResults = results)

        if (cancelled.get()) {
          _state.value = _state.value.copy(status = OrchestrationStatus.CANCELLED)
          return
        }

        // Evaluate.
        Log.d(TAG, "Iteration $iteration: Evaluating results")
        _state.value = _state.value.copy(status = OrchestrationStatus.EVALUATING)

        val evalPrompt = evaluator.buildEvaluationPrompt(userMessage, currentPlan, results)
        val evalResponse = llmProvider.generateResponse(evalPrompt)
        val evaluation = evaluator.parseEvaluation(evalResponse)

        Log.d(TAG, "Evaluation: goalAchieved=${evaluation.goalAchieved}, shouldReplan=${evaluation.shouldReplan}")
        _state.value = _state.value.copy(evaluation = evaluation)

        if (evaluation.goalAchieved) {
          Log.d(TAG, "Goal achieved on iteration $iteration")
          _state.value = _state.value.copy(status = OrchestrationStatus.FORMATTING)
          val (finalOutput, isHtml) = buildFinalOutput(userMessage, currentPlan, results, evaluation)
          _state.value =
            _state.value.copy(
              status = OrchestrationStatus.COMPLETED,
              finalOutput = finalOutput,
              finalOutputIsHtml = isHtml,
            )
          return
        }

        if (!evaluation.shouldReplan || iteration == maxIterations) {
          Log.d(TAG, "Stopping: shouldReplan=${evaluation.shouldReplan}, iteration=$iteration/$maxIterations")
          _state.value = _state.value.copy(status = OrchestrationStatus.FORMATTING)
          val (finalOutput, isHtml) = buildFinalOutput(userMessage, currentPlan, results, evaluation)
          _state.value =
            _state.value.copy(
              status = OrchestrationStatus.COMPLETED,
              finalOutput = finalOutput,
              finalOutputIsHtml = isHtml,
            )
          return
        }

        // Repair: diagnose failed steps before replanning.
        if (cancelled.get()) {
          _state.value = _state.value.copy(status = OrchestrationStatus.CANCELLED)
          return
        }

        val failedSteps = currentPlan.steps.filter { step ->
          results[step.id]?.status == StepStatus.FAILED
        }

        var diagnosticNotes = ""
        if (failedSteps.isNotEmpty()) {
          Log.d(TAG, "Diagnosing ${failedSteps.size} failed steps")
          _state.value = _state.value.copy(status = OrchestrationStatus.REPAIRING)

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

              Log.d(TAG, "Diagnostic for ${failedStep.id}: type=${diagnostic.fixType}, diagnosis=${diagnostic.diagnosis}")

              diagnosticNotes += "\n\nDiagnostic for failed step '${failedStep.id}' (${failedStep.skillName}):"
              diagnosticNotes += "\n- Diagnosis: ${diagnostic.diagnosis}"
              when (diagnostic.fixType) {
                "use_alternative_skill" -> {
                  diagnosticNotes += "\n- Suggested fix: Use skill '${diagnostic.alternativeSkillName}' instead"
                  if (diagnostic.alternativeArgs.isNotEmpty()) {
                    diagnosticNotes += " with args: ${diagnostic.alternativeArgs}"
                  }
                }
                "retry_with_different_args" -> {
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
              Log.w(TAG, "Failed to diagnose step ${failedStep.id}", e)
            }
          }
        }

        // Replan with diagnostic notes.
        Log.d(TAG, "Re-planning for iteration ${iteration + 1}")
        _state.value = _state.value.copy(status = OrchestrationStatus.REPLANNING)

        val replanPrompt =
          planner.buildReplanPrompt(userMessage, currentPlan, results, evaluation, skills)
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

  /** Build a summary of the final output from all step results. Returns (output, isHtml). */
  private suspend fun buildFinalOutput(
    userMessage: String,
    plan: ExecutionPlan,
    results: Map<String, StepResult>,
    evaluation: EvaluationResult,
  ): Pair<String, Boolean> {
    // Collect all completed step outputs.
    val completedOutputs = plan.steps
      .mapNotNull { step -> results[step.id]?.takeIf { it.status == StepStatus.COMPLETED && it.output.isNotBlank() } }

    if (completedOutputs.isEmpty()) {
      return "No output produced." to false
    }

    // Use the last completed output as the primary raw data.
    val rawOutput = completedOutputs.last().output.take(2000)

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
}
