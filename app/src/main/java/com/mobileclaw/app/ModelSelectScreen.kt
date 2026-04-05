package com.mobileclaw.app

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Hearing
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mobileclaw.app.data.Model
import com.mobileclaw.app.data.Task
import com.mobileclaw.app.ui.common.modelitem.ModelItem
import com.mobileclaw.app.ui.modelmanager.ModelManagerViewModel

// Accent gradient colors.
private val AccentStart = Color(0xFF6C63FF)
private val AccentEnd = Color(0xFF00BFA5)
private val AccentMid = Color(0xFF4FC3F7)

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

  val bgGradient = Brush.verticalGradient(
    colors = listOf(
      MaterialTheme.colorScheme.surface,
      MaterialTheme.colorScheme.surfaceContainerLow,
    ),
  )

  Box(modifier = Modifier.fillMaxSize().background(bgGradient)) {
    if (isLoading || task == null) {
      LoadingScreen()
    } else {
      LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
          top = 64.dp,
          bottom = 32.dp,
          start = 20.dp,
          end = 20.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(16.dp),
      ) {
        // Hero header.
        item(key = "hero") {
          HeroHeader(modelCount = models.size)
        }

        // Section divider.
        item(key = "divider") {
          Spacer(modifier = Modifier.height(8.dp))
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

@Composable
private fun HeroHeader(modelCount: Int) {
  Column(
    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
  ) {
    // App name with gradient text.
    Text(
      text = "Mobile Claw",
      style = MaterialTheme.typography.headlineLarge.copy(
        fontWeight = FontWeight.Black,
        fontSize = 36.sp,
        brush = Brush.linearGradient(
          colors = listOf(AccentStart, AccentMid, AccentEnd),
        ),
      ),
    )

    Spacer(modifier = Modifier.height(8.dp))

    // Tagline.
    Text(
      text = "On-device AI agent",
      style = MaterialTheme.typography.titleMedium.copy(
        fontWeight = FontWeight.Normal,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      ),
    )

    Spacer(modifier = Modifier.height(24.dp))

    // Model count + section label row.
    Row(
      verticalAlignment = Alignment.CenterVertically,
      modifier = Modifier.fillMaxWidth(),
    ) {
      Text(
        text = "Models",
        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        color = MaterialTheme.colorScheme.onSurface,
      )
      Spacer(modifier = Modifier.width(8.dp))
      Surface(
        shape = CircleShape,
        color = AccentStart.copy(alpha = 0.12f),
      ) {
        Text(
          text = "$modelCount",
          style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
          color = AccentStart,
          modifier = Modifier.padding(horizontal = 10.dp, vertical = 2.dp),
        )
      }
    }
  }
}

@Composable
private fun CapabilityBadge(icon: ImageVector, label: String, color: Color) {
  Surface(
    shape = RoundedCornerShape(8.dp),
    color = color.copy(alpha = 0.1f),
  ) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
      Icon(
        imageVector = icon,
        contentDescription = label,
        tint = color,
        modifier = Modifier.size(14.dp),
      )
      Spacer(modifier = Modifier.width(4.dp))
      Text(
        text = label,
        style = MaterialTheme.typography.labelSmall,
        color = color,
      )
    }
  }
}

@Composable
private fun LoadingScreen() {
  val infiniteTransition = rememberInfiniteTransition(label = "loading")

  // Three pulsing dots.
  val dot1Alpha by infiniteTransition.animateFloat(
    initialValue = 0.3f,
    targetValue = 1f,
    animationSpec = infiniteRepeatable(
      animation = tween(600, easing = LinearEasing),
      repeatMode = RepeatMode.Reverse,
    ),
    label = "dot1",
  )
  val dot2Alpha by infiniteTransition.animateFloat(
    initialValue = 0.3f,
    targetValue = 1f,
    animationSpec = infiniteRepeatable(
      animation = tween(600, delayMillis = 200, easing = LinearEasing),
      repeatMode = RepeatMode.Reverse,
    ),
    label = "dot2",
  )
  val dot3Alpha by infiniteTransition.animateFloat(
    initialValue = 0.3f,
    targetValue = 1f,
    animationSpec = infiniteRepeatable(
      animation = tween(600, delayMillis = 400, easing = LinearEasing),
      repeatMode = RepeatMode.Reverse,
    ),
    label = "dot3",
  )

  // Bounce offset for dots.
  val dot1Offset by infiniteTransition.animateFloat(
    initialValue = 0f,
    targetValue = -8f,
    animationSpec = infiniteRepeatable(
      animation = tween(600, easing = LinearEasing),
      repeatMode = RepeatMode.Reverse,
    ),
    label = "dot1Offset",
  )
  val dot2Offset by infiniteTransition.animateFloat(
    initialValue = 0f,
    targetValue = -8f,
    animationSpec = infiniteRepeatable(
      animation = tween(600, delayMillis = 200, easing = LinearEasing),
      repeatMode = RepeatMode.Reverse,
    ),
    label = "dot2Offset",
  )
  val dot3Offset by infiniteTransition.animateFloat(
    initialValue = 0f,
    targetValue = -8f,
    animationSpec = infiniteRepeatable(
      animation = tween(600, delayMillis = 400, easing = LinearEasing),
      repeatMode = RepeatMode.Reverse,
    ),
    label = "dot3Offset",
  )

  Box(
    modifier = Modifier.fillMaxSize(),
    contentAlignment = Alignment.Center,
  ) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
      // Gradient title on loading screen too.
      Text(
        text = "Mobile Claw",
        style = MaterialTheme.typography.headlineMedium.copy(
          fontWeight = FontWeight.Black,
          brush = Brush.linearGradient(
            colors = listOf(AccentStart, AccentMid, AccentEnd),
          ),
        ),
      )

      Spacer(modifier = Modifier.height(32.dp))

      // Bouncing dots.
      Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
      ) {
        PulsingDot(alpha = dot1Alpha, offsetY = dot1Offset, color = AccentStart)
        PulsingDot(alpha = dot2Alpha, offsetY = dot2Offset, color = AccentMid)
        PulsingDot(alpha = dot3Alpha, offsetY = dot3Offset, color = AccentEnd)
      }

      Spacer(modifier = Modifier.height(20.dp))

      Text(
        text = "Loading models",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
      )
    }
  }
}

@Composable
private fun PulsingDot(alpha: Float, offsetY: Float, color: Color) {
  Box(
    modifier = Modifier
      .size(10.dp)
      .offset(y = offsetY.dp)
      .graphicsLayer { this.alpha = alpha }
      .background(color = color, shape = CircleShape),
  )
}
