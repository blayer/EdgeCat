/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

package com.mobileclaw.app.eval

import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.mobileclaw.app.customtasks.agentchat.AgentTools
import com.mobileclaw.app.customtasks.agentchat.LlmInferenceProviderImpl
import com.mobileclaw.app.customtasks.agentchat.SkillManagerViewModel
import com.mobileclaw.app.customtasks.agentchat.ToolExecutorImpl
import com.mobileclaw.app.customtasks.common.CustomTask
import com.mobileclaw.app.data.DataStoreRepository
import com.mobileclaw.app.data.Model
import com.mobileclaw.app.data.ModelDownloadStatusType
import com.mobileclaw.app.data.Task
import com.mobileclaw.app.memory.InMemoryMemoryRepository
import com.mobileclaw.app.orchestration.OrchestrationController
import com.mobileclaw.app.orchestration.OrchestrationStatus
import com.mobileclaw.app.orchestration.ThinkingMode
import com.mobileclaw.app.orchestration.TraceRecorder
import com.mobileclaw.app.ui.llmchat.LlmChatViewModel
import com.mobileclaw.app.ui.modelmanager.ModelInitializationStatusType
import com.mobileclaw.app.ui.modelmanager.ModelManagerViewModel
import kotlinx.coroutines.delay
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.AndroidEntryPoint
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import java.io.File
import java.util.UUID

private const val TAG = "AGEvalActivity"
private const val ACTION_RUN = "com.mobileclaw.app.EVAL_RUN"
private const val EXTRA_PROMPT = "prompt"
private const val EXTRA_RUN_ID = "run_id"
private const val TRACE_DIR = "/sdcard/claw-traces"

/**
 * Hidden, intent-driven entry point for UI-free orchestration evaluation.
 *
 * Guarded by a custom action filter — no MAIN/LAUNCHER entry, so it never shows up in the app
 * drawer. Started via:
 *
 *   adb shell am start \
 *     -a com.mobileclaw.app.EVAL_RUN \
 *     -n com.mobileclaw.app/.eval.EvalActivity \
 *     --es prompt "What is 2+2?" \
 *     --es run_id aw-calc-001
 *
 * The activity:
 *   - Reads the selected model from the shared Task singletons (must be loaded in main UI first).
 *   - Refuses to run if no model has been initialized (writes a failure trace and exits).
 *     No hardcoded fallback — production config only.
 *   - Runs the full orchestrator loop with an isolated InMemoryMemoryRepository, writes the trace
 *     to /sdcard/claw-traces/<run_id>.jsonl, and finishes.
 *
 * No Conversation row is written to the chat DB — eval messages would otherwise leak into the
 * main app's conversation history if cleanup was skipped (activity killed mid-run, am force-stop
 * between tasks, etc.). The orchestrator doesn't need DB-backed persistence; memory is isolated
 * via InMemoryMemoryRepository, and the trace file is the record of truth.
 */
@AndroidEntryPoint
class EvalActivity : ComponentActivity() {

  @EntryPoint
  @InstallIn(SingletonComponent::class)
  interface Deps {
    fun dataStoreRepository(): DataStoreRepository
    fun customTasks(): Set<@JvmSuppressWildcards CustomTask>
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    val action = intent?.action
    if (action != ACTION_RUN) {
      Log.w(TAG, "EvalActivity started with wrong action: $action; finishing")
      finish()
      return
    }

    val prompt = intent?.getStringExtra(EXTRA_PROMPT)
    val runId = intent?.getStringExtra(EXTRA_RUN_ID) ?: UUID.randomUUID().toString()
    if (prompt.isNullOrBlank()) {
      writeFailureTrace(runId, prompt = "", reason = "missing_prompt_extra")
      Log.e(TAG, "Missing --es prompt; exiting")
      finish()
      return
    }

    Log.d(TAG, "Eval run starting: runId=$runId, prompt='${prompt.take(80)}'")
    setContent { EvalRunner(prompt = prompt, runId = runId, onComplete = { finish() }) }
  }

  private fun writeFailureTrace(runId: String, prompt: String, reason: String) {
    try {
      val dir = File(TRACE_DIR).apply { mkdirs() }
      val tr = TraceRecorder.forRunId(applicationContext, runId)
      tr.flush(
        userMessage = prompt,
        finalStatus = "error",
        finalOutput = null,
        plan = null,
        stepResults = null,
        evaluation = null,
        iteration = 0,
        extras = mapOf(
          "eval_failure_reason" to reason,
          "device_model" to Build.MODEL,
          "device_sdk" to Build.VERSION.SDK_INT,
        ),
      )
      Log.e(TAG, "Wrote failure trace to $dir/$runId.jsonl: $reason")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to write failure trace", e)
    }
  }
}

