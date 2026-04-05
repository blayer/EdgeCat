package com.mobileclaw.app

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.EaseOutCubic
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Hearing
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mobileclaw.app.data.Model
import com.mobileclaw.app.data.ModelDownloadStatusType
import com.mobileclaw.app.data.Task
import com.mobileclaw.app.ui.modelmanager.ModelManagerViewModel
import kotlinx.coroutines.delay

// ─── Dark palette ───
private val BgDark = Color(0xFF0E0E14)
private val SurfaceCard = Color(0xFF1A1A24)
private val CardBorder = Color(0x18FFFFFF)
private val TextPrimary = Color(0xFFEEEEF0)
private val TextSecondary = Color(0xFF8888A0)
private val AccentViolet = Color(0xFF7C6BF0)
private val AccentTeal = Color(0xFF3ECFCF)
private val AccentBlue = Color(0xFF4FC3F7)
private val SuccessGreen = Color(0xFF34D399)
private val BadgeBg = Color(0xFF252530)
private val ShimmerBase = Color(0xFF1A1A24)
private val ShimmerHighlight = Color(0xFF2A2A35)

private val AccentGradient = Brush.linearGradient(listOf(AccentViolet, AccentBlue, AccentTeal))
private val DownloadButtonGradient = Brush.linearGradient(listOf(AccentViolet, AccentTeal))

@Composable
fun ModelSelectScreen(
  task: Task?,
  modelManagerViewModel: ModelManagerViewModel,
  isLoading: Boolean,
  onModelClicked: (Model) -> Unit,
) {
  val models by remember(task) {
    derivedStateOf {
      val trigger = task?.updateTrigger?.value ?: -1
      if (trigger >= 0) task?.models?.toList()?.filter { !it.imported } ?: listOf()
      else listOf()
    }
  }

  Box(modifier = Modifier.fillMaxSize().background(BgDark)) {
    if (isLoading || task == null) {
      LoadingScreen()
    } else {
      LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
          top = 64.dp,
          bottom = 40.dp,
          start = 20.dp,
          end = 20.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(14.dp),
      ) {
        // Hero header.
        item(key = "hero") {
          HeroHeader(modelCount = models.size)
        }

        // Model cards with staggered animation.
        itemsIndexed(items = models, key = { _, m -> m.name }) { index, model ->
          StaggeredModelCard(
            model = model,
            task = task,
            modelManagerViewModel = modelManagerViewModel,
            index = index,
            onModelClicked = onModelClicked,
          )
        }
      }
    }
  }
}

@Composable
private fun HeroHeader(modelCount: Int) {
  Column(
    modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
  ) {
    // App name with gradient.
    Text(
      text = "Mobile Claw",
      style = MaterialTheme.typography.headlineLarge.copy(
        fontWeight = FontWeight.Black,
        fontSize = 34.sp,
        brush = AccentGradient,
      ),
    )

    Spacer(modifier = Modifier.height(6.dp))

    // Tagline.
    Text(
      text = "On-device AI agent",
      style = MaterialTheme.typography.titleMedium,
      color = TextSecondary,
    )

    Spacer(modifier = Modifier.height(28.dp))

    // Section label + count badge.
    Row(verticalAlignment = Alignment.CenterVertically) {
      Text(
        text = "Choose a model",
        style = MaterialTheme.typography.titleSmall.copy(
          fontWeight = FontWeight.SemiBold,
          letterSpacing = 0.5.sp,
        ),
        color = TextPrimary,
      )
      Spacer(modifier = Modifier.width(10.dp))
      Box(
        modifier = Modifier
          .background(AccentViolet.copy(alpha = 0.15f), CircleShape)
          .padding(horizontal = 10.dp, vertical = 2.dp),
      ) {
        Text(
          text = "$modelCount",
          style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
          color = AccentViolet,
        )
      }
    }
  }
}

// ─── Staggered card wrapper ───
@Composable
private fun StaggeredModelCard(
  model: Model,
  task: Task,
  modelManagerViewModel: ModelManagerViewModel,
  index: Int,
  onModelClicked: (Model) -> Unit,
) {
  var visible by remember { mutableStateOf(false) }
  LaunchedEffect(Unit) {
    delay(index * 80L)
    visible = true
  }

  AnimatedVisibility(
    visible = visible,
    enter = fadeIn(tween(400, easing = EaseOutCubic)) +
        slideInVertically(tween(400, easing = EaseOutCubic)) { 40 },
  ) {
    ModelCard(
      model = model,
      task = task,
      modelManagerViewModel = modelManagerViewModel,
      onModelClicked = onModelClicked,
    )
  }
}

