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

/** A single step in an execution plan. */
data class PlanStep(
  val id: String,
  val description: String,
  val skillName: String? = null,
  val toolName: String? = null,
  val toolArgs: Map<String, String> = emptyMap(),
  val dependsOn: List<String> = emptyList(),
)

/** A structured execution plan produced by the Planner. */
data class ExecutionPlan(
  val goal: String,
  val reasoning: String,
  val steps: List<PlanStep>,
  /**
   * Concrete outcomes the user would call "success" — used by the evaluator as a rubric.
   * Empty means the evaluator will fall back to the old holistic check.
   */
  val successCriteria: List<String> = emptyList(),
)

/** Status of a single plan step during execution. */
enum class StepStatus {
  PENDING,
  RUNNING,
  COMPLETED,
  FAILED,
  SKIPPED,
}

/** Result of executing a single plan step. */
data class StepResult(
  val stepId: String,
  val status: StepStatus,
  val output: String = "",
  val error: String? = null,
  val durationMs: Long = 0,
)

/** Overall status of the orchestration loop. */
enum class OrchestrationStatus {
  IDLE,
  PLANNING,
  EXECUTING,
  EVALUATING,
  REPAIRING,
  REPLANNING,
  FORMATTING,
  COMPLETED,
  CANCELLED,
  ERROR,
}

/** Full state of an orchestration run, exposed via StateFlow. */
data class OrchestrationState(
  val status: OrchestrationStatus = OrchestrationStatus.IDLE,
  val plan: ExecutionPlan? = null,
  val stepResults: Map<String, StepResult> = emptyMap(),
  val evaluation: EvaluationResult? = null,
  val iteration: Int = 0,
  val maxIterations: Int = 3,
  val finalOutput: String? = null,
  val finalOutputIsHtml: Boolean = false,
  val error: String? = null,
  val memoryRecalled: Boolean? = null,
  /** Whether thinking/CoT was enabled for each LLM phase during this run. */
  val thinkingByPhase: Map<String, Boolean> = emptyMap(),
)

/** Result of the self-evaluation module. */
data class EvaluationResult(
  val goalAchieved: Boolean,
  val assessment: String,
  val missingItems: List<String> = emptyList(),
  val shouldReplan: Boolean = false,
  /** Criteria the rubric check marked as failed (when rubric was used). */
  val failedCriteria: List<String> = emptyList(),
)

/** Lightweight skill descriptor for planning prompts. */
data class SkillSummary(
  val name: String,
  val description: String,
  val instructions: String = "",
  /** "base" = always in planner catalog. "deferred" = name-only until search-skills loads it. */
  val tier: String = "base",
)

/** Result of diagnosing a failed skill step. */
data class DiagnosticResult(
  val diagnosis: String,
  val fixType: String, // "retry_with_different_args", "use_alternative_skill", "skip", "unfixable"
  val alternativeSkillName: String? = null,
  val alternativeArgs: Map<String, String> = emptyMap(),
  val updatedInstructions: String? = null,
)
