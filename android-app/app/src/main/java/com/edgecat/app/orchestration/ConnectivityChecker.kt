package com.edgecat.app.orchestration

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/**
 * Fast OS-level internet connectivity check.
 * Uses ConnectivityManager which returns instantly (no network calls).
 */
object ConnectivityChecker {

  /** Skills that require internet access. Excluded from planning when offline. */
  val INTERNET_SKILLS = setOf(
    "search-web",
    "fetch-web-content",
    "open-url",
    "send-email",
  )

  /** Returns true if the device has a validated internet connection. */
  fun isOnline(context: Context): Boolean {
    val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
      ?: return false
    val network = cm.activeNetwork ?: return false
    val caps = cm.getNetworkCapabilities(network) ?: return false
    return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
      caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
  }
}
