/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

package com.mobileclaw.app.orchestration

import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.util.Log
import java.io.File
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

private const val TAG = "AGTraceRecorder"
private const val FLAG_FILE = "claw-trace-enabled"
private const val TRACE_DIR = "claw-traces"

/**
 * Per-run trace recorder for Mobile-Claw orchestration.
 *
 * Records one span per subsystem call (planner, step, evaluator, formatter) with latency,
 * thermal state, memory, and domain payload. Writes one JSONL file per run to
 * /sdcard/claw-traces/<runId>.jsonl.
 *
 * No-op unless /sdcard/claw-traces/claw-trace-enabled (or a matching file under the app's
 * external files dir) exists. This keeps production runs free of I/O cost.
 *
 * Not a library — plain Kotlin + org.json. Emits a stable schema the Python eval harness
 * parses. Thread-safe for the single-orchestration-at-a-time use case.
 */
class TraceRecorder private constructor(
  private val context: Context,
  private val outputFile: File,
  val runId: String,
) {
  private val spans = mutableListOf<JSONObject>()
  private val lock = Any()
  private val runStartNs = System.nanoTime()
  private val runStartMs = System.currentTimeMillis()

  private val powerManager: PowerManager? =
    context.getSystemService(Context.POWER_SERVICE) as? PowerManager

  /** A single span handle. Call end() to record. */
  inner class SpanHandle internal constructor(
    private val kind: String,
    private val name: String,
    private val startNs: Long,
  ) {
    private val attrs = mutableMapOf<String, Any?>()
    private var ended = false

    fun attr(key: String, value: Any?): SpanHandle {
      if (value != null) attrs[key] = value
      return this
    }

    fun end(status: String = "ok", error: String? = null) {
      if (ended) return
      ended = true
      val endNs = System.nanoTime()
      val span = JSONObject().apply {
        put("kind", kind)
        put("name", name)
        put("start_ms", (runStartMs + (startNs - runStartNs) / 1_000_000))
        put("end_ms", (runStartMs + (endNs - runStartNs) / 1_000_000))
        put("duration_ms", (endNs - startNs) / 1_000_000)
        put("status", status)
        if (error != null) put("error", error)
        put("thermal", readThermal())
        put("mem_pss_mb", readMemoryMb())
        if (attrs.isNotEmpty()) {
          put("attrs", JSONObject(attrs.mapValues { it.value ?: JSONObject.NULL }))
        }
      }
      synchronized(lock) { spans.add(span) }
    }
  }

  fun start(kind: String, name: String): SpanHandle =
    SpanHandle(kind, name, System.nanoTime())

  /** Inline helper: record a phase, return its result. */
  inline fun <T> span(kind: String, name: String, block: (SpanHandle) -> T): T {
    val h = start(kind, name)
    return try {
      val r = block(h)
      h.end(status = "ok")
      r
    } catch (t: Throwable) {
      h.end(status = "error", error = t.message)
      throw t
    }
  }

  /** Flush the accumulated spans to JSONL. Call once at end of orchestration run. */
  fun flush(
    userMessage: String,
    finalStatus: String,
    finalOutput: String?,
    plan: ExecutionPlan?,
    stepResults: Map<String, StepResult>?,
    evaluation: EvaluationResult?,
    iteration: Int,
    extras: Map<String, Any?> = emptyMap(),
  ) {
    try {
      synchronized(lock) {
        val runEndNs = System.nanoTime()
        val summary = JSONObject().apply {
          put("run_id", runId)
          put("schema_version", 1)
          put("user_message", userMessage)
          put("final_status", finalStatus)
          put("final_output", finalOutput ?: JSONObject.NULL)
          put("iteration", iteration)
          put("start_ms", runStartMs)
          put("end_ms", (runStartMs + (runEndNs - runStartNs) / 1_000_000))
          put("duration_ms", (runEndNs - runStartNs) / 1_000_000)
          put("device", JSONObject().apply {
            put("manufacturer", Build.MANUFACTURER)
            put("model", Build.MODEL)
            put("sdk", Build.VERSION.SDK_INT)
            put("release", Build.VERSION.RELEASE)
          })
          if (plan != null) put("plan", planToJson(plan))
          if (stepResults != null) put("step_results", stepResultsToJson(stepResults))
          if (evaluation != null) put("evaluation", evaluationToJson(evaluation))
          if (extras.isNotEmpty()) {
            put("extras", JSONObject(extras.mapValues { it.value ?: JSONObject.NULL }))
          }
        }

        val sb = StringBuilder()
        sb.append(JSONObject().apply { put("type", "run"); put("run", summary) }.toString())
        sb.append('\n')
        for (s in spans) {
          sb.append(JSONObject().apply {
            put("type", "span")
            put("run_id", runId)
            put("span", s)
          }.toString())
          sb.append('\n')
        }

        outputFile.parentFile?.mkdirs()
        outputFile.writeText(sb.toString())
        Log.d(TAG, "Wrote trace to ${outputFile.absolutePath} (${spans.size} spans)")
      }
    } catch (e: Exception) {
      Log.w(TAG, "Failed to flush trace", e)
    }
  }

  private fun readThermal(): Int = try {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      powerManager?.currentThermalStatus ?: -1
    } else -1
  } catch (e: Exception) { -1 }

  private fun readMemoryMb(): Long = try {
    val info = Debug.MemoryInfo()
    Debug.getMemoryInfo(info)
    info.totalPss / 1024L
  } catch (e: Exception) { -1L }

  private fun planToJson(plan: ExecutionPlan): JSONObject = JSONObject().apply {
    put("goal", plan.goal)
    put("reasoning", plan.reasoning)
    val stepsArr = JSONArray()
    for (step in plan.steps) {
      stepsArr.put(JSONObject().apply {
        put("id", step.id)
        put("description", step.description)
        put("skill_name", step.skillName ?: JSONObject.NULL)
        put("tool_name", step.toolName ?: JSONObject.NULL)
        put("tool_args", JSONObject(step.toolArgs))
        put("depends_on", JSONArray(step.dependsOn))
      })
    }
    put("steps", stepsArr)
    put("success_criteria", JSONArray(plan.successCriteria))
  }

  private fun stepResultsToJson(results: Map<String, StepResult>): JSONObject =
    JSONObject().apply {
      for ((id, r) in results) {
        put(id, JSONObject().apply {
          put("status", r.status.name)
          put("output", r.output)
          put("error", r.error ?: JSONObject.NULL)
          put("duration_ms", r.durationMs)
        })
      }
    }

  private fun evaluationToJson(eval: EvaluationResult): JSONObject = JSONObject().apply {
    put("goal_achieved", eval.goalAchieved)
    put("assessment", eval.assessment)
    put("missing_items", JSONArray(eval.missingItems))
    put("should_replan", eval.shouldReplan)
    put("failed_criteria", JSONArray(eval.failedCriteria))
  }

  companion object {
    /**
     * Returns a new recorder if tracing is enabled on this device, else null.
     * Tracing is enabled by creating /sdcard/claw-traces/claw-trace-enabled
     * (any content, even empty). The Python eval harness creates this flag file
     * before each scenario run.
     */
    fun createIfEnabled(context: Context): TraceRecorder? {
      return try {
        val baseDir = File("/sdcard/$TRACE_DIR")
        val flag = File(baseDir, FLAG_FILE)
        if (!flag.exists()) return null
        val runId = UUID.randomUUID().toString()
        val outFile = File(baseDir, "$runId.jsonl")
        TraceRecorder(context.applicationContext, outFile, runId).also {
          Log.d(TAG, "Trace enabled, runId=$runId")
        }
      } catch (e: Exception) {
        Log.w(TAG, "Failed to create TraceRecorder", e)
        null
      }
    }

    /**
     * Returns a recorder that writes to the app's external files dir:
     *   /sdcard/Android/data/com.mobileclaw.app/files/claw-traces/<runId>.jsonl
     *
     * Bypasses the flag-file gate — used by the UI-free eval harness (EvalActivity).
     * We use the app-specific external dir (not top-level /sdcard/) because Android 11+
     * scoped storage blocks top-level /sdcard/ writes unless MANAGE_EXTERNAL_STORAGE is
     * granted. `adb pull` can still read this path from the host side.
     */
    fun forRunId(context: Context, runId: String): TraceRecorder {
      val baseDir = File(
        context.applicationContext.getExternalFilesDir(null) ?: context.applicationContext.filesDir,
        TRACE_DIR,
      )
      baseDir.mkdirs()
      val outFile = File(baseDir, "$runId.jsonl")
      return TraceRecorder(context.applicationContext, outFile, runId)
    }
  }
}