// ─── Model card ───
@Composable
private fun ModelCard(
  model: Model,
  task: Task,
  modelManagerViewModel: ModelManagerViewModel,
  onModelClicked: (Model) -> Unit,
) {
  val uiState by modelManagerViewModel.uiState.collectAsState()
  val downloadStatus = uiState.modelDownloadStatus[model.name]
  val isDownloaded = downloadStatus?.status == ModelDownloadStatusType.SUCCEEDED
  val isDownloading = downloadStatus?.status == ModelDownloadStatusType.IN_PROGRESS
  val downloadProgress = if (isDownloading && (downloadStatus?.totalBytes ?: 0) > 0) {
    downloadStatus!!.receivedBytes.toFloat() / downloadStatus.totalBytes.toFloat()
  } else 0f

  val sizeText = remember(model.sizeInBytes) {
    val gb = model.sizeInBytes / (1024.0 * 1024.0 * 1024.0)
    if (gb >= 1.0) String.format("%.1f GB", gb)
    else String.format("%.0f MB", gb * 1024)
  }

  val isBest = model.bestForTaskIds.contains(task.id)

  Box(
    modifier = Modifier
      .fillMaxWidth()
      .clip(RoundedCornerShape(16.dp))
      .background(SurfaceCard)
      .border(1.dp, CardBorder, RoundedCornerShape(16.dp))
      .clickable(
        interactionSource = remember { MutableInteractionSource() },
        indication = null,
      ) {
        if (isDownloaded) onModelClicked(model)
      }
      .padding(16.dp),
  ) {
    Column {
      // Top row: name + size chip.
      Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
      ) {
        Column(modifier = Modifier.weight(1f)) {
          // Best-for badge.
          if (isBest) {
            Text(
              text = "RECOMMENDED",
              style = MaterialTheme.typography.labelSmall.copy(
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.sp,
              ),
              color = AccentTeal,
              modifier = Modifier.padding(bottom = 4.dp),
            )
          }
          Text(
            text = model.name,
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
            color = TextPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
          )
        }
        Spacer(modifier = Modifier.width(8.dp))
        // Size pill.
        Box(
          modifier = Modifier
            .background(BadgeBg, RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 4.dp),
        ) {
          Text(
            text = sizeText,
            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Medium),
            color = TextSecondary,
          )
        }
      }

      Spacer(modifier = Modifier.height(8.dp))

      // Capability badges.
      Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (model.llmSupportImage) {
          CapabilityBadge(icon = Icons.Outlined.Visibility, label = "Vision", color = AccentBlue)
        }
        if (model.llmSupportAudio) {
          CapabilityBadge(icon = Icons.Outlined.Hearing, label = "Audio", color = AccentTeal)
        }
        if (model.llmSupportThinking) {
          CapabilityBadge(icon = Icons.Outlined.Psychology, label = "Thinking", color = AccentViolet)
        }
      }

      // Description.
      if (model.info.isNotEmpty()) {
        Spacer(modifier = Modifier.height(10.dp))
        Text(
          text = model.info.lines().firstOrNull() ?: "",
          style = MaterialTheme.typography.bodySmall,
          color = TextSecondary.copy(alpha = 0.7f),
          maxLines = 2,
          overflow = TextOverflow.Ellipsis,
        )
      }

      Spacer(modifier = Modifier.height(14.dp))

      // Action button.
      when {
        isDownloaded -> {
          // Ready — "Start" button.
          Button(
            onClick = { onModelClicked(model) },
            modifier = Modifier.fillMaxWidth().height(44.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = SuccessGreen),
          ) {
            Icon(
              Icons.Rounded.PlayArrow,
              contentDescription = null,
              modifier = Modifier.size(18.dp),
              tint = Color.White,
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text("Start", fontWeight = FontWeight.SemiBold, color = Color.White)
          }
        }
        isDownloading -> {
          // Downloading — progress bar.
          Box(
            modifier = Modifier
              .fillMaxWidth()
              .height(44.dp)
              .clip(RoundedCornerShape(12.dp))
              .background(AccentViolet.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
          ) {
            // Progress fill.
            Box(
              modifier = Modifier
                .fillMaxWidth(fraction = downloadProgress)
                .height(44.dp)
                .background(
                  Brush.horizontalGradient(listOf(AccentViolet.copy(alpha = 0.3f), AccentTeal.copy(alpha = 0.3f))),
                  RoundedCornerShape(12.dp),
                )
                .align(Alignment.CenterStart),
            )
            Text(
              text = "${(downloadProgress * 100).toInt()}%",
              style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
              color = AccentViolet,
            )
          }
        }
        else -> {
          // Not downloaded — download button.
          Button(
            onClick = {
              modelManagerViewModel.downloadModel(task, model)
            },
            modifier = Modifier.fillMaxWidth().height(44.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = AccentViolet),
          ) {
            Icon(
              Icons.Rounded.Download,
              contentDescription = null,
              modifier = Modifier.size(18.dp),
              tint = Color.White,
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text("Download", fontWeight = FontWeight.SemiBold, color = Color.White)
          }
        }
      }
    }
  }
}

// ─── Capability badge ───
@Composable
private fun CapabilityBadge(icon: ImageVector, label: String, color: Color) {
  Row(
    verticalAlignment = Alignment.CenterVertically,
    modifier = Modifier
      .background(color.copy(alpha = 0.1f), RoundedCornerShape(6.dp))
      .padding(horizontal = 8.dp, vertical = 3.dp),
  ) {
    Icon(
      imageVector = icon,
      contentDescription = label,
      tint = color,
      modifier = Modifier.size(13.dp),
    )
    Spacer(modifier = Modifier.width(4.dp))
    Text(
      text = label,
      style = MaterialTheme.typography.labelSmall.copy(fontSize = 11.sp),
      color = color,
    )
  }
}

