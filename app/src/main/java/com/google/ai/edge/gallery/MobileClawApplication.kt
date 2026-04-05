package com.google.ai.edge.gallery

import android.app.Application
import com.google.ai.edge.gallery.data.DataStoreRepository
import com.google.ai.edge.gallery.ui.theme.ThemeSettings
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

@HiltAndroidApp
class MobileClawApplication : Application() {

  @Inject lateinit var dataStoreRepository: DataStoreRepository

  override fun onCreate() {
    super.onCreate()
    ThemeSettings.themeOverride.value = dataStoreRepository.readTheme()
  }
}
