package com.edgecat.app.orchestration

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM tests for the bare-search-results detector that gates the
 * triage shortcut. No Android APIs touched — runs without Robolectric.
 */
class IsBareSearchResultsTest {

  @Test
  fun `detects search-web output with no fetched content`() {
    val out = """
      Search results for: weather in Tokyo

      1. Tokyo - weather.com
         https://weather.com/tokyo
    """.trimIndent()
    assertTrue(isBareSearchResults(out))
  }

  @Test
  fun `accepts search output that includes a fetched page`() {
    val out = """
      Search results for: weather in Tokyo

      1. Tokyo - weather.com
         https://weather.com/tokyo

      Page content from https://weather.com/tokyo

      Tokyo today: cloudy, 18C.
    """.trimIndent()
    assertFalse(isBareSearchResults(out))
  }

  @Test
  fun `non-search outputs are not flagged`() {
    assertFalse(isBareSearchResults("the answer is 42"))
    assertFalse(isBareSearchResults(""))
  }

  @Test
  fun `header match is case-insensitive`() {
    assertTrue(isBareSearchResults("SEARCH RESULTS FOR: x\n1. example.com"))
  }
}