// ─── Loading screen ───
@Composable
private fun LoadingScreen() {
  val infiniteTransition = rememberInfiniteTransition(label = "loading")

  // Shimmer offset for skeleton cards.
  val shimmerOffset by infiniteTransition.animateFloat(
    initialValue = -300f,
    targetValue = 600f,
    animationSpec = infiniteRepeatable(
      animation = tween(1200, easing = LinearEasing),
      repeatMode = RepeatMode.Restart,
    ),
    label = "shimmer",
  )

  // Bouncing dots.
  val dot1Y by infiniteTransition.animateFloat(
    initialValue = 0f, targetValue = -10f,
    animationSpec = infiniteRepeatable(tween(500), RepeatMode.Reverse),
    label = "d1",
  )
  val dot2Y by infiniteTransition.animateFloat(
    initialValue = 0f, targetValue = -10f,
    animationSpec = infiniteRepeatable(tween(500, delayMillis = 150), RepeatMode.Reverse),
    label = "d2",
  )
  val dot3Y by infiniteTransition.animateFloat(
    initialValue = 0f, targetValue = -10f,
    animationSpec = infiniteRepeatable(tween(500, delayMillis = 300), RepeatMode.Reverse),
    label = "d3",
  )

  Column(
    modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 64.dp),
  ) {
    // Gradient title.
    Text(
      text = "Mobile Claw",
      style = MaterialTheme.typography.headlineLarge.copy(
        fontWeight = FontWeight.Black,
        fontSize = 34.sp,
        brush = AccentGradient,
      ),
    )

    Spacer(modifier = Modifier.height(6.dp))

    Text(
      text = "On-device AI agent",
      style = MaterialTheme.typography.titleMedium,
      color = TextSecondary,
    )

    Spacer(modifier = Modifier.height(48.dp))

    // Skeleton cards.
    repeat(2) {
      ShimmerCard(shimmerOffset = shimmerOffset)
      Spacer(modifier = Modifier.height(14.dp))
    }

    Spacer(modifier = Modifier.weight(1f))

    // Bouncing dots at center-bottom.
    Row(
      modifier = Modifier.fillMaxWidth(),
      horizontalArrangement = Arrangement.Center,
      verticalAlignment = Alignment.CenterVertically,
    ) {
      BounceDot(offsetY = dot1Y, color = AccentViolet)
      Spacer(modifier = Modifier.width(8.dp))
      BounceDot(offsetY = dot2Y, color = AccentBlue)
      Spacer(modifier = Modifier.width(8.dp))
      BounceDot(offsetY = dot3Y, color = AccentTeal)
    }

    Spacer(modifier = Modifier.height(8.dp))

    Text(
      text = "Loading models",
      style = MaterialTheme.typography.bodySmall,
      color = TextSecondary.copy(alpha = 0.6f),
      modifier = Modifier.align(Alignment.CenterHorizontally),
    )
  }
}

@Composable
private fun ShimmerCard(shimmerOffset: Float) {
  val shimmerBrush = Brush.linearGradient(
    colors = listOf(ShimmerBase, ShimmerHighlight, ShimmerBase),
    start = Offset(shimmerOffset, 0f),
    end = Offset(shimmerOffset + 300f, 0f),
  )

  Box(
    modifier = Modifier
      .fillMaxWidth()
      .height(140.dp)
      .clip(RoundedCornerShape(16.dp))
      .background(SurfaceCard)
      .border(1.dp, CardBorder, RoundedCornerShape(16.dp)),
  ) {
    Column(modifier = Modifier.padding(16.dp)) {
      // Title skeleton.
      Box(
        modifier = Modifier
          .width(160.dp)
          .height(18.dp)
          .clip(RoundedCornerShape(4.dp))
          .background(shimmerBrush),
      )
      Spacer(modifier = Modifier.height(12.dp))
      // Badge skeletons.
      Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(
          modifier = Modifier
            .width(60.dp)
            .height(20.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(shimmerBrush),
        )
        Box(
          modifier = Modifier
            .width(52.dp)
            .height(20.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(shimmerBrush),
        )
      }
      Spacer(modifier = Modifier.height(12.dp))
      // Description skeleton.
      Box(
        modifier = Modifier
          .fillMaxWidth(0.8f)
          .height(12.dp)
          .clip(RoundedCornerShape(4.dp))
          .background(shimmerBrush),
      )
      Spacer(modifier = Modifier.height(14.dp))
      // Button skeleton.
      Box(
        modifier = Modifier
          .fillMaxWidth()
          .height(36.dp)
          .clip(RoundedCornerShape(12.dp))
          .background(shimmerBrush),
      )
    }
  }
}

@Composable
private fun BounceDot(offsetY: Float, color: Color) {
  Box(
    modifier = Modifier
      .size(10.dp)
      .offset(y = offsetY.dp)
      .background(color, CircleShape),
  )
}
