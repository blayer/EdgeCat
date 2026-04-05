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

import android.content.Context
import android.util.Log
import com.mobileclaw.app.common.AgentAction
import com.mobileclaw.app.common.AskInfoAgentAction
import com.mobileclaw.app.common.CallJsAgentAction
import com.mobileclaw.app.common.CallJsSkillResult
import com.mobileclaw.app.common.CallJsSkillResultImage
import com.mobileclaw.app.common.CallJsSkillResultWebview
import com.mobileclaw.app.common.LOCAL_URL_BASE
import com.mobileclaw.app.common.SkillProgressAgentAction
import com.google.ai.edge.litertlm.Tool
import com.google.ai.edge.litertlm.ToolParam
import com.google.ai.edge.litertlm.ToolSet
import com.squareup.moshi.JsonAdapter
import com.squareup.moshi.Moshi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.runBlocking

private const val TAG = "AGAgentTools"

class AgentTools() : ToolSet {
  lateinit var context: Context
  lateinit var skillManagerViewModel: SkillManagerViewModel

  private val _actionChannel = Channel<AgentAction>(Channel.UNLIMITED)
  val actionChannel: ReceiveChannel<AgentAction> = _actionChannel
  var resultImageToShow: CallJsSkillResultImage? = null
  var resultWebviewToShow: CallJsSkillResultWebview? = null

  /** Native device skills — SMS, calendar, contacts, photos, apps, phone. */
  val deviceSkills by lazy {
    DeviceSkills(contextProvider = { context }, actionChannel = _actionChannel)
  }