@Composable
private fun EvalRunner(
  prompt: String,
  runId: String,
  onComplete: () -> Unit,
) {
  val context = LocalContext.current
  val chatVm: LlmChatViewModel = hiltViewModel()
  val skillVm: SkillManagerViewModel = hiltViewModel()
  val mmVm: ModelManagerViewModel = hiltViewModel()

  LaunchedEffect(runId) {
    val deps = EntryPointAccessors.fromApplication(context, EvalActivity.Deps::class.java)
    val dataStoreRepo = deps.dataStoreRepository()
    // IMPORTANT: use the same CustomTask instances ModelManagerViewModel works on.
    // Hilt's @IntoSet provider is unscoped, so accessing via a separate EntryPoint returns
    // DIFFERENT instances — and loadModelAllowlist() populates models on MMVM's copy only.
    val customTasks = mmVm.getActiveCustomTasks().toSet()

    // Rule #7: eval must reflect production config; no hardcoded Gemma 2B fallback.
    // We still auto-initialize a model here, but only one that the user has already downloaded.
    // If nothing is downloaded, fail fast — we do NOT pull anything.

    // Load the model allowlist if the main app hasn't run yet. The allowlist hydrates
    // task.models and the download-status map — without it, EvalActivity has no models to look at.
    if (mmVm.uiState.value.tasks.isEmpty()) {
      Log.d(TAG, "Allowlist not loaded yet; calling loadModelAllowlist()")
      mmVm.loadModelAllowlist()
      val allowlistDeadline = System.currentTimeMillis() + 30_000L
      while (System.currentTimeMillis() < allowlistDeadline &&
        mmVm.uiState.value.modelDownloadStatus.isEmpty()) {
        delay(500)
      }
    }

    val liveModel: Model? = customTasks
      .flatMap { it.task.models }
      .firstOrNull { it.instance != null }

    val loadedModel: Model = if (liveModel != null) {
      Log.d(TAG, "Using already-live model: ${liveModel.name}")
      liveModel
    } else {
      val pair = findDownloadedModel(context, mmVm, customTasks)
      if (pair == null) {
        Log.e(TAG, "No downloaded model found; failing fast per eval rule #7")
        writeFlushFailure(
          context = context,
          runId = runId,
          prompt = prompt,
          reason = "no_model_loaded",
        )
        onComplete()
        return@LaunchedEffect
      }
      val (task, model) = pair
      Log.d(TAG, "Auto-initializing downloaded model for eval: ${model.name} (task=${task.id})")
      // AgentChatTask.initializeModelFn touches agentTools.skillManagerViewModel, which is
      // a lateinit normally populated by AgentChatScreen's composable. No screen here — inject
      // it ourselves against the same CustomTask instance MMVM holds.
      val agentChat = customTasks.firstOrNull { it.task.id == "llm_agent_chat" }
        as? com.mobileclaw.app.customtasks.agentchat.AgentChatTask
      if (agentChat != null) {
        agentChat.agentTools.context = context
        agentChat.agentTools.skillManagerViewModel = skillVm
      }
      mmVm.initializeModel(context = context, task = task, model = model)
      // Poll until INITIALIZED or ERROR — cap at 90s.
      val deadlineMs = System.currentTimeMillis() + 90_000L
      while (System.currentTimeMillis() < deadlineMs) {
        val st = mmVm.uiState.value.modelInitializationStatus[model.name]?.status
        if (st == ModelInitializationStatusType.INITIALIZED && model.instance != null) break
        if (st == ModelInitializationStatusType.ERROR) break
        delay(500)
      }
      if (model.instance == null) {
        val err = mmVm.uiState.value.modelInitializationStatus[model.name]?.error ?: "init_timeout"
        Log.e(TAG, "Model init failed for ${model.name}: $err")
        writeFlushFailure(
          context = context,
          runId = runId,
          prompt = prompt,
          reason = "model_init_failed:$err",
        )
        onComplete()
        return@LaunchedEffect
      }
      Log.d(TAG, "Model initialized: ${model.name}")
      model
    }

    // Intentionally no Conversation row: leaving chatVm.currentConversationId null makes
    // persistUserMessage / persistAssistantMessage early-return, so eval runs never write to the
    // chat DB and cannot leak into the main app's history list.
    val trace = TraceRecorder.forRunId(context, runId)
    val memory = InMemoryMemoryRepository()
    val agentTools = AgentTools().apply {
      this.context = context
      this.skillManagerViewModel = skillVm
    }
    val llmProvider = LlmInferenceProviderImpl(chatVm) { loadedModel }
    val toolExec = ToolExecutorImpl(agentTools, skillVm)

    val controller = OrchestrationController(
      llmProvider = llmProvider,
      toolExecutor = toolExec,
      memoryRepository = memory,
      maxIterations = dataStoreRepo.getAgentMaxLoops(),
      maxRepairAttempts = dataStoreRepo.getAgentMaxRepairAttempts(),
      thinkingMode = ThinkingMode.fromInt(dataStoreRepo.getAgentThinkingMode()),
      userPortraitProvider = { dataStoreRepo.getUserPortrait() },
      trace = trace,
    )

    try {
      controller.run(prompt)
    } catch (e: Exception) {
      Log.e(TAG, "controller.run threw", e)
    }

    val finalState = controller.state.value
    val terminalStatus = when (finalState.status) {
      OrchestrationStatus.COMPLETED -> "ok"
      OrchestrationStatus.CANCELLED -> "cancelled"
      OrchestrationStatus.ERROR -> "error"
      else -> "incomplete"
    }
    trace.flush(
      userMessage = prompt,
      finalStatus = terminalStatus,
      finalOutput = finalState.finalOutput,
      plan = finalState.plan,
      stepResults = finalState.stepResults.takeIf { it.isNotEmpty() },
      evaluation = finalState.evaluation,
      iteration = finalState.iteration,
      extras = mapOf(
        "model_name" to loadedModel.name,
        "thinking_mode" to dataStoreRepo.getAgentThinkingMode(),
        "device_model" to Build.MODEL,
        "device_sdk" to Build.VERSION.SDK_INT,
        "memory_isolated" to true,
      ),
    )
    Log.d(TAG, "Flushed trace for runId=$runId, status=$terminalStatus")

    memory.clearAll()
    onComplete()
  }

  Box(modifier = Modifier.fillMaxSize().padding(16.dp), contentAlignment = Alignment.Center) {
    Text("Running eval run_id=$runId\n${prompt.take(120)}")
  }
}

