package com.mobileclaw.app

import android.os.Bundle

/** No-op analytics for Mobile-Claw (no Firebase dependency). */
class NoOpAnalytics {
  fun logEvent(event: String, params: Bundle?) { /* no-op */ }
}

val firebaseAnalytics: NoOpAnalytics? = NoOpAnalytics()

enum class MobileClawEvent(val id: String) {
  CAPABILITY_SELECT(id = "capability_select"),
  MODEL_DOWNLOAD(id = "model_download"),
  GENERATE_ACTION(id = "generate_action"),
  BUTTON_CLICKED(id = "button_clicked"),
}
