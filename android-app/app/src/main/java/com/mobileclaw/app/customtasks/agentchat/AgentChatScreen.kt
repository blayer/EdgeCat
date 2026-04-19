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
import android.os.Bundle
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.mobileclaw.app.MobileClawEvent
import com.mobileclaw.app.R
import com.mobileclaw.app.common.AskInfoAgentAction
import com.mobileclaw.app.common.CallJsAgentAction
import com.mobileclaw.app.common.RequestPermissionAgentAction
import androidx.activity.compose.rememberLauncherForActivityResult
import com.mobileclaw.app.common.SkillProgressAgentAction
import com.mobileclaw.app.data.BuiltInTaskId
import com.mobileclaw.app.data.Model
import com.mobileclaw.app.data.Task
import com.mobileclaw.app.firebaseAnalytics
import com.mobileclaw.app.ui.common.BaseMobileClawWebViewClient
import com.mobileclaw.app.ui.common.MobileClawWebView
import com.mobileclaw.app.ui.common.buildTrackableUrlAnnotatedString
import com.mobileclaw.app.memory.MemoryRepository
import com.mobileclaw.app.orchestration.ExecutionPlan
import com.mobileclaw.app.orchestration.OrchestrationController
import com.mobileclaw.app.orchestration.OrchestrationStatus
import com.mobileclaw.app.orchestration.SkillCreator
import com.mobileclaw.app.orchestration.StepResult
import com.mobileclaw.app.orchestration.StepStatus
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import com.mobileclaw.app.ui.common.chat.ChatMessage
import com.mobileclaw.app.ui.common.chat.ChatMessageCollapsableProgressPanel
import com.mobileclaw.app.ui.common.chat.ChatMessageImage
import com.mobileclaw.app.ui.common.chat.ChatMessageInfo
import com.mobileclaw.app.ui.common.chat.ChatMessageOrchestrationLog
import com.mobileclaw.app.ui.common.chat.ChatMessageText
import com.mobileclaw.app.ui.common.chat.ChatMessageType
import com.mobileclaw.app.ui.common.chat.ChatMessageWebView
import com.mobileclaw.app.ui.common.chat.ChatSide
import com.mobileclaw.app.ui.common.chat.LogMessage
import com.mobileclaw.app.ui.common.chat.LogMessageLevel
import com.mobileclaw.app.ui.common.chat.SendMessageTrigger
import com.mobileclaw.app.ui.llmchat.LlmChatScreen
import com.mobileclaw.app.ui.llmchat.LlmChatViewModel
import com.mobileclaw.app.ui.modelmanager.ModelInitializationStatusType
import com.mobileclaw.app.ui.modelmanager.ModelManagerViewModel
import com.google.ai.edge.litertlm.tool
import java.lang.Exception
import kotlin.coroutines.resume
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

private const val TAG = "AGAgentChatScreen"
private val chatViewJavascriptInterface = ChatWebViewJavascriptInterface()