/** Find the first (task, model) pair whose model file is already downloaded.
 *  Prefers the AgentChat task since that is the production path for orchestration.
 *  Falls back to a direct File.exists() check on the model's expected path, because
 *  `adb push` writes bypass the app's download bookkeeping so the status map
 *  stays NOT_DOWNLOADED even when the file is present. */
private fun findDownloadedModel(
  context: android.content.Context,
  mmVm: ModelManagerViewModel,
  customTasks: Set<CustomTask>,
): Pair<Task, Model>? {
  val status = mmVm.uiState.value.modelDownloadStatus
  Log.d(TAG, "findDownloadedModel: status keys=${status.keys}")
  val orderedTasks = customTasks.map { it.task }.sortedBy {
    if (it.id == "llm_agent_chat") 0 else 1
  }
  for (task in orderedTasks) {
    Log.d(TAG, "  task=${task.id} models=${task.models.map { it.name }}")
    for (model in task.models) {
      val s = status[model.name]?.status
      if (s == ModelDownloadStatusType.SUCCEEDED) {
        return task to model
      }
      val path = model.getPath(context)
      val existsAtExpected = try {
        java.io.FileInputStream(java.io.File(path)).use { it.read(); true }
      } catch (_: Exception) { false }
      if (existsAtExpected) {
        Log.d(TAG, "    ${model.name} found at expected path $path")
        return task to model
      }
      // Fallback: eval harness pushes the model to a shell-writable, app-readable path.
      // Samsung's scoped-storage FUSE hides shell-pushed files inside the app's external
      // files dir, but /data/local/tmp is visible to the app.
      val sideloadPath = "/data/local/tmp/${model.downloadFileName}"
      val sideloadOk = try {
        java.io.FileInputStream(java.io.File(sideloadPath)).use { it.read(); true }
      } catch (_: Exception) { false }
      Log.d(TAG, "    ${model.name} primary=$existsAtExpected sideload=$sideloadOk sideloadPath=$sideloadPath")
      if (sideloadOk) {
        model.localModelFilePathOverride = sideloadPath
        return task to model
      }
    }
  }
  return null
}

private fun writeFlushFailure(
  context: android.content.Context,
  runId: String,
  prompt: String,
  reason: String,
) {
  val tr = TraceRecorder.forRunId(context, runId)
  tr.flush(
    userMessage = prompt,
    finalStatus = "error",
    finalOutput = null,
    plan = null,
    stepResults = null,
    evaluation = null,
    iteration = 0,
    extras = mapOf(
      "eval_failure_reason" to reason,
      "device_model" to Build.MODEL,
      "device_sdk" to Build.VERSION.SDK_INT,
    ),
  )
}
