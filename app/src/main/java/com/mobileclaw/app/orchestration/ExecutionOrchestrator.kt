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
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

private const val TAG = "AGExecutionOrchestrator"

/** Skills that are executed by the LLM rather than by running JS in a WebView. */
private val LLM_ONLY_SKILLS = setOf("summarize")

/** Native app skills — map skill name to the native tool name. */
private val NATIVE_SKILL_TOOLS = mapOf(
  "calculator" to "calculate",
  "fetch-web-content" to "fetchWebContent",
  "send-sms" to "sendSms",
  "send-email" to "sendEmail",
  "access-calendar" to "readCalendarEvents",
  "create-calendar-event" to "createCalendarEvent",
  "read-contacts" to "readContacts",
  "list-photos" to "listPhotos",
  "list-apps" to "listApps",
  "launch-app" to "launchApp",
  "phone-call" to "makePhoneCall",
  "set-alarm" to "setAlarm",
  "set-timer" to "setTimer",
  "get-location" to "getLocation",
  "open-url" to "openUrl",
  "clipboard" to "getClipboard",
  "device-info" to "getDeviceInfo",
  "share-content" to "shareContent",
  "flashlight" to "toggleFlashlight",
  "volume-control" to "setVolume",
  "do-not-disturb" to "setDoNotDisturb",
  "take-photo" to "takePhoto",
  "list-downloads" to "listDownloads",
  "open-settings" to "openSettings",
  "set-reminder" to "setReminder",
  "check-internet" to "checkInternet",
  "search-web" to "searchWeb",
)

/**
 * Module 2: Execution Orchestrator.
 *
 * Takes an [ExecutionPlan] (already batched by the [Planner]) and executes each batch. Tool-only
 * steps within a batch run in parallel; LLM-needing steps are serialized through a [Mutex] because
 * the LiteRT-LM Conversation is single-threaded.
 */