@EntryPoint
@InstallIn(SingletonComponent::class)
interface MemoryEntryPoint {
  fun memoryRepository(): MemoryRepository
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AgentChatScreen(
  task: Task,
  modelManagerViewModel: ModelManagerViewModel,
  navigateUp: () -> Unit,
  agentTools: AgentTools,
  conversationId: Long? = null,
  viewModel: LlmChatViewModel = hiltViewModel(),
  skillManagerViewModel: SkillManagerViewModel = hiltViewModel(),
) {
  // Load persisted conversation history once per conversation id.
  LaunchedEffect(conversationId, modelManagerViewModel.getSelectedModel()?.name) {
    val currentModel = modelManagerViewModel.getSelectedModel()
    if (conversationId != null && currentModel != null && currentModel.name != "empty") {
      viewModel.loadConversation(model = currentModel, id = conversationId)
    } else {
      viewModel.currentConversationId = conversationId
    }
  }
  val context = LocalContext.current
  agentTools.context = context
  agentTools.skillManagerViewModel = skillManagerViewModel
  val density = LocalDensity.current
  val windowInfo = LocalWindowInfo.current
  val screenWidthDp = remember { with(density) { windowInfo.containerSize.width.toDp() } }
  var showSkillManagerBottomSheet by remember { mutableStateOf(false) }
  var showAskInfoDialog by remember { mutableStateOf(false) }
  var currentAskInfoAction by remember { mutableStateOf<AskInfoAgentAction?>(null) }
  var askInfoInputValue by remember { mutableStateOf("") }
  var webViewRef: WebView? by remember { mutableStateOf(null) }
  val chatWebViewClient = remember { ChatWebViewClient(context = context) }
  var curSystemPrompt by remember { mutableStateOf(task.defaultSystemPrompt) }
  val systemPromptUpdatedMessage = stringResource(R.string.system_prompt_updated)
  var sendMessageTrigger by remember { mutableStateOf<SendMessageTrigger?>(null) }
  val dataStoreRepo = skillManagerViewModel.dataStoreRepository
  var orchestrationEnabled by remember { mutableStateOf(dataStoreRepo.isAgenticModeEnabled()) }
  var agentTracesEnabled by remember { mutableStateOf(dataStoreRepo.isAgentTracesEnabled()) }
  var agentMaxLoops by remember { mutableStateOf(dataStoreRepo.getAgentMaxLoops()) }
  var agentMaxRepairAttempts by remember { mutableStateOf(dataStoreRepo.getAgentMaxRepairAttempts()) }
  var agentSkillTimeoutSecs by remember { mutableStateOf(dataStoreRepo.getAgentSkillTimeoutSecs()) }
  var agentThinkingMode by remember { mutableStateOf(dataStoreRepo.getAgentThinkingMode()) }
  var userPortrait by remember { mutableStateOf(dataStoreRepo.getUserPortrait()) }
  var agentHistoryWindowSize by remember { mutableStateOf(dataStoreRepo.getAgentHistoryWindowSize()) }
  val coroutineScope = androidx.compose.runtime.rememberCoroutineScope()

  // Save-as-skill state.
  var showSaveAsSkillDialog by remember { mutableStateOf(false) }
  var saveAsSkillName by remember { mutableStateOf("") }
  var lastOrchestrationUserMessage by remember { mutableStateOf("") }
  var lastOrchestrationPlan by remember { mutableStateOf<ExecutionPlan?>(null) }
  var lastOrchestrationResults by remember { mutableStateOf<Map<String, StepResult>>(emptyMap()) }
  var saveAsSkillLoading by remember { mutableStateOf(false) }
  val skillCreator = remember { SkillCreator() }

  // Permission request handling for device skills.
  var pendingPermissionAction by remember { mutableStateOf<RequestPermissionAgentAction?>(null) }
  val permissionLauncher = rememberLauncherForActivityResult(
    contract = androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions(),
  ) { grants ->
    val allGranted = grants.values.all { it }
    pendingPermissionAction?.result?.complete(allGranted)
    pendingPermissionAction = null
  }

  // Orchestration controller — created lazily when the selected model is available.
  val orchestrationController = remember {
    mutableStateOf<OrchestrationController?>(null)
  }

  // Observe orchestration state and render plan/evaluation messages.
  val orchState by orchestrationController.value?.state?.collectAsState()
    ?: remember { mutableStateOf(null) }.let {
      @Suppress("UNCHECKED_CAST")
      it as androidx.compose.runtime.State<com.mobileclaw.app.orchestration.OrchestrationState?>
    }

  LlmChatScreen(
    modelManagerViewModel = modelManagerViewModel,
    taskId = BuiltInTaskId.LLM_AGENT_CHAT,
    navigateUp = navigateUp,
    onFirstToken = { model ->
      updateProgressPanel(viewModel = viewModel, model = model, agentTools = agentTools)
    },
    onGenerateResponseDone = { model ->
      // Show any image produced by tools.
      agentTools.resultImageToShow?.let { resultImage ->
        resultImage.base64?.let { base64 ->
          decodeBase64ToBitmap(base64String = base64)?.let { bitmap ->
            viewModel.addMessage(
              model = model,
              message =
                ChatMessageImage(
                  bitmaps = listOf(bitmap),
                  imageBitMaps = listOf(bitmap.asImageBitmap()),
                  side = ChatSide.AGENT,
                  maxSize = (screenWidthDp.value * 0.8).toInt(),
                  latencyMs = -1.0f,
                  hideSenderLabel = true,
                ),
            )
          }
        }
        // Clean up.
        agentTools.resultImageToShow = null
      }

      // Show any webview produced by tools.
      agentTools.resultWebviewToShow?.let { webview ->
        val url = webview.url ?: ""
        val iframe = webview.iframe == true
        val aspectRatio = webview.aspectRatio ?: 1.333f
        viewModel.addMessage(
          model = model,
          message =
            ChatMessageWebView(
              url = url,
              iframe = iframe,
              aspectRatio = aspectRatio,
              hideSenderLabel = true,
            ),
        )
        // Clean up.
        agentTools.resultWebviewToShow = null
      }

      updateProgressPanel(viewModel = viewModel, model = model, agentTools = agentTools)
    },
    onResetSessionClickedOverride = { task, model ->
      resetSessionWithCurrentSkills(
        viewModel,
        modelManagerViewModel,
        skillManagerViewModel,
        task,
        curSystemPrompt,
        agentTools,
        agenticModeEnabled = orchestrationEnabled,
      )
    },
    onSkillClicked = { showSkillManagerBottomSheet = true },
    showImagePicker = true,
    showAudioPicker = true,
    composableBelowMessageList = { model ->
      val actionChannel = agentTools.actionChannel
      val doneIcon = ImageVector.vectorResource(R.drawable.skill)
      // Use rememberUpdatedState to ensure that LaunchedEffect captures the
      // latest active model when the model is switched during an ongoing skill execution.
      val currentModel by androidx.compose.runtime.rememberUpdatedState(model)
      LaunchedEffect(actionChannel) {
        for (action in actionChannel) {
          Log.d(TAG, "Handling action: $action")
          when (action) {
            is SkillProgressAgentAction -> {
              // During orchestration, skip individual tool progress panels —
              // progress is shown in the consolidated log bubble.
              if (!orchestrationEnabled || orchestrationController.value == null) {
                viewModel.updateCollapsableProgressPanelMessage(
                  model = currentModel,
                  title = action.label,
                  inProgress = action.inProgress,
                  doneIcon = doneIcon,
                  addItemTitle = action.addItemTitle,
                  addItemDescription = action.addItemDescription,
                  customData = action.customData,
                )
              }
            }
            is CallJsAgentAction -> {
              try {
                // Set up a safety net timeout so we NEVER hang the chat or tool execution
                launch {
                  delay(agentSkillTimeoutSecs * 1000L)
                  if (!action.result.isCompleted) {
                    Log.e(TAG, "JS Execution timed out, completing with error.")
                    action.result.complete(
                      "{\"error\": \"Skill execution timed out. Please check network connection.\"}"
                    )
                  }
                }

                // Load url.
                suspendCancellableCoroutine<Unit> { continuation ->
                  chatWebViewClient.setPageLoadListener {
                    chatWebViewClient.setPageLoadListener(null)
                    continuation.resume(Unit)
                  }
                  Log.d(TAG, "Loading url: ${action.url}")
                  webViewRef?.loadUrl(action.url)
                }

                // Execute JS.
                Log.d(TAG, "Start to run js")
                chatViewJavascriptInterface.onResultListener = { result ->
                  Log.d(TAG, "Got result:\n$result")
                  action.result.complete(result)
                }

                // Escape data for safe embedding in JS. Use JSON.stringify to
                // produce a valid JS string literal (handles backticks, quotes,
                // newlines, and special chars like °C that break template literals).
                val safeData = org.json.JSONObject.quote(action.data)
                val safeSecret = org.json.JSONObject.quote(action.secret)
                val script =
                  """
                  (async function() {
                      var startTs = Date.now();
                      while(true) {
                        if (typeof ai_edge_gallery_get_result === 'function') {
                          break;
                        }
                        await new Promise(resolve=>{
                          setTimeout(resolve, 100)
                        });
                        if (Date.now() - startTs > 10000) {
                          break;
                        }
                      }
                      var result = await ai_edge_gallery_get_result($safeData, $safeSecret);
                      MobileClaw.onResultReady(result);
                  })()
                  """
                    .trimIndent()
                webViewRef?.evaluateJavascript(script, null)
              } catch (e: Exception) {
                action.result.completeExceptionally(e)
              }
            }
            is AskInfoAgentAction -> {
              currentAskInfoAction = action
              askInfoInputValue = "" // Reset input
              showAskInfoDialog = true
            }
            is RequestPermissionAgentAction -> {
              // Request runtime permissions and complete the deferred.
              pendingPermissionAction = action
              permissionLauncher.launch(action.permissions.toTypedArray())
            }
          }
        }
      }

      MobileClawWebView(
        modifier = Modifier.size(300.dp),
        onWebViewCreated = { webView ->
          webViewRef = webView
          webView.addJavascriptInterface(chatViewJavascriptInterface, "MobileClaw")
        },
        customWebViewClient = chatWebViewClient,
        onConsoleMessage = { consoleMessage ->
          consoleMessage?.let { curConsoleMessage ->
            // Create a LogMessage from the ConsoleMessage and add it to the progress panel.
            val logMessage =
              LogMessage(
                level =
                  when (curConsoleMessage.messageLevel()) {
                    ConsoleMessage.MessageLevel.LOG -> LogMessageLevel.Info
                    ConsoleMessage.MessageLevel.ERROR -> LogMessageLevel.Error
                    ConsoleMessage.MessageLevel.WARNING -> LogMessageLevel.Warning
                    else -> LogMessageLevel.Info
                  },
                source = curConsoleMessage.sourceId(),
                lineNumber = curConsoleMessage.lineNumber(),
                message = curConsoleMessage.message(),
              )
            if (!orchestrationEnabled || orchestrationController.value == null) {
              viewModel.addLogMessageToLastCollapsableProgressPanel(
                model = model,
                logMessage = logMessage,
              )
            }
            Log.d(
              TAG,
              "${curConsoleMessage.message()} " +
                "-- From line ${curConsoleMessage.lineNumber()} of ${curConsoleMessage.sourceId()}",
            )
          }
        },
      )
    },
    allowEditingSystemPrompt = true,
    curSystemPrompt = curSystemPrompt,
    onSystemPromptChanged = { newPrompt ->
      curSystemPrompt = newPrompt
      resetSessionWithCurrentSkills(
        viewModel,
        modelManagerViewModel,
        skillManagerViewModel,
        task,
        curSystemPrompt,
        agentTools,
        onDone = { model ->
          viewModel.addMessage(
            model = model,
            message = ChatMessageInfo(content = systemPromptUpdatedMessage),
          )
        },
        agenticModeEnabled = orchestrationEnabled,
      )
    },
    emptyStateComposable = { model ->
      val uiState by viewModel.uiState.collectAsState()
      val modelManagerUiState by modelManagerViewModel.uiState.collectAsState()
      val modelInitializationStatus = modelManagerUiState.modelInitializationStatus[model.name]
      Box(modifier = Modifier.fillMaxSize()) {
        AnimatedVisibility(
          !WindowInsets.isImeVisible,
          enter = fadeIn(animationSpec = tween(200)),
          exit = fadeOut(animationSpec = tween(200)),
        ) {
          Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(
              modifier =
                Modifier.align(Alignment.Center)
                  .padding(horizontal = 48.dp)
                  .padding(bottom = 48.dp),
              horizontalAlignment = Alignment.CenterHorizontally,
            ) {
              Text(
                "Your",
                style = MaterialTheme.typography.headlineSmall,
              )
              Text(
                stringResource(R.string.agent_skills),
                style =
                  MaterialTheme.typography.headlineLarge.copy(
                    fontWeight = FontWeight.Medium,
                    brush =
                      Brush.linearGradient(colors = listOf(Color(0xFF85B1F8), Color(0xFF3174F1))),
                  ),
                modifier = Modifier.padding(top = 12.dp, bottom = 16.dp),
              )
              Text(
                stringResource(R.string.agent_skills_description),
                style =
                  MaterialTheme.typography.headlineSmall.copy(fontSize = 16.sp, lineHeight = 22.sp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
              )
            }
          }
        }

      }
    },
    sendMessageTrigger = sendMessageTrigger,
    onSendMessageOverride = { model, messages ->
      android.util.Log.d("AGOrchOverride", "onSendMessageOverride called. orchestrationEnabled=$orchestrationEnabled, messages=${messages.size}")
      if (!orchestrationEnabled) {
        android.util.Log.d("AGOrchOverride", "Orchestration disabled, returning false")
        false // Let default handler process the message.
      } else {
        // Extract text from the messages.
        val text = messages.filterIsInstance<ChatMessageText>().firstOrNull()?.content ?: ""
        android.util.Log.d("AGOrchOverride", "Extracted text: '$text'")
        if (text.isBlank()) {
          android.util.Log.d("AGOrchOverride", "Text is blank, returning false")
          false // Nothing to orchestrate.
        } else if (text.lowercase().startsWith("save as skill") || text.lowercase().startsWith("save skill")) {
          // Handle "save as skill <name>" command.
          for (message in messages) {
            viewModel.addMessage(model = model, message = message)
          }
          val plan = lastOrchestrationPlan
          val results = lastOrchestrationResults
          val userMsg = lastOrchestrationUserMessage
          if (plan == null || plan.steps.isEmpty()) {
            viewModel.addMessage(model = model, message = ChatMessageInfo(content = "No completed workflow to save. Run a multi-step command first."))
          } else {
            // Extract skill name from the message.
            val nameFromMsg = text
              .replace(Regex("^save\\s+(as\\s+)?skill\\s*", RegexOption.IGNORE_CASE), "")
              .trim()
              .replace("\\s+".toRegex(), "-")
              .replace(Regex("[^a-zA-Z0-9-]"), "")
              .lowercase()
              .ifEmpty { "my-workflow" }

            viewModel.addMessage(model = model, message = ChatMessageInfo(content = "Generating skill \"$nameFromMsg\"..."))

            coroutineScope.launch(kotlinx.coroutines.Dispatchers.Default) {
              try {
                val llmProvider = LlmInferenceProviderImpl(viewModel) { model }
                val prompt = skillCreator.buildSkillCreationPrompt(nameFromMsg, userMsg, plan, results)
                val policy = com.mobileclaw.app.orchestration.ThinkingPolicy(
                  com.mobileclaw.app.orchestration.ThinkingMode.fromInt(agentThinkingMode)
                )
                val llmOutput = llmProvider.generateResponse(
                  prompt,
                  enableThinking = policy.saveAsSkill(),
                )
                val skillMd = skillCreator.parseSkillMd(llmOutput)
                android.util.Log.d(TAG, "Generated SKILL.md:\n$skillMd")

                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                  skillManagerViewModel.createSkillFromOrchestration(
                    skillMdContent = skillMd,
                    onSuccess = { name ->
                      viewModel.addMessage(model = model, message = ChatMessageText(
                        content = "Skill \"$name\" saved! You can now use it by saying: \"run $name\" or reference it in future requests.",
                        side = ChatSide.AGENT,
                      ))
                    },
                    onError = { error ->
                      viewModel.addMessage(model = model, message = ChatMessageInfo(content = "Failed to save skill: $error"))
                    },
                  )
                }
              } catch (e: Exception) {
                android.util.Log.e(TAG, "Failed to generate skill", e)
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                  viewModel.addMessage(model = model, message = ChatMessageInfo(content = "Failed to generate skill: ${e.message}"))
                }
              }
            }
          }
          true // Handled.
        } else {
          // Classify intent: is this a task or casual chat?
          val planner = com.mobileclaw.app.orchestration.Planner()
          val hasPriorAssistantTurn =
            viewModel.uiState.value.messagesByModel[model.name]
              ?.any { it is ChatMessageText && it.side == ChatSide.AGENT }
              ?: false
          val intentResult = planner.classifyIntent(text, hasPriorAssistantTurn)
          android.util.Log.d("AGOrchOverride", "Intent classification: '$intentResult' for: '$text'")

          if (intentResult == "chat") {
            // Casual conversation — respond directly with thinking disabled to avoid
            // showing model chain-of-thought for simple follow-ups.
            android.util.Log.d("AGOrchOverride", "Chat intent, responding without thinking")
            for (message in messages) {
              viewModel.addMessage(model = model, message = message)
              if (message is ChatMessageText && message.side == ChatSide.USER) {
                viewModel.persistUserMessage(message.content)
              }
            }
            viewModel.generateResponse(
              model = model,
              input = text,
              onError = { errorMessage ->
                viewModel.handleError(
                  context = context,
                  task = task,
                  model = model,
                  errorMessage = errorMessage,
                  modelManagerViewModel = modelManagerViewModel,
                )
              },
              allowThinking = false,
            )
            true
          } else {
          android.util.Log.d("AGOrchOverride", "Task intent, starting orchestration for: '$text'")
          // Add user message to chat.
          for (message in messages) {
            viewModel.addMessage(model = model, message = message)
            if (message is ChatMessageText && message.side == ChatSide.USER) {
              viewModel.persistUserMessage(message.content)
            }
          }

          // Create controller.
          val llmProvider = LlmInferenceProviderImpl(viewModel) { model }
          val toolExec = ToolExecutorImpl(agentTools, skillManagerViewModel)
          val memoryRepo = try {
            EntryPointAccessors.fromApplication(context, MemoryEntryPoint::class.java).memoryRepository()
          } catch (e: Exception) { null }
          val controller = OrchestrationController(
            llmProvider,
            toolExec,
            memoryRepo,
            maxIterations = agentMaxLoops,
            maxRepairAttempts = agentMaxRepairAttempts,
            thinkingMode = com.mobileclaw.app.orchestration.ThinkingMode.fromInt(agentThinkingMode),
            userPortraitProvider = { dataStoreRepo.getUserPortrait() },
          )
          orchestrationController.value = controller

          // Observe state changes — single consolidated log bubble.
          coroutineScope.launch {
              var lastStatus: OrchestrationStatus? = null
              var lastPlanIteration = -1
              var lastEvalIteration = -1
              var memoryLogged = false
              val loggedSteps = mutableSetOf<String>()

              // Create the log bubble.
              viewModel.addMessage(
                model = model,
                message = ChatMessageOrchestrationLog(
                  logLines = listOf("\uD83D\uDCA1 Planning..."),
                  inProgress = true,
                ),
              )

              var planningThinkingMarked = false
              // Currently-visible "...ing" line. Resolved to its done form when the phase ends.
              var activeProgressLine: String? = "\uD83D\uDCA1 Planning..."
              fun resolveActive(doneLine: String) {
                val active = activeProgressLine ?: return
                viewModel.replaceOrchestrationLogLine(model, active, doneLine)
                activeProgressLine = null
              }
              fun setActive(line: String) {
                activeProgressLine?.let { prev ->
                  // Previous phase's progress line was never resolved — replace with a neutral done.
                  viewModel.replaceOrchestrationLogLine(model, prev, prev.removeSuffix("...").removeSuffix(" (thinking)"))
                }
                viewModel.appendOrchestrationLogLine(model, line)
                activeProgressLine = line
              }
              controller.state.collect { state ->
              val showTraces = agentTracesEnabled
              fun thinkSuffix(phase: String): String =
                if (state.thinkingByPhase[phase] == true) " (thinking)" else ""

              // Upgrade the initial "Planning..." line once we know if thinking is on.
              if (!planningThinkingMarked && state.thinkingByPhase.containsKey("planning")) {
                planningThinkingMarked = true
                if (state.thinkingByPhase["planning"] == true) {
                  val upgraded = "\uD83D\uDCA1 Planning (thinking)..."
                  viewModel.replaceOrchestrationLogLine(model, "\uD83D\uDCA1 Planning...", upgraded)
                  if (activeProgressLine == "\uD83D\uDCA1 Planning...") activeProgressLine = upgraded
                }
              }

              // Memory recall status.
              if (!memoryLogged && state.memoryRecalled != null) {
                memoryLogged = true
                if (state.memoryRecalled) {
                  viewModel.appendOrchestrationLogLine(model, "\uD83E\uDDE0 Memory recalled")
                } else {
                  viewModel.appendOrchestrationLogLine(model, "\uD83E\uDDE0 No memory found")
                }
              }

              // Plan ready — log the plan steps.
              if (state.plan != null && state.iteration != lastPlanIteration) {
                // Planning/replanning phase finished. Resolve the in-progress line.
                val doneLabel = if (state.iteration <= 1) "\uD83D\uDCA1 Planned" else "\uD83D\uDD04 Re-planned"
                resolveActive(doneLabel)
                lastPlanIteration = state.iteration
                loggedSteps.clear()
                val plan = state.plan!!
                if (showTraces) {
                  val iterLabel = if (state.iteration > 1) " (iteration ${state.iteration})" else ""
                  viewModel.appendOrchestrationLogLine(model, "\uD83D\uDCCB Plan: ${plan.goal}$iterLabel")
                  for ((i, step) in plan.steps.withIndex()) {
                    val skill = if (step.skillName != null) " [${step.skillName}]" else ""
                    viewModel.appendOrchestrationLogLine(model, "   \uD83D\uDD39 ${step.description}$skill")
                  }
                }
              }

              // Step status updates.
              if (state.status == OrchestrationStatus.EXECUTING && state.plan != null) {
                // High-level "Executing..." log when traces are off.
                if (!showTraces && lastStatus != OrchestrationStatus.EXECUTING) {
                  setActive("\u25B6\uFE0F Executing...")
                }
                if (showTraces) {
                  for ((stepId, result) in state.stepResults) {
                    val key = "$stepId:${result.status}"
                    if (key !in loggedSteps) {
                      loggedSteps.add(key)
                      val step = state.plan!!.steps.find { it.id == stepId }
                      val desc = step?.description ?: stepId
                      when (result.status) {
                        com.mobileclaw.app.orchestration.StepStatus.RUNNING -> {
                          val hasTerminal = loggedSteps.contains("$stepId:${com.mobileclaw.app.orchestration.StepStatus.COMPLETED}") ||
                            loggedSteps.contains("$stepId:${com.mobileclaw.app.orchestration.StepStatus.FAILED}")
                          if (!hasTerminal) {
                            viewModel.appendOrchestrationLogLine(model, "\u25B6\uFE0F $desc")
                          }
                        }
                        com.mobileclaw.app.orchestration.StepStatus.COMPLETED -> {
                          val dur = if (result.durationMs > 0) " (${String.format("%.1f", result.durationMs / 1000.0)}s)" else ""
                          viewModel.replaceOrchestrationLogLine(model, "\u25B6\uFE0F $desc", "\u2705 $desc$dur")
                        }
                        com.mobileclaw.app.orchestration.StepStatus.FAILED -> {
                          viewModel.replaceOrchestrationLogLine(model, "\u25B6\uFE0F $desc", "\u274C $desc — ${result.error?.take(80) ?: "unknown error"}")
                        }
                        com.mobileclaw.app.orchestration.StepStatus.SKIPPED ->
                          viewModel.appendOrchestrationLogLine(model, "\u23ED\uFE0F $desc")
                        else -> {}
                      }
                    }
                  }
                }
              }

              // Evaluation.
              if (state.evaluation != null && state.iteration != lastEvalIteration) {
                // Execution phase finished (non-traces mode Executing... line).
                resolveActive("\u25B6\uFE0F Executed")
                lastEvalIteration = state.iteration
                if (showTraces) {
                  if (state.status == OrchestrationStatus.EVALUATING || lastStatus == OrchestrationStatus.EVALUATING) {
                    // Show evaluating as a resolved line immediately — the outcome follows.
                    viewModel.appendOrchestrationLogLine(model, "\uD83D\uDD0D Evaluated${thinkSuffix("evaluating")}")
                  }
                  val eval = state.evaluation!!
                  if (eval.goalAchieved) {
                    viewModel.appendOrchestrationLogLine(model, "\u2705 Goal achieved!")
                  } else {
                    viewModel.appendOrchestrationLogLine(model, "\u26A0\uFE0F Not yet achieved: ${eval.assessment.take(100)}")
                    if (eval.shouldReplan) {
                      setActive("\uD83D\uDD04 Re-planning${thinkSuffix("replanning")}...")
                    }
                  }
                }
              }

              // Repairing.
              if (state.status == OrchestrationStatus.REPAIRING && lastStatus != OrchestrationStatus.REPAIRING) {
                if (showTraces) {
                  setActive("\uD83D\uDD27 Diagnosing failed steps...")
                }
              }

              // Formatting.
              if (state.status == OrchestrationStatus.FORMATTING && lastStatus != OrchestrationStatus.FORMATTING) {
                // Execution may have been the prior active line in non-traces mode.
                resolveActive("\u25B6\uFE0F Executed")
                if (showTraces) {
                  setActive("\u270D\uFE0F Formatting response${thinkSuffix("formatting")}...")
                } else {
                  setActive("\u270D\uFE0F Summarizing${thinkSuffix("formatting")}...")
                }
              }

              // Completed — finalize log, send final output, capture for save-as-skill.
              if (state.status == OrchestrationStatus.COMPLETED && lastStatus != OrchestrationStatus.COMPLETED) {
                // Resolve whichever progress line is still active (formatting, or execution in
                // the short-circuit path where formatting was skipped).
                resolveActive("\u270D\uFE0F Formatted")
                viewModel.appendOrchestrationLogLine(model, "\uD83C\uDF89 Task complete")
                viewModel.finalizeOrchestrationLog(model)
                // Capture orchestration data for "Save as Skill".
                lastOrchestrationUserMessage = text
                lastOrchestrationPlan = state.plan
                lastOrchestrationResults = state.stepResults
                if (state.finalOutput != null) {
                  if (state.finalOutputIsHtml) {
                    // Wrap HTML in a full document for proper rendering.
                    val fullHtml = """
                      <!DOCTYPE html>
                      <html><head>
                        <meta name="viewport" content="width=device-width, initial-scale=1">
                        <style>body{margin:0;padding:8px;font-family:sans-serif;}</style>
                      </head><body>${state.finalOutput!!}</body></html>
                    """.trimIndent()
                    val encoded = android.util.Base64.encodeToString(
                      fullHtml.toByteArray(Charsets.UTF_8),
                      android.util.Base64.NO_WRAP,
                    )
                    viewModel.addMessage(
                      model = model,
                      message = ChatMessageWebView(
                        url = "data:text/html;base64,$encoded",
                        iframe = false,
                        aspectRatio = 1.2f,
                        side = ChatSide.AGENT,
                      ),
                    )
                  } else {
                    viewModel.addMessage(
                      model = model,
                      message = ChatMessageText(
                        content = state.finalOutput!!,
                        side = ChatSide.AGENT,
                      ),
                    )
                    viewModel.persistAssistantMessage(state.finalOutput!!)
                  }
                }
                // Hint about saving as skill if multi-step plan.
                if ((state.plan?.steps?.size ?: 0) >= 2) {
                  viewModel.addMessage(
                    model = model,
                    message = ChatMessageInfo(content = "You can say \"save as skill <name>\" to reuse this workflow."),
                  )
                }
              }

              // Error.
              if (state.status == OrchestrationStatus.ERROR && lastStatus != OrchestrationStatus.ERROR) {
                viewModel.appendOrchestrationLogLine(model, "\u274C Error: ${state.error ?: "unknown"}")
                viewModel.finalizeOrchestrationLog(model)
              }

              // Cancelled.
              if (state.status == OrchestrationStatus.CANCELLED && lastStatus != OrchestrationStatus.CANCELLED) {
                viewModel.appendOrchestrationLogLine(model, "\uD83D\uDED1 Cancelled.")
                viewModel.finalizeOrchestrationLog(model)
              }

              lastStatus = state.status
            }
          }

          // Build recent conversation context for the planner.
          val recentContext = buildString {
            val allMsgs = viewModel.uiState.value.messagesByModel[model.name] ?: emptyList()
            // Take last few user+assistant text messages (excluding the current user message
            // which was just added above).
            val textMsgs = allMsgs
              .filterIsInstance<ChatMessageText>()
              .dropLast(1) // drop the current user message
              .takeLast(6)
            for (m in textMsgs) {
              val who = if (m.side == ChatSide.USER) "User" else "Assistant"
              appendLine("$who: ${m.content.trim().take(300)}")
            }
          }

          // Check connectivity once (fast OS call) before orchestration.
          val isOnline = com.mobileclaw.app.orchestration.ConnectivityChecker.isOnline(context)
          android.util.Log.d("AGOrchOverride", "Connectivity check: online=$isOnline")

          // Run orchestration (blocks until complete).
          coroutineScope.launch(kotlinx.coroutines.Dispatchers.Default) {
            android.util.Log.d("AGOrchOverride", "Launching controller.run()")
            try {
              controller.run(text, recentContext, isOnline)
              android.util.Log.d("AGOrchOverride", "controller.run() completed")
            } catch (e: Exception) {
              android.util.Log.e("AGOrchOverride", "controller.run() failed", e)
            }
          }

          true // Message handled by orchestration.
          }
        }
      }
    },
    showAgentSettingsTab = true,
    agenticModeEnabled = orchestrationEnabled,
    agentTracesEnabled = agentTracesEnabled,
    onAgenticModeChanged = { enabled ->
      orchestrationEnabled = enabled
      dataStoreRepo.setAgenticModeEnabled(enabled)
      if (!enabled) {
        agentTracesEnabled = false
        dataStoreRepo.setAgentTracesEnabled(false)
      }
      // Reset session to add/remove tools based on agentic mode.
      resetSessionWithCurrentSkills(
        viewModel, modelManagerViewModel, skillManagerViewModel,
        task, curSystemPrompt, agentTools,
        agenticModeEnabled = enabled,
      )
    },
    onAgentTracesChanged = { enabled ->
      agentTracesEnabled = enabled
      dataStoreRepo.setAgentTracesEnabled(enabled)
    },
    agentMaxLoops = agentMaxLoops,
    agentMaxRepairAttempts = agentMaxRepairAttempts,
    agentSkillTimeoutSecs = agentSkillTimeoutSecs,
    onAgentMaxLoopsChanged = { value ->
      agentMaxLoops = value
      dataStoreRepo.setAgentMaxLoops(value)
    },
    onAgentMaxRepairAttemptsChanged = { value ->
      agentMaxRepairAttempts = value
      dataStoreRepo.setAgentMaxRepairAttempts(value)
    },
    onAgentSkillTimeoutSecsChanged = { value ->
      agentSkillTimeoutSecs = value
      dataStoreRepo.setAgentSkillTimeoutSecs(value)
    },
    agentThinkingMode = agentThinkingMode,
    onAgentThinkingModeChanged = { value ->
      agentThinkingMode = value
      dataStoreRepo.setAgentThinkingMode(value)
    },
    userPortrait = userPortrait,
    onUserPortraitChanged = { value ->
      userPortrait = value
      dataStoreRepo.setUserPortrait(value)
    },
    agentHistoryWindowSize = agentHistoryWindowSize,
    onAgentHistoryWindowSizeChanged = { value ->
      agentHistoryWindowSize = value
      dataStoreRepo.setAgentHistoryWindowSize(value)
    },
    onClearMemory = {
      val memoryRepo = try {
        EntryPointAccessors.fromApplication(context, MemoryEntryPoint::class.java).memoryRepository()
      } catch (e: Exception) { null }
      memoryRepo?.let { repo ->
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
          repo.clearAll()
        }
      }
    },
  )

  if (showAskInfoDialog && currentAskInfoAction != null) {
    val action = currentAskInfoAction!!
    SecretEditorDialog(
      title = action.dialogTitle,
      fieldLabel = action.fieldLabel,
      value = askInfoInputValue,
      onValueChange = { askInfoInputValue = it },
      onDone = {
        action.result.complete(askInfoInputValue)
        showAskInfoDialog = false
        currentAskInfoAction = null
      },
      onDismiss = {
        action.result.complete("")
        showAskInfoDialog = false
        currentAskInfoAction = null
      },
    )
  }

  if (showSkillManagerBottomSheet) {
    SkillManagerBottomSheet(
      agentTools = agentTools,
      skillManagerViewModel = skillManagerViewModel,
      onDismiss = { selectedSkillsChanged ->
        // Hide sheet.
        showSkillManagerBottomSheet = false

        // Reset session when selected skills changed.
        if (selectedSkillsChanged) {
          Log.d(TAG, "Selected skill changed. Resetting conversation.")
          resetSessionWithCurrentSkills(
            viewModel,
            modelManagerViewModel,
            skillManagerViewModel,
            task,
            curSystemPrompt,
            agentTools,
            agenticModeEnabled = orchestrationEnabled,
          )
        }
      },
    )
  }

}

