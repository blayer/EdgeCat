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

package com.mobileclaw.app.customtasks.agentchat

import android.content.Context
import androidx.compose.runtime.Composable
import com.mobileclaw.app.R
import com.mobileclaw.app.customtasks.common.CustomTask
import com.mobileclaw.app.customtasks.common.CustomTaskDataForBuiltinTask
import com.mobileclaw.app.data.BuiltInTaskId
import com.mobileclaw.app.data.Category
import com.mobileclaw.app.data.DataStoreRepository
import com.mobileclaw.app.data.Model
import com.mobileclaw.app.data.Task
import com.mobileclaw.app.ui.llmchat.LlmChatModelHelper
import com.google.ai.edge.litertlm.tool
import dagger.Module
import dagger.Provides
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoSet
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope

@EntryPoint
@InstallIn(SingletonComponent::class)
interface DataStoreEntryPoint {
  fun dataStoreRepository(): DataStoreRepository
}

class AgentChatTask @Inject constructor() : CustomTask {
  private val agentTools = AgentTools()

  override val task: Task =
    Task(
      id = BuiltInTaskId.LLM_AGENT_CHAT,
      label = "Agent Skills",
      category = Category.LLM,
      iconVectorResourceId = R.drawable.agent,
      newFeature = true,
      models = mutableListOf(),
      description = "Chat with on-device large language models with skills and tools",
      shortDescription = "Complete agentic tasks with chat",
      docUrl = "https://github.com/google-ai-edge/LiteRT-LM/blob/main/kotlin/README.md",
      sourceCodeUrl =
        "https://github.com/google-ai-edge/gallery/blob/main/Android/src/app/src/main/java/com/google/ai/edge/gallery/customtasks/agentchat/",
      textInputPlaceHolderRes = R.string.text_input_placeholder_llm_chat,
      defaultSystemPrompt =
        """
        You are a helpful AI assistant with access to device skills and tools.
        When the user asks a task, use the most relevant skill from this list:

        ___SKILLS___

        Use skills by calling the appropriate tool with the right parameters.
        If no skill matches the request, answer directly from your knowledge.
        Output ONLY the final result — no intermediate thoughts or reasoning.
        """
          .trimIndent(),
    )

  override fun initializeModelFn(
    context: Context,
    coroutineScope: CoroutineScope,
    model: Model,
    onDone: (String) -> Unit,
  ) {
    val agenticModeEnabled = try {
      EntryPointAccessors.fromApplication(context, DataStoreEntryPoint::class.java)
        .dataStoreRepository().isAgenticModeEnabled()
    } catch (e: Exception) { true }

    agentTools.skillManagerViewModel.loadSkills {
      LlmChatModelHelper.initialize(
        context = context,
        model = model,
        supportImage = true,
        supportAudio = true,
        onDone = onDone,
        systemInstruction =
          if (!agenticModeEnabled || agentTools.skillManagerViewModel.getSelectedSkills().isEmpty()) {
            null
          } else {
            agentTools.skillManagerViewModel.getSystemPrompt(task.defaultSystemPrompt)
          },
        tools = if (agenticModeEnabled) listOf(tool(agentTools)) else emptyList(),
        enableConversationConstrainedDecoding = agenticModeEnabled,
      )
    }
  }

  override fun cleanUpModelFn(
    context: Context,
    coroutineScope: CoroutineScope,
    model: Model,
    onDone: () -> Unit,
  ) {
    LlmChatModelHelper.cleanUp(model = model, onDone = onDone)
  }

  @Composable
  override fun MainScreen(data: Any) {
    val myData = data as CustomTaskDataForBuiltinTask
    AgentChatScreen(
      task = task,
      modelManagerViewModel = myData.modelManagerViewModel,
      navigateUp = myData.onNavUp,
      agentTools = agentTools,
    )
  }
}

@Module
@InstallIn(SingletonComponent::class)
internal object AgentChatTaskModule {
  @Provides
  @IntoSet
  fun provideTask(): CustomTask {
    return AgentChatTask()
  }
}
