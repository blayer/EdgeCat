package com.mobileclaw.app.ui.conversations

import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ChatBubbleOutline
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import com.mobileclaw.app.conversations.db.ConversationEntity
import com.mobileclaw.app.data.ModelDownloadStatusType
import com.mobileclaw.app.data.Task
import com.mobileclaw.app.ui.common.ModelPickerChip
import com.mobileclaw.app.ui.common.getTaskIconColor
import com.mobileclaw.app.ui.modelmanager.ModelManagerViewModel
import java.text.DateFormat
import java.util.Date
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationListScreen(
  modelManagerViewModel: ModelManagerViewModel,
  task: Task?,
  onConversationClicked: (Long) -> Unit,
  onOpenDownloadPage: () -> Unit,
  viewModel: ConversationListViewModel = hiltViewModel(),
) {
  val conversations by viewModel.conversations.collectAsState()
  val modelManagerUiState by modelManagerViewModel.uiState.collectAsState()
  var openRowId by remember { mutableStateOf<Long?>(null) }

  Scaffold(
    topBar = {
      CenterAlignedTopAppBar(
        title = {
          Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
          ) {
            if (task != null) {
              Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
              ) {
                val tintColor = getTaskIconColor(task = task)
                Icon(
                  task.icon ?: ImageVector.vectorResource(task.iconVectorResourceId!!),
                  tint = tintColor,
                  modifier = Modifier.size(24.dp),
                  contentDescription = null,
                )
                Text(task.label, style = MaterialTheme.typography.titleMedium, color = tintColor)
              }

              ModelPickerChip(
                enabled = true,
                task = task,
                initialModel = modelManagerUiState.selectedModel,
                modelManagerViewModel = modelManagerViewModel,
                onModelSelected = { _, cur ->
                  modelManagerViewModel.selectModel(cur)
                  val status = modelManagerUiState.modelDownloadStatus[cur.name]?.status
                  if (status != ModelDownloadStatusType.SUCCEEDED) {
                    onOpenDownloadPage()
                  }
                },
              )
            } else {
              Text("Conversations", style = MaterialTheme.typography.titleMedium)
            }
          }
        },
      )
    },
    floatingActionButton = {
      ExtendedFloatingActionButton(
        onClick = {
          if (openRowId != null) {
            openRowId = null
          } else {
            viewModel.createConversation { id -> onConversationClicked(id) }
          }
        },
        icon = { Icon(Icons.Rounded.Add, contentDescription = null) },
        text = { Text("New") },
      )
    },
  ) { innerPadding ->
    if (conversations.isEmpty()) {
      Box(
        modifier = Modifier.fillMaxSize().padding(innerPadding),
        contentAlignment = Alignment.Center,
      ) {
        Column(
          horizontalAlignment = Alignment.CenterHorizontally,
          verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
          Icon(
            Icons.Rounded.ChatBubbleOutline,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
          )
          Text(
            "No conversations yet",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
          Text(
            "Tap \"New\" to start chatting",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
        }
      }
    } else {
      LazyColumn(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
        items(conversations, key = { it.id }) { conv ->
          RevealableConversationRow(
            conv = conv,
            isOpen = openRowId == conv.id,
            onRequestOpen = { openRowId = conv.id },
            onRequestClose = { if (openRowId == conv.id) openRowId = null },
            onRowClicked = {
              if (openRowId != null) {
                openRowId = null
              } else {
                onConversationClicked(conv.id)
              }
            },
            onDelete = {
              openRowId = null
              viewModel.deleteConversation(conv.id)
            },
            onTogglePin = {
              openRowId = null
              viewModel.setPinned(conv.id, !conv.pinned)
            },
          )
          HorizontalDivider()
        }
      }
    }
  }
}

private val ActionButtonWidth = 72.dp
private val ActionsWidth = ActionButtonWidth * 2

@Composable
private fun RevealableConversationRow(
  conv: ConversationEntity,
  isOpen: Boolean,
  onRequestOpen: () -> Unit,
  onRequestClose: () -> Unit,
  onRowClicked: () -> Unit,
  onDelete: () -> Unit,
  onTogglePin: () -> Unit,
) {
  val density = LocalDensity.current
  val actionsPx = with(density) { ActionsWidth.toPx() }
  val offsetX = remember { Animatable(0f) }
  val scope = rememberCoroutineScope()

  LaunchedEffect(isOpen) {
    offsetX.animateTo(if (isOpen) -actionsPx else 0f)
  }

  Box(modifier = Modifier.fillMaxWidth()) {
    // Wrapper that mirrors the foreground cell's size (matchParentSize). Inside it,
    // fillMaxHeight resolves to the cell height — needed because LazyColumn items
    // pass an unbounded max-height constraint to their children.
    Box(modifier = Modifier.matchParentSize()) {
    Row(
      modifier = Modifier
        .align(Alignment.CenterEnd)
        .fillMaxHeight()
        .width(ActionsWidth),
    ) {
      ActionButton(
        icon = Icons.Rounded.PushPin,
        label = if (conv.pinned) "Unpin" else "Pin",
        background = MaterialTheme.colorScheme.tertiaryContainer.copy(alpha = 0.55f),
        contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
        onClick = onTogglePin,
        modifier = Modifier.weight(1f).fillMaxHeight(),
      )
      ActionButton(
        icon = Icons.Rounded.Delete,
        label = "Delete",
        background = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.55f),
        contentColor = MaterialTheme.colorScheme.onErrorContainer,
        onClick = onDelete,
        modifier = Modifier.weight(1f).fillMaxHeight(),
      )
    }
    }

    // Foreground row: draggable horizontally; dragging left reveals the actions.
    Box(
      modifier = Modifier
        .offset { IntOffset(offsetX.value.roundToInt(), 0) }
        .fillMaxWidth()
        .background(MaterialTheme.colorScheme.surface)
        .draggable(
          orientation = Orientation.Horizontal,
          state = rememberDraggableState { delta ->
            scope.launch {
              val next = (offsetX.value + delta).coerceIn(-actionsPx, 0f)
              offsetX.snapTo(next)
            }
          },
          onDragStopped = {
            val shouldOpen = offsetX.value < -actionsPx / 2f
            if (shouldOpen) onRequestOpen() else onRequestClose()
          },
        ),
    ) {
      ConversationRow(conv = conv, onClick = onRowClicked)
    }
  }
}

