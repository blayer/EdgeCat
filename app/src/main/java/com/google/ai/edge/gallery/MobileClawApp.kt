package com.google.ai.edge.gallery

import androidx.compose.runtime.Composable
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.compose.rememberNavController
import com.google.ai.edge.gallery.ui.modelmanager.ModelManagerViewModel
import com.google.ai.edge.gallery.ui.theme.GalleryTheme

@Composable
fun MobileClawApp() {
  val navController = rememberNavController()
  val modelManagerViewModel: ModelManagerViewModel = hiltViewModel()

  GalleryTheme {
    MobileClawNavHost(
      navController = navController,
      modelManagerViewModel = modelManagerViewModel,
    )
  }
}
