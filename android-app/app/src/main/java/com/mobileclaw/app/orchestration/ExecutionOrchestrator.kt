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
private val LLM_ONLY_SKILLS = setOf("summarize", "compose")

/** Native app skills — map skill name to the native tool name. */
private val NATIVE_SKILL_TOOLS = mapOf(
  "calculator" to "calculate",
  "fetch-web-content" to "fetchWebContent",
  "send-sms" to "sendSms",
  "send-email" to "sendEmail",
  "calendar" to "manageCalendar",
  "timer" to "manageTimer",
  "read-contacts" to "readContacts",
  "list-photos" to "listPhotos",
  "search-photos" to "searchPhotos",
  "scan-barcode" to "scanBarcode",
  "list-apps" to "listApps",
  "launch-app" to "launchApp",
  "phone-call" to "makePhoneCall",
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
  "search-web" to "searchWeb",
  "search-skills" to "searchSkills",
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
  private val thinkingPolicy: ThinkingPolicy = ThinkingPolicy(ThinkingMode.AUTO),
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

    val today = java.time.LocalDate.now()
    val tomorrow = today.plusDays(1)
    val lower = value.lowercase().trim()

    // Handle natural language: "today at 11pm", "tomorrow at 9am", "today 23:00"
    val todayTomorrow = when {
      lower.startsWith("tomorrow") -> tomorrow
      lower.startsWith("today") || lower.startsWith("tonight") -> today
      else -> null
    }
    if (todayTomorrow != null) {
      val time = extractTime(lower)
      if (time != null) {
        args[key] = "${todayTomorrow}T$time"
        Log.d(TAG, "Fixed natural language date-time to: ${args[key]}")
        return
      }
      // No time found — default to 09:00
      args[key] = "${todayTomorrow}T09:00"
      Log.d(TAG, "Fixed natural language date (no time) to: ${args[key]}")
      return
    }

    // Handle time-only values: "23:00", "11pm", "9:30 AM"
    val timeOnly = extractTime(lower)
    if (timeOnly != null && !lower.contains(Regex("""\d{4}"""))) {
      args[key] = "${today}T$timeOnly"
      Log.d(TAG, "Fixed time-only to: ${args[key]}")
      return
    }

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
          val month = remaining.substring(0, 1).padStart(2, '0')
          val day = remaining.substring(1, 2).padStart(2, '0')
          args[key] = "$year-$month-${day}T$hour:$minute"
          Log.d(TAG, "Fixed short date-time to: ${args[key]}")
          return
        } else if (remaining.length == 3) {
          val month = remaining.substring(0, 2)
          val day = remaining.substring(2, 3).padStart(2, '0')
          if (month.toIntOrNull() in 1..12) {
            args[key] = "$year-$month-${day}T$hour:$minute"
            Log.d(TAG, "Fixed 3-digit date-time to: ${args[key]}")
            return
          }
          val month2 = remaining.substring(0, 1).padStart(2, '0')
          val day2 = remaining.substring(1, 3)
          args[key] = "$year-$month2-${day2}T$hour:$minute"
          Log.d(TAG, "Fixed M+dd date-time to: ${args[key]}")
          return
        }
      }
    }
  }

  /** Extract HH:mm from various time formats: "23:00", "11pm", "9:30 AM", "at 3pm" */
  private fun extractTime(input: String): String? {
    // 24h format: "23:00", "09:30"
    Regex("""(\d{1,2}):(\d{2})""").find(input)?.let {
      val h = it.groupValues[1].toInt()
      val m = it.groupValues[2].toInt()
      if (h in 0..23 && m in 0..59) return "${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}"
    }
    // 12h format: "11pm", "9 am", "3:30pm"
    Regex("""(\d{1,2})(?::(\d{2}))?\s*(am|pm)""", RegexOption.IGNORE_CASE).find(input)?.let {
      var h = it.groupValues[1].toInt()
      val m = it.groupValues[2].toIntOrNull() ?: 0
      val ampm = it.groupValues[3].lowercase()
      if (ampm == "pm" && h != 12) h += 12
      if (ampm == "am" && h == 12) h = 0
      if (h in 0..23 && m in 0..59) return "${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}"
    }
    return null
  }

  /** Fix date-only args: convert "today", "tomorrow" to yyyy-MM-dd. */
  internal fun fixDateArgs(args: MutableMap<String, String>, key: String) {
    val value = args[key] ?: return
    if (value.matches(Regex("""\d{4}-\d{2}-\d{2}"""))) return

    val today = java.time.LocalDate.now()
    val lower = value.lowercase().trim()
    val date = when {
      lower == "today" || lower.startsWith("today") -> today
      lower == "tomorrow" || lower.startsWith("tomorrow") -> today.plusDays(1)
      else -> return // leave as-is, DeviceSkills will default to today if blank
    }
    args[key] = date.toString()
    Log.d(TAG, "Fixed date arg '$key' from '$value' to '${args[key]}'")
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

    // Rescue garbled keys: scan all args for values that look like date-times
    // and map them to startDateTime/endDateTime if those are empty.
    val isoDateTimePattern = Regex("""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}""")
    if (args["startDateTime"].isNullOrBlank()) {
      // Look for any arg value that looks like a valid datetime
      val rescueEntry = args.entries.firstOrNull { (key, value) ->
        key != "endDateTime" && key != "title" && key != "action" &&
          key != "location" && key != "description" &&
          isoDateTimePattern.containsMatchIn(value)
      }
      if (rescueEntry != null) {
        args["startDateTime"] = rescueEntry.value
        args.remove(rescueEntry.key)
        Log.d(TAG, "Rescued startDateTime from garbled key '${rescueEntry.key}': ${args["startDateTime"]}")
      } else if (!args["endDateTime"].isNullOrBlank()) {
        // If endDateTime is set but startDateTime is empty, copy endDateTime
        args["startDateTime"] = args["endDateTime"]!!
        Log.d(TAG, "Copied endDateTime to missing startDateTime: ${args["startDateTime"]}")
      }
    }

    // If endDateTime is missing, default to startDateTime + 1 hour.
    if (!args["startDateTime"].isNullOrBlank() && args["endDateTime"].isNullOrBlank()) {
      val start = args["startDateTime"]!!
      val hourMatch = Regex("""T(\d{2}):(\d{2})""").find(start)
      if (hourMatch != null) {
        val hour = hourMatch.groupValues[1].toIntOrNull() ?: 0
        val newHour = ((hour + 1) % 24).toString().padStart(2, '0')
        args["endDateTime"] = start.replace(hourMatch.value, "T$newHour:${hourMatch.groupValues[2]}")
      }
    }

    // Last resort: if startDateTime is still empty, infer from step description context
    // using today's date + any time found in args values
    if (args["startDateTime"].isNullOrBlank()) {
      val today = java.time.LocalDate.now()
      // Try to find a time in any arg value
      for ((_, value) in args) {
        val time = extractTime(value.lowercase())
        if (time != null) {
          args["startDateTime"] = "${today}T$time"
          Log.d(TAG, "Inferred startDateTime from arg values: ${args["startDateTime"]}")
          break
        }
      }
    }
  }

  /**
   * Last-resort rescue from the plan step's natural-language description. Called after
   * [normalizeCalendarArgs] when the planner emitted garbage keys so badly that no
   * valid datetime or title survived. Small models frequently mangle calendar args
   * on first try — e.g. {"ddthh":"5","create":"Team Meeting"} — but the step
   * description ("Create calendar event called Team Meeting tomorrow at 3pm") is
   * always clean because it's just echoing the user prompt.
   *
   * Extracts:
   *  - title: via "called X" / "titled X" / "named X" / quoted-string patterns
   *  - startDateTime: via natural-language date-time phrases ("tomorrow at 3pm")
   *  - endDateTime: defaults to startDateTime + 1 hour if still missing
   */
  internal fun rescueCalendarFromDescription(args: MutableMap<String, String>, description: String) {
    val desc = description
    val lower = desc.lowercase()

    if (args["title"].isNullOrBlank()) {
      val patterns = listOf(
        Regex("""(?:called|titled|named|labeled)\s+['"]?([^'"\n]+?)['"]?(?:\s+(?:at|on|for|in|tomorrow|today|tonight|next|this)\b|$)""", RegexOption.IGNORE_CASE),
        Regex("""['"]([^'"]+)['"]"""),
        Regex("""(?:reminder|event|meeting)\s+(?:to|for|about)\s+(.+?)(?:\s+(?:at|on|for|in|tomorrow|today|tonight)\b|$)""", RegexOption.IGNORE_CASE),
      )
      for (pattern in patterns) {
        val m = pattern.find(desc) ?: continue
        val candidate = m.groupValues[1].trim().trimEnd('.', ',', '!', '?')
        if (candidate.length in 2..80) {
          args["title"] = candidate
          Log.d(TAG, "Rescued title from description: '$candidate'")
          break
        }
      }
    }

    // Derive an authoritative datetime from the description whenever it contains
    // an unambiguous natural-language anchor ("tomorrow at 9am", "today 3pm"). We
    // trust this over whatever the planner emitted, because garbled planner output
    // ({"ddthh":"15","endDateTime":"202604020T15:300"}) may have passed earlier
    // normalization with a wrong date (2026-04-02 instead of 2026-04-20).
    val today = java.time.LocalDate.now()
    val tomorrow = today.plusDays(1)
    val targetDate = when {
      Regex("""\btomorrow\b""").containsMatchIn(lower) -> tomorrow
      Regex("""\btonight\b""").containsMatchIn(lower) -> today
      Regex("""\btoday\b""").containsMatchIn(lower) -> today
      else -> null
    }
    val explicitTime = extractTime(lower)
    if (targetDate != null) {
      val time = explicitTime ?: "09:00"
      val derived = "${targetDate}T$time"
      val existing = args["startDateTime"]
      if (existing != derived) {
        args["startDateTime"] = derived
        Log.d(TAG, "Rescued startDateTime from description: $derived (was: $existing)")
        // Re-derive endDateTime when we overrode the start — the old end would
        // carry the wrong date/time from the planner's garbled input.
        val endHour = ((time.substring(0, 2).toIntOrNull() ?: 0) + 1) % 24
        val newEnd = "${targetDate}T${endHour.toString().padStart(2, '0')}:${time.substring(3, 5)}"
        if (args["endDateTime"] != newEnd) {
          args["endDateTime"] = newEnd
          Log.d(TAG, "Re-derived endDateTime to $newEnd")
        }
      }
    }

    if (!args["startDateTime"].isNullOrBlank() && args["endDateTime"].isNullOrBlank()) {
      val start = args["startDateTime"]!!
      val hourMatch = Regex("""T(\d{2}):(\d{2})""").find(start)
      if (hourMatch != null) {
        val hour = hourMatch.groupValues[1].toIntOrNull() ?: 0
        val newHour = ((hour + 1) % 24).toString().padStart(2, '0')
        args["endDateTime"] = start.replace(hourMatch.value, "T$newHour:${hourMatch.groupValues[2]}")
        Log.d(TAG, "Defaulted endDateTime to start+1h: ${args["endDateTime"]}")
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

    // For multi-action tools, infer the action from the step description if missing.
    // Use word-boundary matching to avoid false positives (e.g., "DeleteMe" != "delete").
    if (toolName == "manageCalendar" && !args.containsKey("action")) {
      val desc = step.description.lowercase()
      fun hasWord(vararg words: String) = words.any { desc.contains(Regex("""\b${it}\b""")) }
      val action = when {
        hasWord("delete", "remove", "cancel") -> "delete"
        hasWord("edit", "update", "change", "modify", "rename") -> "edit"
        hasWord("read", "show", "list", "get", "check", "view", "find", "search") -> "read"
        else -> "create"
      }
      args["action"] = action
      Log.d(TAG, "Inferred calendar action='$action' from description: ${step.description}")
    }

    // For calendar edit/delete, ensure we have an eventId or title to look up.
    if (toolName == "manageCalendar") {
      val action = args["action"]?.lowercase()
      if (action == "delete" || action == "edit") {
        // If eventId is a non-numeric string (e.g., dep output or placeholder), try to extract real ID
        val currentId = args["eventId"]
        if (!currentId.isNullOrBlank() && currentId.toLongOrNull() == null) {
          val idMatch = Regex("""_id=(\d+)""").find(currentId)
            ?: Regex("""event_id[=:](\d+)""").find(currentId)
          if (idMatch != null) {
            args["eventId"] = idMatch.groupValues[1]
            Log.d(TAG, "Extracted eventId '${args["eventId"]}' from raw value")
          } else {
            args.remove("eventId") // invalid, let title lookup handle it
            Log.d(TAG, "Removed invalid eventId: ${currentId.take(100)}")
          }
        }

        // If still no valid eventId, try title-based lookup
        if (args["eventId"].isNullOrBlank()) {
          // Check dependency outputs for event IDs
          for ((_, output) in depOutputs) {
            val idMatch = Regex("""_id=(\d+)""").find(output)
              ?: Regex("""event_id[=:](\d+)""").find(output)
            if (idMatch != null) {
              args["eventId"] = idMatch.groupValues[1]
              Log.d(TAG, "Extracted eventId '${args["eventId"]}' from dependency output")
              break
            }
          }
        }

        // If still no eventId, extract title from step description
        if (args["eventId"].isNullOrBlank() && args["title"].isNullOrBlank() && args["originalTitle"].isNullOrBlank()) {
          val desc = step.description
          val titleMatch = Regex("""['"]([^'"]+)['"]""").find(desc)
            ?: Regex("""(?:named|called|titled)\s+(\S+)""", RegexOption.IGNORE_CASE).find(desc)
          if (titleMatch != null) {
            args["title"] = titleMatch.groupValues[1]
            Log.d(TAG, "Extracted event title '${args["title"]}' from description for $action")
          }
        }
      }
    }

    if (toolName == "manageTimer" && !args.containsKey("action")) {
      val desc = step.description.lowercase()
      val action = when {
        desc.contains("dismiss") -> "dismiss_alarm"
        desc.contains("show") || desc.contains("list") || desc.contains("view") -> "show_alarms"
        desc.contains("timer") || desc.contains("countdown") -> "set_timer"
        else -> "set_alarm"
      }
      args["action"] = action
      Log.d(TAG, "Inferred timer action='$action' from description: ${step.description}")
    }

    // For calendar tool, fix common date-time arg issues.
    if (toolName == "manageCalendar") {
      fixDateTimeArgs(args, "startdatetime")
      fixDateTimeArgs(args, "startDateTime")
      fixDateTimeArgs(args, "enddatetime")
      fixDateTimeArgs(args, "endDateTime")
      fixDateTimeArgs(args, "dateTime")
      fixDateTimeArgs(args, "datetime")
      fixDateArgs(args, "startDate")
      fixDateArgs(args, "endDate")
      fixDateArgs(args, "startdate")
      fixDateArgs(args, "enddate")
      normalizeCalendarArgs(args)
      rescueCalendarFromDescription(args, step.description)
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

      // Prefer the explicit `instruction` toolArg (set by compose/summarize) over the
      // generic step description — it's usually a more specific directive.
      val taskText = step.toolArgs["instruction"]?.takeIf { it.isNotBlank() }
        ?: step.toolArgs["text"]?.takeIf { it.isNotBlank() && step.skillName != "summarize" }
        ?: step.description

      val prompt = buildString {
        if (contextParts.isNotEmpty()) {
          append("Context from previous steps:\n")
          append(contextParts.joinToString("\n"))
          append("\n\n")
        }
        append("Task: $taskText")
        if (isLlmSkill) {
          append("\n\nIMPORTANT: Output ONLY the result text. Do not add explanations or preamble.")
        }
      }

      val response = llmProvider.generateResponse(
        prompt,
        enableThinking = thinkingPolicy.llmStep(),
      )

      StepResult(
        stepId = step.id,
        status = StepStatus.COMPLETED,
        output = response,
      )
    }
  }
}
