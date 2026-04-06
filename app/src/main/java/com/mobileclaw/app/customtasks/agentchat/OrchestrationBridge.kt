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

package com.mobileclaw.app.customtasks.agentchat

import com.mobileclaw.app.data.Model
import com.mobileclaw.app.orchestration.LlmInferenceProvider
import com.mobileclaw.app.orchestration.SkillSummary
import com.mobileclaw.app.orchestration.ToolExecutionResult
import com.mobileclaw.app.orchestration.ToolExecutor
import com.mobileclaw.app.ui.llmchat.LlmChatViewModelBase

/**
 * App-layer implementation of [LlmInferenceProvider].
 *
 * Wraps [LlmChatViewModelBase.generateInternalResponse] to provide LLM access to the orchestration
 * module without exposing ViewModel internals.
 */
class LlmInferenceProviderImpl(
  private val viewModel: LlmChatViewModelBase,
  private val modelProvider: () -> Model,
) : LlmInferenceProvider {

  override suspend fun generateResponse(prompt: String, enableThinking: Boolean): String {
    android.util.Log.d("AGOrchBridge", "generateResponse called, prompt length=${prompt.length}, thinking=$enableThinking")
    android.util.Log.d("AGOrchBridge", "prompt preview: ${prompt.take(200)}")
    val result = viewModel.generatePlanningResponse(modelProvider(), prompt, enableThinking)
    android.util.Log.d("AGOrchBridge", "generateResponse result length=${result.length}")
    android.util.Log.d("AGOrchBridge", "result preview: ${result.take(500)}")
    return result
  }

  override fun cancel() {
    viewModel.stopResponse(modelProvider())
  }
}

/**
 * App-layer implementation of [ToolExecutor].
 *
 * Wraps [AgentTools] and [SkillManagerViewModel] to provide tool execution to the orchestration
 * module.
 */
class ToolExecutorImpl(
  private val agentTools: AgentTools,
  private val skillManagerViewModel: SkillManagerViewModel,
) : ToolExecutor {

  override suspend fun executeTool(
    toolName: String,
    args: Map<String, String>,
  ): ToolExecutionResult {
    return try {
      val result =
        when (toolName) {
          "loadSkill" -> {
            val skillName = args["skillName"] ?: return ToolExecutionResult(
              success = false,
              output = "",
              error = "Missing skillName argument",
            )
            val map = agentTools.loadSkill(skillName)
            val instructions = map["skill_instructions"] ?: ""
            ToolExecutionResult(
              success = instructions != "Skill not found",
              output = instructions,
              error = if (instructions == "Skill not found") "Skill '$skillName' not found" else null,
            )
          }
          "runJs" -> {
            val skillName = args["skillName"] ?: return ToolExecutionResult(
              success = false,
              output = "",
              error = "Missing skillName argument",
            )
            val scriptName = args["scriptName"] ?: "index.html"
            val data = args["data"] ?: "{}"
            val map = agentTools.runJs(skillName, scriptName, data)
            val status = map["status"] as? String
            val output = (map["result"] as? String) ?: ""
            val error = map["error"] as? String
            ToolExecutionResult(
              success = status == "succeeded",
              output = output,
              error = error,
            )
          }
          "runIntent" -> {
            val intent = args["intent"] ?: return ToolExecutionResult(
              success = false,
              output = "",
              error = "Missing intent argument",
            )
            val parameters = args["parameters"] ?: "{}"
            val map = agentTools.runIntent(intent, parameters)
            val result = map["result"]
            ToolExecutionResult(
              success = result == "succeeded",
              output = result ?: "",
              error = if (result != "succeeded") "Intent failed" else null,
            )
          }
          // ── App Skills (native device access) ──
          "sendSms" -> {
            val map = agentTools.sendSms(args["phoneNumber"] ?: "", args["messageBody"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "sendEmail" -> {
            val map = agentTools.sendEmail(args["to"] ?: "", args["subject"] ?: "", args["body"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "readCalendarEvents" -> {
            val map = agentTools.readCalendarEvents(args["startDate"] ?: "", args["endDate"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "createCalendarEvent" -> {
            val map = agentTools.createCalendarEvent(
              args["title"] ?: "", args["startDateTime"] ?: "", args["endDateTime"] ?: "",
              args["location"] ?: "", args["description"] ?: "",
            )
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "readContacts" -> {
            val map = agentTools.readContacts(args["query"] ?: "", args["maxResults"] ?: "20")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "listPhotos" -> {
            val map = agentTools.listPhotos(args["maxResults"] ?: "20")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "listApps" -> {
            val map = agentTools.listApps(args["query"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "launchApp" -> {
            val map = agentTools.launchApp(args["packageName"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "makePhoneCall" -> {
            val map = agentTools.makePhoneCall(args["phoneNumber"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "setAlarm" -> {
            val map = agentTools.setAlarm(args["hour"] ?: "0", args["minute"] ?: "0", args["label"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "setTimer" -> {
            val map = agentTools.setTimer(args["durationSeconds"] ?: "60", args["label"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "getLocation" -> {
            val map = agentTools.getLocation()
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "openUrl" -> {
            val map = agentTools.openUrl(args["url"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "searchWeb" -> {
            val map = agentTools.searchWeb(args["query"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "fetchWebContent" -> {
            val map = agentTools.fetchWebContent(args["url"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "calculate" -> {
            val map = agentTools.calculate(args["expression"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "getClipboard" -> {
            val map = agentTools.getClipboard()
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "setClipboard" -> {
            val map = agentTools.setClipboard(args["text"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "getDeviceInfo" -> {
            val map = agentTools.getDeviceInfo()
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "shareContent" -> {
            val map = agentTools.shareContent(args["text"] ?: "", args["subject"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "toggleFlashlight" -> {
            val map = agentTools.toggleFlashlight(args["turnOn"] ?: "true")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "setVolume" -> {
            val map = agentTools.setVolume(args["streamType"] ?: "media", args["volumePercent"] ?: "50")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "setDoNotDisturb" -> {
            val map = agentTools.setDoNotDisturb(args["enable"] ?: "true")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "takePhoto" -> {
            val map = agentTools.takePhoto()
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "listDownloads" -> {
            val map = agentTools.listDownloads(args["maxResults"] ?: "20")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "openSettings" -> {
            val map = agentTools.openSettings(args["settingsPage"] ?: "general")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "setReminder" -> {
            val map = agentTools.setReminder(args["title"] ?: "", args["dateTime"] ?: "", args["minutesBefore"] ?: "10")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          else ->
            ToolExecutionResult(
              success = false,
              output = "",
              error = "Unknown tool: $toolName",
            )
        }
      result
    } catch (e: Exception) {
      ToolExecutionResult(
        success = false,
        output = "",
        error = e.message ?: "Tool execution failed",
      )
    }
  }

  override suspend fun updateSkillInstructions(
    skillName: String,
    newInstructions: String,
  ): Boolean {
    return skillManagerViewModel.updateSkillInstructionsProgrammatic(skillName, newInstructions)
  }

  override fun getAvailableSkills(): List<SkillSummary> {
    val skills = skillManagerViewModel.getSelectedSkills().map { skill ->
      SkillSummary(name = skill.name, description = skill.description, instructions = skill.instructions)
    }
    android.util.Log.d("AGOrchBridge", "getAvailableSkills: ${skills.size} skills: ${skills.map { it.name }}")
    return skills
  }
}
