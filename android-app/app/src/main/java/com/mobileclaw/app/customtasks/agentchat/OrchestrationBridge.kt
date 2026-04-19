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
    rawArgs: Map<String, String>,
  ): ToolExecutionResult {
    // Normalize arg keys to lowercase for case-insensitive lookup —
    // the on-device LLM often emits lowercase keys (e.g. "datetime" vs "dateTime").
    val args = rawArgs.mapKeys { it.key.lowercase() }
    return try {
      val result =
        when (toolName) {
          "loadSkill" -> {
            val skillName = args["skillname"] ?: return ToolExecutionResult(
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
            val skillName = args["skillname"] ?: return ToolExecutionResult(
              success = false,
              output = "",
              error = "Missing skillName argument",
            )
            val scriptName = args["scriptname"] ?: "index.html"
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
            val map = agentTools.sendSms(args["phonenumber"] ?: "", args["messagebody"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "sendEmail" -> {
            val map = agentTools.sendEmail(args["to"] ?: "", args["subject"] ?: "", args["body"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "manageCalendar" -> {
            val action = args["action"] ?: return ToolExecutionResult(
              success = false, output = "", error = "Missing action argument",
            )
            val calArgs = org.json.JSONObject(rawArgs.filterKeys { it.lowercase() != "action" }).toString()
            val map = agentTools.manageCalendar(action, calArgs)
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "manageTimer" -> {
            val action = args["action"] ?: return ToolExecutionResult(
              success = false, output = "", error = "Missing action argument",
            )
            val timerArgs = org.json.JSONObject(rawArgs.filterKeys { it.lowercase() != "action" }).toString()
            val map = agentTools.manageTimer(action, timerArgs)
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "readContacts" -> {
            val map = agentTools.readContacts(args["query"] ?: "", args["maxresults"] ?: "20")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "listPhotos" -> {
            val map = agentTools.listPhotos(args["maxresults"] ?: "20")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "searchPhotos" -> {
            val map = agentTools.searchPhotos(
              args["query"] ?: "",
              args["album"] ?: "",
              args["datefrom"] ?: "",
              args["dateto"] ?: "",
              args["maxresults"] ?: "20",
            )
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "scanBarcode" -> {
            val map = agentTools.scanBarcode(args["photouri"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "listApps" -> {
            val map = agentTools.listApps(args["query"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "launchApp" -> {
            val map = agentTools.launchApp(args["packagename"] ?: "")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "makePhoneCall" -> {
            val map = agentTools.makePhoneCall(args["phonenumber"] ?: "")
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
            val ok = map["status"] == "succeeded"
            // Return pre-formatted text directly. Map.toString() mangles large text values
            // (commas inside results break the downstream parser), and the results string is
            // already human-readable.
            val text = if (ok) {
              val q = map["query"] ?: args["query"] ?: ""
              buildString {
                append("Search results for: ").append(q).append("\n\n")
                append(map["results"] ?: "")
              }
            } else {
              map.toString()
            }
            ToolExecutionResult(success = ok, output = text, error = map["error"])
          }
          "fetchWebContent" -> {
            val map = agentTools.fetchWebContent(args["url"] ?: "")
            val ok = map["status"] == "succeeded"
            val text = if (ok) {
              val url = map["url"] ?: args["url"] ?: ""
              buildString {
                append("Content from: ").append(url).append("\n\n")
                append(map["content"] ?: "")
              }
            } else {
              map.toString()
            }
            ToolExecutionResult(success = ok, output = text, error = map["error"])
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
            val map = agentTools.toggleFlashlight(args["turnon"] ?: "true")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "setVolume" -> {
            val map = agentTools.setVolume(args["streamtype"] ?: "media", args["volumepercent"] ?: "50")
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
            val map = agentTools.listDownloads(args["maxresults"] ?: "20")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "openSettings" -> {
            val map = agentTools.openSettings(args["settingspage"] ?: "general")
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "checkInternet" -> {
            val map = agentTools.checkInternet()
            ToolExecutionResult(success = map["status"] == "succeeded", output = map.toString())
          }
          "searchSkills" -> {
            val query = (args["query"] ?: "").lowercase().trim()
            val allSkills = skillManagerViewModel.getSelectedSkills()
            val deferred = allSkills.filter { DEFERRED_SKILLS.contains(it.name) }
            val tokens = query.split(Regex("\\s+")).filter { it.isNotBlank() }
            val matches = if (tokens.isEmpty()) deferred else deferred.filter { skill ->
              val hay = (skill.name + " " + skill.description).lowercase()
              tokens.any { hay.contains(it) }
            }
            val json = org.json.JSONObject()
            json.put("status", "succeeded")
            val namesArr = org.json.JSONArray()
            val skillsArr = org.json.JSONArray()
            matches.forEach { skill ->
              namesArr.put(skill.name)
              val obj = org.json.JSONObject()
              obj.put("name", skill.name)
              obj.put("description", skill.description)
              obj.put("instructions", skill.instructions.take(800))
              skillsArr.put(obj)
            }
            json.put("loaded", namesArr)
            json.put("skills", skillsArr)
            android.util.Log.d("AGOrchBridge", "searchSkills query='$query' matched=${matches.map { it.name }}")
            ToolExecutionResult(success = true, output = json.toString())
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
      SkillSummary(
        name = skill.name,
        description = skill.description,
        instructions = skill.instructions,
        tier = if (DEFERRED_SKILLS.contains(skill.name)) "deferred" else "base",
      )
    }
    android.util.Log.d("AGOrchBridge", "getAvailableSkills: ${skills.size} skills (${skills.count { it.tier == "deferred" }} deferred): ${skills.map { it.name }}")
    return skills
  }

  companion object {
    /**
     * Skills kept out of the default planner catalog. Only their names are shown;
     * the agent must emit a `search-skills` step to load full details.
     *
     * Keep this list focused on skills that are:
     * - Rarely used for typical chat turns (photo/barcode/etc are niche)
     * - Have complex args the planner might fumble without full instructions
     * - Safe to be invisible on the common path (base skills cover most requests)
     */
    val DEFERRED_SKILLS = setOf(
      "scan-barcode", "search-photos", "list-photos", "take-photo",
      "send-sms", "send-email", "read-contacts", "phone-call",
      "get-location", "flashlight", "volume-control", "do-not-disturb",
      "list-downloads", "open-settings", "share-content",
    )
  }
}
