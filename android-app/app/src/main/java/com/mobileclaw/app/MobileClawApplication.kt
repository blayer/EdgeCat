package com.mobileclaw.app

import android.app.Application
import com.mobileclaw.app.data.DataStoreRepository
import com.mobileclaw.app.ui.theme.ThemeSettings
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