class ExecutionOrchestrator(
  private val llmProvider: LlmInferenceProvider,
  private val toolExecutor: ToolExecutor,
) {
  private val cancelled = AtomicBoolean(false)
  private val llmMutex = Mutex()

  /**
   * Execute a full plan organized into sequential batches.
   *
   * @param plan The execution plan.
   * @param batches Pre-computed batches from [Planner.getExecutionBatches].
   * @param onStepUpdate Callback invoked when a step's status changes.
   * @return Map of step ID to result.
   */
  suspend fun executePlan(
    plan: ExecutionPlan,
    batches: List<List<PlanStep>>,
    onStepUpdate: (StepResult) -> Unit,
  ): Map<String, StepResult> {
    cancelled.set(false)
    val allResults = mutableMapOf<String, StepResult>()

    for ((batchIndex, batch) in batches.withIndex()) {
      if (cancelled.get()) {
        Log.d(TAG, "Cancelled before batch $batchIndex")
        // Mark remaining steps as skipped.
        for (step in batch) {
          val result = StepResult(stepId = step.id, status = StepStatus.SKIPPED)
          allResults[step.id] = result
          onStepUpdate(result)
        }
        continue
      }

      Log.d(TAG, "Executing batch $batchIndex with ${batch.size} steps")
      val batchResults = executeBatch(batch, allResults, onStepUpdate)
      allResults.putAll(batchResults)
    }

    return allResults
  }

  /** Cancel the current execution. Checked between steps and batches. */
  fun cancel() {
    cancelled.set(true)
    llmProvider.cancel()
  }

  /**
   * Execute a single batch. Tool-only steps run in parallel, LLM steps are serialized.
   */
  private suspend fun executeBatch(
    batch: List<PlanStep>,
    previousResults: Map<String, StepResult>,
    onStepUpdate: (StepResult) -> Unit,
  ): Map<String, StepResult> = coroutineScope {
    val deferreds =
      batch.map { step ->
        async {
          if (cancelled.get()) {
            val result = StepResult(stepId = step.id, status = StepStatus.SKIPPED)
            onStepUpdate(result)
            return@async step.id to result
          }

          // Notify: step is running.
          onStepUpdate(StepResult(stepId = step.id, status = StepStatus.RUNNING))

          val result = executeStep(step, previousResults)
          onStepUpdate(result)
          step.id to result
        }
      }

    deferreds.awaitAll().toMap()
  }

  /** Execute a single step, choosing the right execution path based on toolName. */
  private suspend fun executeStep(
    step: PlanStep,
    previousResults: Map<String, StepResult>,
  ): StepResult {
    val startTime = System.currentTimeMillis()

    return try {
      // Determine the effective tool name:
      // 1. If toolName is already set, use it.
      // 2. If skillName maps to a native app skill, use the native tool.
      // 3. If skillName is LLM-only (e.g. "summarize"), treat as LLM step.
      // 4. Otherwise, treat as a JS skill (runJs).
      // Normalize skill name: LLMs often use underscores instead of hyphens.
      val normalizedSkillName = step.skillName?.replace('_', '-')
      val nativeTool = normalizedSkillName?.let { NATIVE_SKILL_TOOLS[it] }
      val effectiveToolName = step.toolName
        ?: nativeTool
        ?: if (!normalizedSkillName.isNullOrEmpty() && normalizedSkillName !in LLM_ONLY_SKILLS) "runJs" else null

      Log.d(TAG, "Step ${step.id}: toolName=${step.toolName}, skillName=${step.skillName}, nativeTool=$nativeTool, effectiveToolName=$effectiveToolName")

      val result =
        when {
          effectiveToolName == null -> executeLlmStep(step, previousResults)
          effectiveToolName in listOf("loadSkill", "runJs", "runIntent") ->
            executeToolStep(step.copy(toolName = effectiveToolName), previousResults)
          nativeTool != null ->
            executeNativeToolStep(step, nativeTool, previousResults)
          else -> {
            // Try as a direct tool call (covers any registered native tool).
            executeNativeToolStep(step, effectiveToolName, previousResults)
          }
        }

      result.copy(durationMs = System.currentTimeMillis() - startTime)
    } catch (e: Exception) {
      Log.e(TAG, "Step ${step.id} failed with exception", e)
      StepResult(
        stepId = step.id,
        status = StepStatus.FAILED,
        error = e.message ?: "Unknown error",
        durationMs = System.currentTimeMillis() - startTime,
      )
    }
  }

  /** Execute a tool-based step. These can run in parallel. */
  private suspend fun executeToolStep(
    step: PlanStep,
    previousResults: Map<String, StepResult> = emptyMap(),
  ): StepResult {
    Log.d(TAG, "Executing tool step: ${step.id} (${step.toolName}, skill=${step.skillName})")

    val args = step.toolArgs.toMutableMap()
    // Ensure skillName is in args if the tool needs it.
    // Normalize underscores to hyphens to match asset folder names.
    if (step.skillName != null && !args.containsKey("skillName")) {
      args["skillName"] = step.skillName.replace('_', '-')
    }
    // Ensure scriptName defaults to index.html for runJs.
    if (step.toolName == "runJs" && !args.containsKey("scriptName")) {
      args["scriptName"] = "index.html"
    }

    // For runJs: build or augment the "data" JSON field.
    if (step.toolName == "runJs") {
      val reservedKeys = setOf("skillName", "scriptName", "data")
      // Collect non-reserved args (e.g., "city"="Tokyo") into the data JSON.
      val extraDataArgs = args.filter { it.key !in reservedKeys }
      // Collect outputs from dependent steps.
      val depOutputMap = mutableMapOf<String, String>()
      for (depId in step.dependsOn) {
        val depResult = previousResults[depId]
        if (depResult != null && depResult.status == StepStatus.COMPLETED) {
          depOutputMap[depId] = depResult.output.take(500)
        }
      }

      // Parse existing data or start fresh.
      val dataJson = try {
        if (!args["data"].isNullOrEmpty() && args["data"] != "{}") {
          org.json.JSONObject(args["data"]!!)
        } else {
          org.json.JSONObject()
        }
      } catch (e: Exception) {
        org.json.JSONObject()
      }

      // Add non-reserved args into data.
      for ((key, value) in extraDataArgs) {
        dataJson.put(key, value)
      }

      // Replace placeholder values that reference step outputs.
      // The LLM often generates placeholders like "Output from step_1" or "Wikipedia summary for Tokyo".
      // Strategy: scan data values for references to step IDs, replace with actual output.
      val keysToUpdate = mutableMapOf<String, String>()
      for (key in dataJson.keys()) {
        val value = dataJson.optString(key, "")
        for ((depId, output) in depOutputMap) {
          if (value.contains(depId, ignoreCase = true) ||
              value.startsWith("Output from", ignoreCase = true)) {
            keysToUpdate[key] = output
            depOutputMap.remove(depId)
            break
          }
        }
      }
      for ((key, output) in keysToUpdate) {
        dataJson.put(key, output)
      }

      // For remaining deps not matched to placeholders:
      // Only replace a field if its value looks like a placeholder (empty or references a step).
      // Otherwise add as step_N keys to avoid overwriting real user data.
      if (depOutputMap.isNotEmpty()) {
        val nonReservedKeys = dataJson.keys().asSequence().toList()
        if (depOutputMap.size == 1 && nonReservedKeys.size == 1) {
          val existingValue = dataJson.optString(nonReservedKeys[0], "")
          val looksLikePlaceholder = existingValue.isBlank() ||
            step.dependsOn.any { existingValue.contains(it, ignoreCase = true) } ||
            existingValue.startsWith("Output from", ignoreCase = true) ||
            existingValue.startsWith("[", ignoreCase = true)
          if (looksLikePlaceholder) {
            dataJson.put(nonReservedKeys[0], depOutputMap.values.first())
          } else {
            // Real data — add dep output as step_N key instead.
            for ((depId, output) in depOutputMap) {
              dataJson.put(depId, output)
            }
          }
        } else {
          for ((depId, output) in depOutputMap) {
            dataJson.put(depId, output)
          }
        }
      }

      // If data is still empty but we have deps, add them all.
      if (dataJson.length() == 0 && previousResults.isNotEmpty()) {
        for (depId in step.dependsOn) {
          val depResult = previousResults[depId]
          if (depResult != null && depResult.status == StepStatus.COMPLETED) {
            dataJson.put(depId, depResult.output.take(500))
          }
        }
      }

      args["data"] = dataJson.toString()
      // Remove non-reserved keys from top-level args.
      for (key in extraDataArgs.keys) {
        args.remove(key)
      }
    }

    Log.d(TAG, "Tool args: $args")
    val toolResult = toolExecutor.executeTool(step.toolName!!, args)

    return StepResult(
      stepId = step.id,
      status = if (toolResult.success) StepStatus.COMPLETED else StepStatus.FAILED,
      output = toolResult.output,
      error = toolResult.error,
    )
  }

  /**
   * Fix date-time args that the LLM may have garbled.
   * Tries to ensure the value is in yyyy-MM-ddTHH:mm format.
   */
  internal fun fixDateTimeArgs(args: MutableMap<String, String>, key: String) {
    val value = args[key] ?: return
    // Already valid format.
    if (value.matches(Regex("""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}"""))) return

    Log.d(TAG, "Fixing date-time arg '$key': '$value'")

    // Try to extract date and time components from garbled input.
    // Handle patterns like "2066406T15:00" -> should be "2026-04-06T15:00"
    val timeMatch = Regex("""(\d{1,2}):(\d{2})""").find(value)
    if (timeMatch != null) {
      val hour = timeMatch.groupValues[1].padStart(2, '0')
      val minute = timeMatch.groupValues[2]
      val beforeTime = value.substring(0, timeMatch.range.first).replace(Regex("[^0-9]"), "")

      if (beforeTime.length >= 8) {
        // 8+ digits: yyyyMMdd
        val year = beforeTime.substring(0, 4)
        val month = beforeTime.substring(4, 6)
        val day = beforeTime.substring(6, 8)
        args[key] = "$year-$month-${day}T$hour:$minute"
        Log.d(TAG, "Fixed date-time to: ${args[key]}")
        return
      } else if (beforeTime.length >= 6) {
        // 6-7 digits: might be garbled. Try yyyy + M + dd or yyyyMd.
        val year = beforeTime.substring(0, 4)
        val remaining = beforeTime.substring(4)
        if (remaining.length == 2) {
          // Could be Md (e.g., "46" for April 6th).
          val month = remaining.substring(0, 1).padStart(2, '0')
          val day = remaining.substring(1, 2).padStart(2, '0')
          args[key] = "$year-$month-${day}T$hour:$minute"
          Log.d(TAG, "Fixed short date-time to: ${args[key]}")
          return
        } else if (remaining.length == 3) {
          // Could be MMd or Mdd.
          val month = remaining.substring(0, 2)
          val day = remaining.substring(2, 3).padStart(2, '0')
          if (month.toIntOrNull() in 1..12) {
            args[key] = "$year-$month-${day}T$hour:$minute"
            Log.d(TAG, "Fixed 3-digit date-time to: ${args[key]}")
            return
          }
          // Try M + dd.
          val month2 = remaining.substring(0, 1).padStart(2, '0')
          val day2 = remaining.substring(1, 3)
          args[key] = "$year-$month2-${day2}T$hour:$minute"
          Log.d(TAG, "Fixed M+dd date-time to: ${args[key]}")
          return
        }
      }
    }
  }

  /**
   * Normalize calendar event arg keys to match what DeviceSkills expects.
   * LLM may use startdatetime vs startDateTime, etc.
   */
  internal fun normalizeCalendarArgs(args: MutableMap<String, String>) {
    val keyMap = mapOf(
      "startdatetime" to "startDateTime",
      "enddatetime" to "endDateTime",
      "start_date_time" to "startDateTime",
      "end_date_time" to "endDateTime",
      "start" to "startDateTime",
      "end" to "endDateTime",
    )
    for ((from, to) in keyMap) {
      if (args.containsKey(from) && !args.containsKey(to)) {
        args[to] = args.remove(from)!!
      }
    }

    // If endDateTime is missing, default to startDateTime + 1 hour.
    if (args.containsKey("startDateTime") && !args.containsKey("endDateTime")) {
      val start = args["startDateTime"]!!
      val hourMatch = Regex("""T(\d{2}):(\d{2})""").find(start)
      if (hourMatch != null) {
        val hour = hourMatch.groupValues[1].toIntOrNull() ?: 0
        val newHour = ((hour + 1) % 24).toString().padStart(2, '0')
        args["endDateTime"] = start.replace(hourMatch.value, "T$newHour:${hourMatch.groupValues[2]}")
      }
    }
  }

  /** Execute a native app skill step (calculator, web search, device skills, etc.). */
  private suspend fun executeNativeToolStep(
    step: PlanStep,
    toolName: String,
    previousResults: Map<String, StepResult>,
  ): StepResult {
    Log.d(TAG, "Executing native tool step: ${step.id} (tool=$toolName, skill=${step.skillName})")

    val args = step.toolArgs.toMutableMap()

    // Collect dependency outputs.
    val depOutputs = mutableMapOf<String, String>()
    for (depId in step.dependsOn) {
      val depResult = previousResults[depId]
      if (depResult != null && depResult.status == StepStatus.COMPLETED) {
        depOutputs[depId] = depResult.output.take(2000)
      }
    }

    // Resolve placeholder args that reference dependency outputs.
    // The LLM often generates values like "The URL from the result of step_1".
    for ((key, value) in args.toMap()) {
      for ((depId, output) in depOutputs) {
        if (value.contains(depId, ignoreCase = true) ||
            value.startsWith("Output from", ignoreCase = true) ||
            value.startsWith("The ", ignoreCase = true) && value.contains("result", ignoreCase = true)) {
          // For URL args, try to extract an actual URL from the output.
          if (key == "url") {
            Log.d(TAG, "Trying URL extraction from dep output (${output.length} chars): ${output.take(300)}")
            val urlMatch = Regex("https?://[^\\s,\"'\\]}>]+").find(output)
            if (urlMatch != null) {
              Log.d(TAG, "Extracted URL: ${urlMatch.value}")
              args[key] = urlMatch.value
              break
            }
            Log.d(TAG, "No URL found in dep output, using raw output")
          }
          // Otherwise, replace with the raw output.
          args[key] = output
          break
        }
      }
    }

    // Add remaining dep outputs as _dep_ keys for tools that may need them.
    for ((depId, output) in depOutputs) {
      if (!args.values.contains(output)) {
        args["_dep_${depId}"] = output
      }
    }

    // For calculator, ensure the expression is in args.
    if (toolName == "calculate" && !args.containsKey("expression")) {
      val desc = step.description
      args["expression"] = desc
    }

    // For calendar event creation, fix common date-time arg issues.
    if (toolName == "createCalendarEvent") {
      fixDateTimeArgs(args, "startdatetime")
      fixDateTimeArgs(args, "startDateTime")
      fixDateTimeArgs(args, "enddatetime")
      fixDateTimeArgs(args, "endDateTime")
      // Normalize arg keys to what DeviceSkills expects.
      normalizeCalendarArgs(args)
    }

    val result = toolExecutor.executeTool(toolName, args)
    return StepResult(
      stepId = step.id,
      status = if (result.success) StepStatus.COMPLETED else StepStatus.FAILED,
      output = result.output,
      error = result.error,
    )
  }

  private suspend fun executeLlmStep(
    step: PlanStep,
    previousResults: Map<String, StepResult>,
  ): StepResult {
    Log.d(TAG, "Executing LLM step: ${step.id} (skill=${step.skillName})")

    return llmMutex.withLock {
      // Build context from dependency results.  For LLM-only skills like "summarize",
      // include more of the dependency output since the whole point is to process it.
      val isLlmSkill = step.skillName in LLM_ONLY_SKILLS
      val maxOutputLen = if (isLlmSkill) 3000 else 500

      val contextParts = mutableListOf<String>()
      for (depId in step.dependsOn) {
        val depResult = previousResults[depId]
        if (depResult != null && depResult.status == StepStatus.COMPLETED) {
          contextParts.add("Result from $depId: ${depResult.output.take(maxOutputLen)}")
        }
      }

      val prompt = buildString {
        if (contextParts.isNotEmpty()) {
          append("Context from previous steps:\n")
          append(contextParts.joinToString("\n"))
          append("\n\n")
        }
        append("Task: ${step.description}")
        if (isLlmSkill) {
          append("\n\nIMPORTANT: Output ONLY the result text. Do not add explanations or preamble.")
        }
      }

      val response = llmProvider.generateResponse(prompt)

      StepResult(
        stepId = step.id,
        status = StepStatus.COMPLETED,
        output = response,
      )
    }
  }
}