@Composable
private fun ActionButton(
  icon: ImageVector,
  label: String,
  background: androidx.compose.ui.graphics.Color,
  contentColor: androidx.compose.ui.graphics.Color,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
) {
  Box(
    modifier = modifier.background(background).clickable(onClick = onClick),
    contentAlignment = Alignment.Center,
  ) {
    Column(
      horizontalAlignment = Alignment.CenterHorizontally,
      verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
      Icon(
        icon,
        contentDescription = label,
        tint = contentColor,
        modifier = Modifier.size(20.dp),
      )
      Text(label, style = MaterialTheme.typography.labelSmall, color = contentColor)
    }
  }
}

@Composable
private fun ConversationRow(conv: ConversationEntity, onClick: () -> Unit) {
  Column(
    modifier =
      Modifier.fillMaxWidth()
        .background(MaterialTheme.colorScheme.surface)
        .clickable(onClick = onClick)
        .padding(horizontal = 16.dp, vertical = 12.dp),
    verticalArrangement = Arrangement.spacedBy(4.dp),
  ) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
      if (conv.pinned) {
        Icon(
          Icons.Rounded.PushPin,
          contentDescription = "Pinned",
          tint = MaterialTheme.colorScheme.primary,
          modifier = Modifier.size(14.dp),
        )
      }
      Text(
        text = conv.title.ifBlank { "New conversation" },
        style = MaterialTheme.typography.titleSmall,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.weight(1f),
      )
    }
    if (conv.lastMessagePreview.isNotBlank()) {
      Text(
        text = conv.lastMessagePreview,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
      )
    }
    Text(
      text = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
        .format(Date(conv.updatedAt)),
      style = MaterialTheme.typography.labelSmall,
      color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
  }
}
