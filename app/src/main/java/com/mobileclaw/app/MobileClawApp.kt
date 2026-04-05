package com.mobileclaw.app

import androidx.compose.runtime.Composable
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.compose.rememberNavController
import com.mobileclaw.app.ui.modelmanager.ModelManagerViewModel
import com.mobileclaw.app.ui.theme.MobileClawTheme

@Composable
fun MobileClawApp() {
  val navController = rememberNavController()
  val modelManagerViewModel: ModelManagerViewModel = hiltViewModel()

  MobileClawTheme {
    MobileClawNavHost(
      navController = navController,
      modelManagerViewModel = modelManagerViewModel,
    )
  }
}
