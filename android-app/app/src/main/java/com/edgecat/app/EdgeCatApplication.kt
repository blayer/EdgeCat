package com.edgecat.app

import android.app.Application
import com.edgecat.app.data.DataStoreRepository
import com.edgecat.app.ui.theme.ThemeSettings
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

@HiltAndroidApp
class EdgeCatApplication : Application() {

  @Inject lateinit var dataStoreRepository: DataStoreRepository

  override fun onCreate() {
    super.onCreate()
    ThemeSettings.themeOverride.value = dataStoreRepository.readTheme()
  }
}
