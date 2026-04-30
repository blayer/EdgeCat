package com.edgecat.app.orchestration

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure-JVM tests for the URL scraper used to chain `fetch-web-content` off
 * `search-web` output. No Android APIs touched, so no Robolectric needed.
 */
class UrlExtractionTest {

  @Test
  fun `passes a clean http url through unchanged`() {
    assertEquals(
      "https://example.com/path?q=1",
      extractFirstHttpUrl("https://example.com/path?q=1"),
    )
  }

  @Test
  fun `stops at JSON-escaped newline after the URL`() {
    // search-web's output is JSON-serialized — newlines come through as the
    // two-char escape `\n`. The regex must stop at backslash, not include it.
    val raw = "https://weather.com/tokyo\\nMore results below"
    assertEquals("https://weather.com/tokyo", extractFirstHttpUrl(raw))
  }

  @Test
  fun `strips trailing sentence punctuation`() {
    assertEquals(
      "https://example.com",
      extractFirstHttpUrl("Visit https://example.com."),
    )
    assertEquals(
      "https://example.com",
      extractFirstHttpUrl("(see https://example.com)"),
    )
  }

  @Test
  fun `extracts first url from a results listing`() {
    val output = """
      Search results for: weather in Tokyo

      1. Tokyo Weather - weather.com
         https://weather.com/tokyo
         Today: cloudy, 18C.

      2. Tokyo Forecast - accuweather.com
         https://accuweather.com/tokyo
    """.trimIndent()
    assertEquals("https://weather.com/tokyo", extractFirstHttpUrl(output))
  }

  @Test
  fun `returns null when no http url is present`() {
    assertNull(extractFirstHttpUrl("the answer is 42"))
    assertNull(extractFirstHttpUrl(""))
    assertNull(extractFirstHttpUrl("ftp://files.example.com/x")) // non-http scheme
  }
}
