package com.mobileclaw.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.mobileclaw.app.customtasks.common.CustomTaskDataForBuiltinTask
import com.mobileclaw.app.data.Model
import com.mobileclaw.app.data.Task
import com.mobileclaw.app.ui.modelmanager.ModelManager
import com.mobileclaw.app.ui.modelmanager.ModelManagerViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

private const val ROUTE_MODEL_SELECT = "model_select"
private const val ROUTE_AGENT_CHAT = "agent_chat"

@Composable
fun MobileClawNavHost(
  navController: NavHostController,
  modelManagerViewModel: ModelManagerViewModel,
) {
  val context = LocalContext.current
  val scope = rememberCoroutineScope()

  // Get the agent chat task (the only task in Mobile-Claw).
  val agentTask = remember {
    modelManagerViewModel.uiState.value.tasks.firstOrNull()
  }

  NavHost(
    navController = navController,
    startDestination = ROUTE_MODEL_SELECT,
  ) {
    // Model selection screen.
    composable(route = ROUTE_MODEL_SELECT) {
      agentTask?.let { task ->
        ModelManager(
          viewModel = modelManagerViewModel,
          task = task,
          enableAnimation = true,
          onModelClicked = { model ->
            modelManagerViewModel.selectModel(model)
            navController.navigate("$ROUTE_AGENT_CHAT/${model.name}")
          },
          navigateUp = { /* No back from root */ },
        )
      }
    }

    // Agent chat screen.
    composable(
      route = "$ROUTE_AGENT_CHAT/{modelName}",
      arguments = listOf(navArgument("modelName") { type = NavType.StringType }),
    ) { backStackEntry ->
      val modelName = backStackEntry.arguments?.getString("modelName") ?: ""

      agentTask?.let { task ->
        val customTask = modelManagerViewModel.getCustomTaskByTaskId(id = task.id)
        if (customTask != null) {
          customTask.MainScreen(
            data = CustomTaskDataForBuiltinTask(
              modelManagerViewModel = modelManagerViewModel,
              onNavUp = {
                // Clean up models when navigating back.
                for (model in task.models) {
                  val instance = model.instance
                  scope.launch(Dispatchers.Default) {
                    modelManagerViewModel.cleanupModel(
                      context = context,
                      task = task,
                      model = model,
                      instanceToCleanUp = instance,
                    )
                  }
                }
                navController.navigateUp()
              },
            )
          )
        }
      }
    }
  }
}
