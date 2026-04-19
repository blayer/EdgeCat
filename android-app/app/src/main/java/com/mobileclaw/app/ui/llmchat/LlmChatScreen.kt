/*
 * Copyright 2025 Google LLC
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

package com.mobileclaw.app.ui.llmchat

import androidx.hilt.navigation.compose.hiltViewModel

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.os.bundleOf
import com.mobileclaw.app.MobileClawEvent
import com.mobileclaw.app.R
import com.mobileclaw.app.data.BuiltInTaskId
import com.mobileclaw.app.data.Model
import com.mobileclaw.app.data.RuntimeType
import com.mobileclaw.app.data.Task
import com.mobileclaw.app.firebaseAnalytics
import com.mobileclaw.app.ui.common.chat.ChatMessage
import com.mobileclaw.app.ui.common.chat.ChatMessageAudioClip
import com.mobileclaw.app.ui.common.chat.ChatMessageImage
import com.mobileclaw.app.ui.common.chat.ChatMessageText
import com.mobileclaw.app.ui.common.chat.ChatSide
import com.mobileclaw.app.ui.common.chat.ChatView
import com.mobileclaw.app.ui.common.chat.SendMessageTrigger
import com.mobileclaw.app.ui.modelmanager.ModelManagerViewModel
import com.mobileclaw.app.ui.theme.emptyStateContent
import com.mobileclaw.app.ui.theme.emptyStateTitle

private const val TAG = "AGLlmChatScreen"

@Composable
fun LlmChatScreen(
  modelManagerViewModel: ModelManagerViewModel,
  navigateUp: () -> Unit,
  modifier: Modifier = Modifier,
  taskId: String = BuiltInTaskId.LLM_CHAT,
  onFirstToken: (Model) -> Unit = {},
  onGenerateResponseDone: (Model) -> Unit = {},
  onSkillClicked: () -> Unit = {},
  onResetSessionClickedOverride: ((Task, Model) -> Unit)? = null,
  composableBelowMessageList: @Composable (Model) -> Unit = {},
  viewModel: LlmChatViewModel = hiltViewModel(),
  allowEditingSystemPrompt: Boolean = false,
  curSystemPrompt: String = "",
  onSystemPromptChanged: (String) -> Unit = {},
  emptyStateComposable: @Composable (Model) -> Unit = {},
  sendMessageTrigger: SendMessageTrigger? = null,
  showImagePicker: Boolean = false,
  showAudioPicker: Boolean = false,
  onSendMessageOverride: ((Model, List<ChatMessage>) -> Boolean)? = null,
  showAgentSettingsTab: Boolean = false,
  agenticModeEnabled: Boolean = true,
  agentTracesEnabled: Boolean = true,
  onAgenticModeChanged: (Boolean) -> Unit = {},
  onAgentTracesChanged: (Boolean) -> Unit = {},
  onClearMemory: (() -> Unit)? = null,
  agentMaxLoops: Int = 3,
  agentMaxRepairAttempts: Int = 2,
  agentSkillTimeoutSecs: Int = 60,
  onAgentMaxLoopsChanged: (Int) -> Unit = {},
  onAgentMaxRepairAttemptsChanged: (Int) -> Unit = {},
  onAgentSkillTimeoutSecsChanged: (Int) -> Unit = {},
  agentThinkingMode: Int = 0,
  onAgentThinkingModeChanged: (Int) -> Unit = {},
  userPortrait: String = "",
  onUserPortraitChanged: (String) -> Unit = {},
  agentHistoryWindowSize: Int = 6,
  onAgentHistoryWindowSizeChanged: (Int) -> Unit = {},
) {
  ChatViewWrapper(
    viewModel = viewModel,
    modelManagerViewModel = modelManagerViewModel,
    taskId = taskId,
    navigateUp = navigateUp,
    modifier = modifier,
    onSkillClicked = onSkillClicked,
    onFirstToken = onFirstToken,
    onGenerateResponseDone = onGenerateResponseDone,
    onResetSessionClickedOverride = onResetSessionClickedOverride,
    composableBelowMessageList = composableBelowMessageList,
    allowEditingSystemPrompt = allowEditingSystemPrompt,
    curSystemPrompt = curSystemPrompt,
    onSystemPromptChanged = onSystemPromptChanged,
    emptyStateComposable = emptyStateComposable,
    sendMessageTrigger = sendMessageTrigger,
    showImagePicker = showImagePicker,
    showAudioPicker = showAudioPicker,
    onSendMessageOverride = onSendMessageOverride,
    showAgentSettingsTab = showAgentSettingsTab,
    agenticModeEnabled = agenticModeEnabled,
    agentTracesEnabled = agentTracesEnabled,
    onAgenticModeChanged = onAgenticModeChanged,
    onAgentTracesChanged = onAgentTracesChanged,
    onClearMemory = onClearMemory,
    agentMaxLoops = agentMaxLoops,
    agentMaxRepairAttempts = agentMaxRepairAttempts,
    agentSkillTimeoutSecs = agentSkillTimeoutSecs,
    onAgentMaxLoopsChanged = onAgentMaxLoopsChanged,
    onAgentMaxRepairAttemptsChanged = onAgentMaxRepairAttemptsChanged,
    onAgentSkillTimeoutSecsChanged = onAgentSkillTimeoutSecsChanged,
    agentThinkingMode = agentThinkingMode,
    onAgentThinkingModeChanged = onAgentThinkingModeChanged,
    userPortrait = userPortrait,
    onUserPortraitChanged = onUserPortraitChanged,
    agentHistoryWindowSize = agentHistoryWindowSize,
    onAgentHistoryWindowSizeChanged = onAgentHistoryWindowSizeChanged,
  )
}

@Composable
fun LlmAskImageScreen(
  modelManagerViewModel: ModelManagerViewModel,
  navigateUp: () -> Unit,
  modifier: Modifier = Modifier,
  viewModel: LlmAskImageViewModel = hiltViewModel(),
) {
  ChatViewWrapper(
    viewModel = viewModel,
    modelManagerViewModel = modelManagerViewModel,
    taskId = BuiltInTaskId.LLM_ASK_IMAGE,
    navigateUp = navigateUp,
    modifier = modifier,
    showImagePicker = true,
    showAudioPicker = false,
    emptyStateComposable = { model ->
      Box(modifier = Modifier.fillMaxSize()) {
        Column(
          modifier =
            Modifier.align(Alignment.Center).padding(horizontal = 48.dp).padding(bottom = 48.dp),
          horizontalAlignment = Alignment.CenterHorizontally,
          verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
          Text(stringResource(R.string.askimage_emptystate_title), style = emptyStateTitle)
          var contentRes = R.string.askimage_emptystate_content
          Text(
            stringResource(contentRes),
            style = emptyStateContent,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
          )
        }
      }
    },
  )
}

@Composable
fun LlmAskAudioScreen(
  modelManagerViewModel: ModelManagerViewModel,
  navigateUp: () -> Unit,
  modifier: Modifier = Modifier,
  viewModel: LlmAskAudioViewModel = hiltViewModel(),
) {
  ChatViewWrapper(
    viewModel = viewModel,
    modelManagerViewModel = modelManagerViewModel,
    taskId = BuiltInTaskId.LLM_ASK_AUDIO,
    navigateUp = navigateUp,
    modifier = modifier,
    showImagePicker = false,
    showAudioPicker = true,
    emptyStateComposable = {
      Box(modifier = Modifier.fillMaxSize()) {
        Column(
          modifier =
            Modifier.align(Alignment.Center).padding(horizontal = 48.dp).padding(bottom = 48.dp),
          horizontalAlignment = Alignment.CenterHorizontally,
          verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
          Text(stringResource(R.string.askaudio_emptystate_title), style = emptyStateTitle)
          Text(
            stringResource(R.string.askaudio_emptystate_content),
            style = emptyStateContent,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
          )
        }
      }
    },
  )
}

@Composable
fun ChatViewWrapper(
  viewModel: LlmChatViewModelBase,
  modelManagerViewModel: ModelManagerViewModel,
  taskId: String,
  navigateUp: () -> Unit,
  modifier: Modifier = Modifier,
  onSkillClicked: () -> Unit = {},
  onFirstToken: (Model) -> Unit = {},
  onGenerateResponseDone: (Model) -> Unit = {},
  onResetSessionClickedOverride: ((Task, Model) -> Unit)? = null,
  composableBelowMessageList: @Composable (Model) -> Unit = {},
  emptyStateComposable: @Composable (Model) -> Unit = {},
  allowEditingSystemPrompt: Boolean = false,
  curSystemPrompt: String = "",
  onSystemPromptChanged: (String) -> Unit = {},
  sendMessageTrigger: SendMessageTrigger? = null,
  showImagePicker: Boolean = false,
  showAudioPicker: Boolean = false,
  onSendMessageOverride: ((Model, List<ChatMessage>) -> Boolean)? = null,
  showAgentSettingsTab: Boolean = false,
  agenticModeEnabled: Boolean = true,
  agentTracesEnabled: Boolean = true,
  onAgenticModeChanged: (Boolean) -> Unit = {},
  onAgentTracesChanged: (Boolean) -> Unit = {},
  onClearMemory: (() -> Unit)? = null,
  agentMaxLoops: Int = 3,
  agentMaxRepairAttempts: Int = 2,
  agentSkillTimeoutSecs: Int = 60,
  onAgentMaxLoopsChanged: (Int) -> Unit = {},
  onAgentMaxRepairAttemptsChanged: (Int) -> Unit = {},
  onAgentSkillTimeoutSecsChanged: (Int) -> Unit = {},
  agentThinkingMode: Int = 0,
  onAgentThinkingModeChanged: (Int) -> Unit = {},
  userPortrait: String = "",
  onUserPortraitChanged: (String) -> Unit = {},
  agentHistoryWindowSize: Int = 6,
  onAgentHistoryWindowSizeChanged: (Int) -> Unit = {},
) {
  val context = LocalContext.current
  val task = modelManagerViewModel.getTaskById(id = taskId)!!
  val allowThinking = task.allowThinking()

  ChatView(
    task = task,
    viewModel = viewModel,
    modelManagerViewModel = modelManagerViewModel,
    onSendMessage = { model, messages ->
      // If the override handles the message, skip default processing.
      val handled = onSendMessageOverride != null && onSendMessageOverride(model, messages)

      if (!handled) {
        for (message in messages) {
          viewModel.addMessage(model = model, message = message)
          if (message is ChatMessageText && message.side == ChatSide.USER) {
            viewModel.persistUserMessage(message.content)
          }
        }

        var text = ""
        val images: MutableList<Bitmap> = mutableListOf()
        val audioMessages: MutableList<ChatMessageAudioClip> = mutableListOf()
        var chatMessageText: ChatMessageText? = null
        for (message in messages) {
          if (message is ChatMessageText) {
            chatMessageText = message
            text = message.content
          } else if (message is ChatMessageImage) {
            images.addAll(message.bitmaps)
          } else if (message is ChatMessageAudioClip) {
            audioMessages.add(message)
          }
        }
        if ((text.isNotEmpty() && chatMessageText != null) || audioMessages.isNotEmpty()) {
          if (text.isNotEmpty()) {
            modelManagerViewModel.addTextInputHistory(text)
          }
          viewModel.generateResponse(
            model = model,
            input = text,
            images = images,
            audioMessages = audioMessages,
            onFirstToken = onFirstToken,
            onDone = { onGenerateResponseDone(model) },
            onError = { errorMessage ->
              viewModel.handleError(
                context = context,
                task = task,
                model = model,
                errorMessage = errorMessage,
                modelManagerViewModel = modelManagerViewModel,
              )
            },
            allowThinking = allowThinking,
          )

          firebaseAnalytics?.logEvent(
            MobileClawEvent.GENERATE_ACTION.id,
            bundleOf("capability_name" to task.id, "model_id" to model.name),
          )
        }
      }
    },
    onRunAgainClicked = { model, message ->
      if (message is ChatMessageText) {
        viewModel.runAgain(
          model = model,
          message = message,
          onError = { errorMessage ->
            viewModel.handleError(
              context = context,
              task = task,
              model = model,
              errorMessage = errorMessage,
              modelManagerViewModel = modelManagerViewModel,
            )
          },
          allowThinking = allowThinking,
        )
      }
    },
    onBenchmarkClicked = { _, _, _, _ -> },
    onResetSessionClicked = { model ->
      if (onResetSessionClickedOverride != null) {
        onResetSessionClickedOverride(task, model)
      } else {
        viewModel.resetSession(
          task = task,
          model = model,
          supportImage = showImagePicker,
          supportAudio = showAudioPicker,
        )
      }
    },
    showStopButtonInInputWhenInProgress = true,
    onStopButtonClicked = { model -> viewModel.stopResponse(model = model) },
    onSkillClicked = onSkillClicked,
    navigateUp = navigateUp,
    modifier = modifier,
    composableBelowMessageList = composableBelowMessageList,
    showImagePicker = showImagePicker,
    emptyStateComposable = emptyStateComposable,
    allowEditingSystemPrompt = allowEditingSystemPrompt,
    curSystemPrompt = curSystemPrompt,
    onSystemPromptChanged = onSystemPromptChanged,
    sendMessageTrigger = sendMessageTrigger,
    showAudioPicker = showAudioPicker,
    showAgentSettingsTab = showAgentSettingsTab,
    agenticModeEnabled = agenticModeEnabled,
    agentTracesEnabled = agentTracesEnabled,
    onAgenticModeChanged = onAgenticModeChanged,
    onAgentTracesChanged = onAgentTracesChanged,
    onClearMemory = onClearMemory,
    agentMaxLoops = agentMaxLoops,
    agentMaxRepairAttempts = agentMaxRepairAttempts,
    agentSkillTimeoutSecs = agentSkillTimeoutSecs,
    onAgentMaxLoopsChanged = onAgentMaxLoopsChanged,
    onAgentMaxRepairAttemptsChanged = onAgentMaxRepairAttemptsChanged,
    onAgentSkillTimeoutSecsChanged = onAgentSkillTimeoutSecsChanged,
    agentThinkingMode = agentThinkingMode,
    onAgentThinkingModeChanged = onAgentThinkingModeChanged,
    userPortrait = userPortrait,
    onUserPortraitChanged = onUserPortraitChanged,
    agentHistoryWindowSize = agentHistoryWindowSize,
    onAgentHistoryWindowSizeChanged = onAgentHistoryWindowSizeChanged,
  )
}