  /** Loads skill. */
  @Tool(description = "Loads a skill.")
  fun loadSkill(
    @ToolParam(description = "The name of the skill to load.") skillName: String
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) {
      val skills = skillManagerViewModel.getSelectedSkills()
      val skill = skills.find { it.name == skillName.trim() }
      val skillContent =
        if (skill != null) {
          "---\nname: ${skill.name}\ndescription: ${skill.description}\n---\n\n${skill.instructions}"
        } else {
          "Skill not found"
        }
      Log.d(TAG, "load skill. Skill content:\n$skillContent")
      if (skill != null) {
        _actionChannel.send(
          SkillProgressAgentAction(
            label = "Loading skill \"$skillName\"",
            inProgress = true,
            addItemTitle = "Load \"${skill.name}\"",
            addItemDescription = "Description: ${skill.description}",
            customData = skill,
          )
        )
      } else {
        _actionChannel.send(
          SkillProgressAgentAction(
            label = "Failed to load skill \"$skillName\"",
            inProgress = false,
          )
        )
      }

      mapOf("skill_name" to skillName, "skill_instructions" to skillContent)
    }
  }

  /** Call JS skill */
  @Tool(description = "Runs JS script")
  fun runJs(
    @ToolParam(description = "The name of skill") skillName: String,
    @ToolParam(description = "The script name to run. Use 'index.html' if not provided by user")
    scriptName: String,
    @ToolParam(
      description = "The data to pass to the script. Use empty string if not provided by user"
    )
    data: String,
  ): Map<String, Any> {
    return runBlocking(Dispatchers.Default) {
      Log.d(
        TAG,
        "runJS tool called with:" +
          "\n- skillName: ${skillName}\n- scriptName: ${scriptName}\n- data: ${data}\n",
      )

      val skills = skillManagerViewModel.getSelectedSkills()
      val skill = skills.find { it.name == skillName.trim() }

      if (skill == null) {
        _actionChannel.send(
          SkillProgressAgentAction(
            label = "Failed to call skill \"$scriptName\"",
            inProgress = false,
          )
        )
        return@runBlocking mapOf(
          "error" to "Skill \"${scriptName}\" not found",
          "status" to "failed",
        )
      }

      // Check secret. If a skill requires a secret and the secret is not provided, show error.
      var secret = ""
      if (skill.requireSecret) {
        val savedSecret =
          skillManagerViewModel.dataStoreRepository.readSecret(
            key = getSkillSecretKey(skillName = skillName)
          )
        if (savedSecret == null || savedSecret.isEmpty()) {
          val action =
            AskInfoAgentAction(
              dialogTitle = "Enter secret",
              fieldLabel =
                skill.requireSecretDescription.ifEmpty {
                  "The JS script needs a secret (API key / token) to proceed:"
                },
            )
          _actionChannel.send(action)
          secret = action.result.await()
          if (secret.isNotEmpty()) {
            skillManagerViewModel.dataStoreRepository.saveSecret(
              key = getSkillSecretKey(skillName = skillName),
              value = secret,
            )
            Log.d(TAG, "Got Secret from ask info dialog: ${secret.substring(0, 3)}")
          } else {
            Log.d(TAG, "The ask info dialog got cancelled. No secret.")
          }
        } else {
          secret = savedSecret
        }
      }

      // Get the url for the skill.
      val url =
        skillManagerViewModel.getJsSkillUrl(skillName = skillName, scriptName = scriptName)
          ?: return@runBlocking mapOf(
            "result" to "JS Skill URL not set properly or skill not found"
          )
      Log.d(TAG, "Calling JS script.\n- url: $url\n- data: $data")

      // Update progress.
      _actionChannel.send(
        SkillProgressAgentAction(
          label = "Calling JS script \"${skillName}/${scriptName}\"",
          inProgress = true,
          addItemTitle = "Call JS script: \"${skillName}/${scriptName}\"",
          addItemDescription = "- URL: ${url.replace(LOCAL_URL_BASE, "")}\n- Data: $data",
          customData = skill,
        )
      )

      // Actually run it and wait for the result.
      val action =
        CallJsAgentAction(url = url, data = data.trim().ifEmpty { "{}" }, secret = secret)
      _actionChannel.send(action)
      val result = action.result.await()

      // Try to parse result to CallJsSkillResult.
      val moshi: Moshi = Moshi.Builder().build()
      val jsonAdapter: JsonAdapter<CallJsSkillResult> =
        moshi.adapter(CallJsSkillResult::class.java).failOnUnknown()
      val resultJson = runCatching { jsonAdapter.fromJson(result) }.getOrNull()
      val error = resultJson?.error

      // Failed to parse. Treat its whole as a result string.
      if (
        resultJson == null ||
          (resultJson.result == null && resultJson.webview == null && resultJson.image == null)
      ) {
        mapOf("result" to result, "status" to "succeeded")
      }
      // Error case.
      else if (error != null) {
        mapOf("error" to error, "status" to "failed")
      }
      // Non-error cases.
      else {
        // Handle image and webview in result.
        val image = resultJson.image
        val webview = resultJson.webview
        if (image != null) {
          Log.d(TAG, "Got an image response.")
          resultImageToShow = image
        }
        if (webview != null) {
          Log.d(TAG, "Got an webview response.")
          val webviewUrl =
            skillManagerViewModel.getJsSkillWebviewUrl(
              skillName = skillName,
              url = webview.url ?: "",
            )
          Log.d(TAG, "Webview url: $webviewUrl")
          resultWebviewToShow = webview.copy(url = webviewUrl)
        }
        Log.d(TAG, "Result: ${resultJson.result}")
        mapOf("result" to (resultJson.result ?: ""), "status" to "succeeded")
      }
    }
  }

  @Tool(
    description =
      "Run an Android intent. It is used to interact with the app to perform certain actions."
  )
  fun runIntent(
    @ToolParam(description = "The intent to run.") intent: String,
    @ToolParam(
      description = "A JSON string containing the parameter values required for the intent."
    )
    parameters: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) {
      Log.d(TAG, "Run intent. Intent: '$intent', parameters: '$parameters'")
      _actionChannel.send(
        SkillProgressAgentAction(
          label = "Executing intent \"$intent\"",
          inProgress = true,
          addItemTitle = "Execute intent \"$intent\"",
          addItemDescription = "Parameters: $parameters",
        )
      )
      if (IntentHandler.handleAction(context, intent, parameters)) {
        return@runBlocking mapOf(
          "action" to intent,
          "parameters" to parameters,
          "result" to "succeeded",
        )
      } else {
        return@runBlocking mapOf(
          "action" to intent,
          "parameters" to parameters,
          "result" to "failed",
        )
      }
    }
  }

  fun sendAgentAction(action: AgentAction) {
    runBlocking(Dispatchers.Default) { _actionChannel.send(action) }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // App Skills — native device access (separate from JS/MCP skills above)
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  @Tool(description = "Send an SMS text message directly to a phone number")
  fun sendSms(
    @ToolParam(description = "The phone number to send the SMS to") phoneNumber: String,
    @ToolParam(description = "The text message body to send") messageBody: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.sendSms(phoneNumber, messageBody) }
  }

  @Tool(description = "Send an email by opening the email app with pre-filled fields")
  fun sendEmail(
    @ToolParam(description = "The email address to send to") to: String,
    @ToolParam(description = "The email subject") subject: String,
    @ToolParam(description = "The email body text") body: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.sendEmail(to, subject, body) }
  }

  @Tool(description = "Read calendar events within a date range from the device calendar")
  fun readCalendarEvents(
    @ToolParam(description = "Start date in yyyy-MM-dd format") startDate: String,
    @ToolParam(description = "End date in yyyy-MM-dd format") endDate: String,
  ): Map<String, Any> {
    return runBlocking(Dispatchers.Default) { deviceSkills.readCalendarEvents(startDate, endDate) }
  }

  @Tool(description = "Create a new event in the device calendar")
  fun createCalendarEvent(
    @ToolParam(description = "Event title") title: String,
    @ToolParam(description = "Start date and time in yyyy-MM-ddTHH:mm format") startDateTime: String,
    @ToolParam(description = "End date and time in yyyy-MM-ddTHH:mm format") endDateTime: String,
    @ToolParam(description = "Event location, use empty string if none") location: String,
    @ToolParam(description = "Event description, use empty string if none") description: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) {
      deviceSkills.createCalendarEvent(title, startDateTime, endDateTime, location, description)
    }
  }

  @Tool(description = "Search contacts by name or list all contacts on the device")
  fun readContacts(
    @ToolParam(description = "Search query to filter contacts by name. Use empty string to list all") query: String,
    @ToolParam(description = "Maximum number of contacts to return") maxResults: String,
  ): Map<String, Any> {
    val max = maxResults.toIntOrNull() ?: 20
    return runBlocking(Dispatchers.Default) { deviceSkills.readContacts(query, max) }
  }

  @Tool(description = "List recent photos from the device gallery")
  fun listPhotos(
    @ToolParam(description = "Maximum number of photos to return") maxResults: String,
  ): Map<String, Any> {
    val max = maxResults.toIntOrNull() ?: 20
    return runBlocking(Dispatchers.Default) { deviceSkills.listPhotos(max) }
  }

  @Tool(description = "List installed apps that can be launched on the device")
  fun listApps(
    @ToolParam(description = "Search query to filter apps by name. Use empty string to list all") query: String,
  ): Map<String, Any> {
    return runBlocking(Dispatchers.Default) { deviceSkills.listApps(query) }
  }

  @Tool(description = "Launch an app on the device by its package name")
  fun launchApp(
    @ToolParam(description = "The package name of the app to launch, e.g. com.android.chrome") packageName: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.launchApp(packageName) }
  }

  @Tool(description = "Make a phone call to a number")
  fun makePhoneCall(
    @ToolParam(description = "The phone number to call") phoneNumber: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.makePhoneCall(phoneNumber) }
  }
}

fun getSkillSecretKey(skillName: String): String {
  return "skill___${skillName}"
}
