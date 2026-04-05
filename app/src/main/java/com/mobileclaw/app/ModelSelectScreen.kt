package com.mobileclaw.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.mobileclaw.app.data.Model
import com.mobileclaw.app.data.Task
import com.mobileclaw.app.ui.common.modelitem.ModelItem
import com.mobileclaw.app.ui.modelmanager.ModelManagerViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelSelectScreen(
  task: Task?,
  modelManagerViewModel: ModelManagerViewModel,
  isLoading: Boolean,
  onModelClicked: (Model) -> Unit,
) {
  val modelItemExpandedStates = remember { mutableStateMapOf<String, Boolean>() }

  val models by remember(task) {
    derivedStateOf {
      val trigger = task?.updateTrigger?.value ?: -1
      if (trigger >= 0) task?.models?.toList()?.filter { !it.imported } ?: listOf()
      else listOf()
    }
  }

  Scaffold(
    topBar = {
      TopAppBar(
        title = {
          Text(
            "Mobile Claw",
            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
          )
        },
        colors = TopAppBarDefaults.topAppBarColors(
          containerColor = MaterialTheme.colorScheme.surface,
        ),
      )
    },
  ) { innerPadding ->
    if (isLoading || task == null) {
      // Loading state.
      Box(
        modifier = Modifier.fillMaxSize().padding(innerPadding),
        contentAlignment = Alignment.Center,
      ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
          CircularProgressIndicator(modifier = Modifier.size(48.dp))
          Spacer(modifier = Modifier.height(16.dp))
          Text("Loading models...", style = MaterialTheme.typography.bodyLarge)
        }
      }
    } else {
      LazyColumn(
        modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface),
        contentPadding = PaddingValues(
          top = innerPadding.calculateTopPadding() + 8.dp,
          bottom = innerPadding.calculateBottomPadding() + 16.dp,
          start = 16.dp,
          end = 16.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(12.dp),
      ) {
        // Header section.
        item(key = "header") {
          Column(
            modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
          ) {
            Text(
              "On-device AI agent with skills",
              style = MaterialTheme.typography.bodyLarge,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
              "${models.size} models available",
              style = MaterialTheme.typography.bodyMedium,
              color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            )
          }
        }

        // Section title.
        item(key = "sectionTitle") {
          Text(
            "Choose a model",
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(bottom = 4.dp),
          )
        }

        // Model cards.
        items(items = models, key = { it.name }) { model ->
          val expanded = modelItemExpandedStates.getOrDefault(model.name, null)
          ModelItem(
            model = model,
            task = task,
            modelManagerViewModel = modelManagerViewModel,
            onModelClicked = onModelClicked,
            onBenchmarkClicked = {},
            expanded = expanded,
            onExpanded = { modelItemExpandedStates[model.name] = it },
            showBenchmarkButton = false,
          )
        }
      }
    }
  }
}
