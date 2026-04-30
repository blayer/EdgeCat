package com.edgecat.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.compose.rememberNavController
import com.edgecat.app.ui.modelmanager.ModelManagerViewModel
import com.edgecat.app.ui.theme.EdgeCatTheme

@Composable
fun EdgeCatApp() {
  val navController = rememberNavController()
  val modelManagerViewModel: ModelManagerViewModel = hiltViewModel()

  LaunchedEffect(Unit) {
    modelManagerViewModel.loadModelAllowlist()
  }

  EdgeCatTheme {
    EdgeCatNavHost(
      navController = navController,
      modelManagerViewModel = modelManagerViewModel,
    )
  }
}
