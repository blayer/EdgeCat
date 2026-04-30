package com.edgecat.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.edgecat.app.customtasks.common.CustomTaskDataForBuiltinTask
import com.edgecat.app.data.Model
import com.edgecat.app.data.ModelDownloadStatusType
import com.edgecat.app.ui.conversations.ConversationListScreen
import com.edgecat.app.ui.modelmanager.ModelManagerViewModel

private const val ROUTE_CONVERSATIONS = "conversations"
private const val ROUTE_MODEL_SELECT = "model_select"
private const val ROUTE_AGENT_CHAT = "agent_chat"

@Composable
fun EdgeCatNavHost(
  navController: NavHostController,
  modelManagerViewModel: ModelManagerViewModel,
) {
  val uiState by modelManagerViewModel.uiState.collectAsState()
  val agentTask = uiState.tasks.firstOrNull()

  NavHost(
    navController = navController,
    startDestination = ROUTE_CONVERSATIONS,
  ) {
    // Conversation list screen (start destination).
    composable(route = ROUTE_CONVERSATIONS) {
      fun isReady(model: Model?): Boolean {
        if (model == null || model.name == "empty") return false
        val status = uiState.modelDownloadStatus[model.name]?.status
        return status == ModelDownloadStatusType.SUCCEEDED
      }

      ConversationListScreen(
        modelManagerViewModel = modelManagerViewModel,
        task = agentTask,
        onConversationClicked = { conversationId ->
          val selected = modelManagerViewModel.getSelectedModel()
          if (!isReady(selected)) {
            navController.navigate("$ROUTE_MODEL_SELECT?conversationId=$conversationId")
          } else {
            navController.navigate("$ROUTE_AGENT_CHAT/${selected!!.name}/$conversationId")
          }
        },
        onOpenDownloadPage = {
          navController.navigate("$ROUTE_MODEL_SELECT?conversationId=-1")
        },
      )
    }

    // Model selection screen.
    composable(
      route = "$ROUTE_MODEL_SELECT?conversationId={conversationId}",
      arguments = listOf(
        navArgument("conversationId") {
          type = NavType.LongType
          defaultValue = -1L
        }
      ),
    ) { backStackEntry ->
      val conversationId = backStackEntry.arguments?.getLong("conversationId") ?: -1L
      ModelSelectScreen(
        task = agentTask,
        modelManagerViewModel = modelManagerViewModel,
        isLoading = uiState.loadingModelAllowlist,
        onModelClicked = { model ->
          modelManagerViewModel.selectModel(model)
          if (conversationId >= 0L) {
            navController.navigate("$ROUTE_AGENT_CHAT/${model.name}/$conversationId") {
              popUpTo(ROUTE_CONVERSATIONS)
            }
          } else {
            navController.navigate("$ROUTE_AGENT_CHAT/${model.name}/-1")
          }
        },
      )
    }

    // Agent chat screen.
    composable(
      route = "$ROUTE_AGENT_CHAT/{modelName}/{conversationId}",
      arguments = listOf(
        navArgument("modelName") { type = NavType.StringType },
        navArgument("conversationId") { type = NavType.LongType },
      ),
    ) { backStackEntry ->
      val conversationIdArg = backStackEntry.arguments?.getLong("conversationId") ?: -1L
      val conversationId = if (conversationIdArg >= 0L) conversationIdArg else null

      agentTask?.let { task ->
        val customTask = modelManagerViewModel.getCustomTaskByTaskId(id = task.id)
        if (customTask != null) {
          customTask.MainScreen(
            data = CustomTaskDataForBuiltinTask(
              modelManagerViewModel = modelManagerViewModel,
              conversationId = conversationId,
              onNavUp = {
                // Pop back to the conversation list — do NOT tear down the model so that
                // the user can tap another conversation and skip model selection.
                navController.navigateUp()
              },
            )
          )
        }
      }
    }
  }
}
