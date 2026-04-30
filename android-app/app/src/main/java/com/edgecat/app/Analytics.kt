package com.edgecat.app

import android.os.Bundle

/** No-op analytics for EdgeCat (no Firebase dependency). */
class NoOpAnalytics {
  fun logEvent(event: String, params: Bundle?) { /* no-op */ }
}

val firebaseAnalytics: NoOpAnalytics? = NoOpAnalytics()

enum class EdgeCatEvent(val id: String) {
  CAPABILITY_SELECT(id = "capability_select"),
  MODEL_DOWNLOAD(id = "model_download"),
  GENERATE_ACTION(id = "generate_action"),
  BUTTON_CLICKED(id = "button_clicked"),
}
