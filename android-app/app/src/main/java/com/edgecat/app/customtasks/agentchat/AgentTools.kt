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
package com.edgecat.app.customtasks.agentchat

import android.content.Context
import android.util.Log
import com.edgecat.app.common.AgentAction
import com.edgecat.app.common.AskInfoAgentAction
import com.edgecat.app.common.CallJsAgentAction
import com.edgecat.app.common.CallJsSkillResult
import com.edgecat.app.common.CallJsSkillResultImage
import com.edgecat.app.common.CallJsSkillResultWebview
import com.edgecat.app.common.LOCAL_URL_BASE
import com.edgecat.app.common.SkillProgressAgentAction
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

  @Tool(description = "Manage calendar events and reminders. Actions: create, read, edit, delete")
  fun manageCalendar(
    @ToolParam(description = "Action: create, read, edit, delete") action: String,
    @ToolParam(description = "JSON args, e.g. {\"title\":\"Meeting\",\"startDateTime\":\"2026-01-15T14:00\"}") args: String,
  ): Map<String, Any> {
    return runBlocking(Dispatchers.Default) {
      deviceSkills.manageCalendar(action, parseJsonArgs(args))
    }
  }

  @Tool(description = "Manage alarms and timers. Actions: set_alarm, set_timer, show_alarms, dismiss_alarm")
  fun manageTimer(
    @ToolParam(description = "Action: set_alarm, set_timer, show_alarms, dismiss_alarm") action: String,
    @ToolParam(description = "JSON args, e.g. {\"hour\":\"7\",\"minute\":\"30\",\"label\":\"Wake up\"}") args: String,
  ): Map<String, Any> {
    return runBlocking(Dispatchers.Default) {
      deviceSkills.manageTimer(action, parseJsonArgs(args))
    }
  }

  private fun parseJsonArgs(args: String): Map<String, String> {
    return try {
      val json = org.json.JSONObject(args)
      json.keys().asSequence().associateWith { json.optString(it, "") }
    } catch (e: Exception) {
      Log.w(TAG, "Failed to parse args as JSON: $args", e)
      emptyMap()
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

  @Tool(description = "Search photos by filename, album/folder, or date range. Any empty filter is ignored.")
  fun searchPhotos(
    @ToolParam(description = "Substring to match in the filename (case-insensitive). Empty = any name.") query: String,
    @ToolParam(description = "Album/folder name, e.g. 'Screenshots', 'Camera'. Empty = any album.") album: String,
    @ToolParam(description = "Inclusive start date in yyyy-MM-dd format. Empty = no lower bound.") dateFrom: String,
    @ToolParam(description = "Inclusive end date in yyyy-MM-dd format. Empty = no upper bound.") dateTo: String,
    @ToolParam(description = "Maximum number of photos to return") maxResults: String,
  ): Map<String, Any> {
    val max = maxResults.toIntOrNull() ?: 20
    return runBlocking(Dispatchers.Default) {
      deviceSkills.searchPhotos(query, album, dateFrom, dateTo, max)
    }
  }

  @Tool(description = "Scan barcodes or QR codes from a photo in the device gallery. Returns the decoded text values.")
  fun scanBarcode(
    @ToolParam(description = "URI of the photo to scan (from listPhotos or searchPhotos). Empty = scan the most recent photo.") photoUri: String,
  ): Map<String, Any> {
    return runBlocking(Dispatchers.Default) { deviceSkills.scanBarcode(photoUri) }
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


  @Tool(description = "Get the device's current GPS location with address")
  fun getLocation(): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.getLocation() }
  }

  @Tool(description = "Open a URL in the device's browser")
  fun openUrl(
    @ToolParam(description = "The URL to open") url: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.openUrl(url) }
  }

  @Tool(description = "Search the web and return text results with titles, URLs, and snippets")
  fun searchWeb(
    @ToolParam(description = "The search query") query: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.webSearch(query) }
  }

  @Tool(description = "Fetch the text content of a web page at a URL and return it")
  fun fetchWebContent(
    @ToolParam(description = "The full URL to fetch, e.g. https://example.com") url: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.fetchWebContent(url) }
  }

  @Tool(description = "Evaluate a math expression and return the exact result. Supports +, -, *, /, %, ^, parentheses, sqrt, abs, sin, cos, tan, log, ln, round, ceil, floor, pi, e.")
  fun calculate(
    @ToolParam(description = "The math expression to evaluate, e.g. '(47.83 * 0.15) + 2'") expression: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.calculate(expression) }
  }

  @Tool(description = "Read the current text content from the device clipboard")
  fun getClipboard(): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.getClipboard() }
  }

  @Tool(description = "Copy text to the device clipboard")
  fun setClipboard(
    @ToolParam(description = "The text to copy to clipboard") text: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.setClipboard(text) }
  }

  @Tool(description = "Get device information including battery level, storage, connectivity, and hardware details")
  fun getDeviceInfo(): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.getDeviceInfo() }
  }

  @Tool(description = "Share text content to other apps via the Android share sheet")
  fun shareContent(
    @ToolParam(description = "The text content to share") text: String,
    @ToolParam(description = "Subject line for the share, use empty string if none") subject: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.shareContent(text, subject) }
  }

  @Tool(description = "Turn the device flashlight on or off")
  fun toggleFlashlight(
    @ToolParam(description = "true to turn on, false to turn off") turnOn: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.toggleFlashlight(turnOn.toBoolean()) }
  }

  @Tool(description = "Set the device volume for a specific audio stream")
  fun setVolume(
    @ToolParam(description = "Audio stream: media, ring, alarm, or notification") streamType: String,
    @ToolParam(description = "Volume level as percentage 0-100") volumePercent: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) {
      deviceSkills.setVolume(streamType, volumePercent.toIntOrNull() ?: 50)
    }
  }

  @Tool(description = "Enable or disable Do Not Disturb mode")
  fun setDoNotDisturb(
    @ToolParam(description = "true to enable DnD, false to disable") enable: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.setDoNotDisturb(enable.toBoolean()) }
  }

  @Tool(description = "Open the camera to take a photo")
  fun takePhoto(): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.takePhoto() }
  }

  @Tool(description = "List files in the device Downloads folder")
  fun listDownloads(
    @ToolParam(description = "Maximum number of files to return") maxResults: String,
  ): Map<String, Any> {
    return runBlocking(Dispatchers.Default) { deviceSkills.listDownloads(maxResults.toIntOrNull() ?: 20) }
  }

  @Tool(description = "Open a specific Android settings page")
  fun openSettings(
    @ToolParam(description = "Settings page: wifi, bluetooth, display, sound, battery, location, security, apps, notifications, accessibility, date, language, developer, or general") settingsPage: String,
  ): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.openSettings(settingsPage) }
  }


  @Tool(description = "Check if the device has an active internet connection and what type (WiFi, cellular, etc)")
  fun checkInternet(): Map<String, String> {
    return runBlocking(Dispatchers.Default) { deviceSkills.checkInternet() }
  }
}

fun getSkillSecretKey(skillName: String): String {
  return "skill___${skillName}"
}