private fun updateProgressPanel(viewModel: LlmChatViewModel, model: Model, agentTools: AgentTools) {
  // Update status.
  val lastProgressPanelMessage =
    viewModel.getLastMessageWithType(
      model = model,
      type = ChatMessageType.COLLAPSABLE_PROGRESS_PANEL,
    )
  if (
    lastProgressPanelMessage != null &&
      lastProgressPanelMessage is ChatMessageCollapsableProgressPanel
  ) {
    if (lastProgressPanelMessage.title.startsWith("Loading")) {
      agentTools.sendAgentAction(
        SkillProgressAgentAction(
          label = lastProgressPanelMessage.title.replace("Loading", "Loaded"),
          inProgress = false,
        )
      )
    } else if (lastProgressPanelMessage.title.startsWith("Calling")) {
      agentTools.sendAgentAction(
        SkillProgressAgentAction(
          label = lastProgressPanelMessage.title.replace("Calling", "Called"),
          inProgress = false,
        )
      )
    } else if (lastProgressPanelMessage.title.startsWith("Executing")) {
      agentTools.sendAgentAction(
        SkillProgressAgentAction(
          label = lastProgressPanelMessage.title.replace("Executing", "Executed"),
          inProgress = false,
        )
      )
    }
  }
}

private fun resetSessionWithCurrentSkills(
  viewModel: LlmChatViewModel,
  modelManagerViewModel: ModelManagerViewModel,
  skillManagerViewModel: SkillManagerViewModel,
  task: Task,
  curSystemPrompt: String,
  agentTools: AgentTools,
  onDone: (Model) -> Unit = {},
  agenticModeEnabled: Boolean = true,
) {
  val model = modelManagerViewModel.uiState.value.selectedModel
  val newSelectedSkills = skillManagerViewModel.getSelectedSkills()
  viewModel.resetSession(
    task = task,
    model = model,
    systemInstruction =
      if (!agenticModeEnabled || newSelectedSkills.isEmpty()) null
      else skillManagerViewModel.getSystemPrompt(curSystemPrompt),
    tools = if (agenticModeEnabled) listOf(tool(agentTools)) else emptyList(),
    supportImage = true,
    supportAudio = true,
    onDone = { onDone(model) },
    enableConversationConstrainedDecoding = agenticModeEnabled,
  )
}

class ChatWebViewJavascriptInterface {
  var onResultListener: ((String) -> Unit)? = null

  @JavascriptInterface
  fun onResultReady(result: String) {
    onResultListener?.invoke(result)
  }
}

class ChatWebViewClient(val context: Context) : BaseMobileClawWebViewClient(context = context) {
  private var onPageLoaded: (() -> Unit)? = null

  fun setPageLoadListener(listener: (() -> Unit)?) {
    onPageLoaded = listener
  }

  override fun onPageFinished(view: WebView?, url: String?) {
    super.onPageFinished(view, url)
    Log.d(TAG, "page loaded")
    onPageLoaded?.invoke()
  }
}
