/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.edgecat.app.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Friendly error formatting for download failures. Specifically guards
 * against leaking raw `IOException("HTTP error code: 401")` strings or
 * cancel-shaped messages into the user-facing failure label.
 */
class DownloadErrorMessageTest {

  // -------- Cancellation detection --------

  @Test
  fun blankMessageIsNotCancellation() {
    assertFalse(isCancellationMessage(""))
  }

  @Test
  fun cancelKeywordIsCancellation() {
    assertTrue(isCancellationMessage("Job was cancelled"))
    assertTrue(isCancellationMessage("CancellationException"))
    assertTrue(isCancellationMessage("download was cancelled by user"))
  }

  @Test
  fun interruptKeywordIsCancellation() {
    assertTrue(isCancellationMessage("Thread was interrupted"))
  }

  @Test
  fun realFailureIsNotCancellation() {
    assertFalse(isCancellationMessage("HTTP error code: 401"))
    assertFalse(isCancellationMessage("Unable to resolve host"))
    assertFalse(isCancellationMessage("Connection reset by peer"))
  }

  // -------- HTTP error mapping --------

  @Test
  fun http401PromptsSignIn() {
    val msg = friendlyDownloadError("HTTP error code: 401")
    assertTrue("Got: $msg", msg.contains("Sign in"))
  }

  @Test
  fun http403MentionsGatedAcceptance() {
    val msg = friendlyDownloadError("HTTP error code: 403")
    val lower = msg.lowercase()
    assertTrue("Got: $msg", lower.contains("gated") || lower.contains("accept"))
  }

  @Test
  fun http404MentionsCatalogIssue() {
    val msg = friendlyDownloadError("HTTP error code: 404")
    assertTrue(msg.lowercase().contains("not found"))
  }

  @Test
  fun http429MentionsRateLimit() {
    val msg = friendlyDownloadError("HTTP error code: 429")
    assertTrue(msg.lowercase().contains("rate"))
  }

  @Test
  fun http5xxMentionsHuggingFaceServerTrouble() {
    for (code in listOf(500, 502, 503, 599)) {
      val msg = friendlyDownloadError("HTTP error code: $code")
      assertTrue("Got: $msg", msg.contains("Hugging Face"))
    }
  }

  // -------- Transport error mapping --------

  @Test
  fun unableToResolveHostMapsToConnectivityMessage() {
    val msg = friendlyDownloadError(
      "java.net.UnknownHostException: Unable to resolve host \"huggingface.co\""
    )
    assertTrue(
      "Got: $msg",
      msg.lowercase().contains("hugging face") || msg.lowercase().contains("connection")
    )
  }

  @Test
  fun connectionAbortMapsToFriendlyMessage() {
    val msg = friendlyDownloadError("Software caused connection abort")
    assertTrue(msg.lowercase().contains("connection") || msg.lowercase().contains("network"))
  }

  @Test
  fun timeoutMapsToFriendlyMessage() {
    val msg = friendlyDownloadError("read timed out")
    assertTrue(msg.lowercase().contains("timed out"))
  }

  @Test
  fun sslErrorMapsToSecureConnectionMessage() {
    val msg = friendlyDownloadError("javax.net.ssl.SSLException: handshake failed")
    assertTrue(msg.lowercase().contains("secure"))
  }

  @Test
  fun sizeMismatchMapsToRetryMessage() {
    val msg = friendlyDownloadError("Download size mismatch for foo: expected 100, got 50")
    assertTrue(msg.lowercase().contains("download"))
  }

  // -------- Fallthrough never leaks raw text --------

  @Test
  fun unknownErrorReturnsGenericMessageNotRawText() {
    val msg = friendlyDownloadError("java.io.IOException: stream corrupted at offset 0xdeadbeef")
    assertEquals("Download failed. Please try again.", msg)
    assertFalse("Must not leak IOException internals", msg.contains("IOException"))
    assertFalse("Must not leak hex internals", msg.contains("0xdeadbeef"))
  }

  @Test
  fun blankInputReturnsGenericMessage() {
    assertEquals("Download failed. Please try again.", friendlyDownloadError(""))
  }
}
