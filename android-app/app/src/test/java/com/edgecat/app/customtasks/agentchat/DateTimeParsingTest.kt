package com.edgecat.app.customtasks.agentchat

import com.edgecat.app.common.AgentAction
import kotlinx.coroutines.channels.Channel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

@RunWith(RobolectricTestRunner::class)
class DateTimeParsingTest {

  private lateinit var skills: DeviceSkills

  @Before
  fun setUp() {
    val channel = Channel<AgentAction>(Channel.UNLIMITED)
    skills = DeviceSkills(
      contextProvider = { throw UnsupportedOperationException("No context in unit tests") },
      actionChannel = channel,
    )
  }

  private fun assertParsedDate(input: String, expectedYear: Int, expectedMonth: Int, expectedDay: Int, expectedHour: Int, expectedMinute: Int) {
    val millis = skills.parseDateTimeLenient(input)
    assertNotNull("Failed to parse: '$input'", millis)
    val cal = Calendar.getInstance()
    cal.timeInMillis = millis!!
    assertEquals("Year mismatch for '$input'", expectedYear, cal.get(Calendar.YEAR))
    assertEquals("Month mismatch for '$input'", expectedMonth, cal.get(Calendar.MONTH) + 1)
    assertEquals("Day mismatch for '$input'", expectedDay, cal.get(Calendar.DAY_OF_MONTH))
    assertEquals("Hour mismatch for '$input'", expectedHour, cal.get(Calendar.HOUR_OF_DAY))
    assertEquals("Minute mismatch for '$input'", expectedMinute, cal.get(Calendar.MINUTE))
  }

  // ─── Standard ISO format ───

  @Test
  fun `parses standard ISO format`() {
    assertParsedDate("2026-04-06T15:00", 2026, 4, 6, 15, 0)
  }

  @Test
  fun `parses ISO format with seconds`() {
    assertParsedDate("2026-04-06T15:30:00", 2026, 4, 6, 15, 30)
  }

  @Test
  fun `parses space-separated format`() {
    assertParsedDate("2026-04-06 15:00", 2026, 4, 6, 15, 0)
  }

  @Test
  fun `parses slash-separated format`() {
    assertParsedDate("2026/04/06T15:00", 2026, 4, 6, 15, 0)
  }

  @Test
  fun `parses slash space format`() {
    assertParsedDate("2026/04/06 15:00", 2026, 4, 6, 15, 0)
  }

  // ─── Garbled LLM outputs ───

  @Test
  fun `parses garbled date without hyphens 8 digits`() {
    // LLM outputs "20260406T15:00" instead of "2026-04-06T15:00"
    assertParsedDate("20260406T15:00", 2026, 4, 6, 15, 0)
  }

  @Test
  fun `parses garbled date with missing hyphens`() {
    // "202646T15:00" -> digits are 202646, this is tricky
    // 4 digits year: 2026, remaining "46" could be month 4 day 6
    assertParsedDate("202646T15:00", 2026, 4, 6, 15, 0)
  }

  @Test
  fun `parses date with partial hyphens`() {
    // "2026-0406T15:00" -> digit extraction should handle
    assertParsedDate("2026-0406T15:00", 2026, 4, 6, 15, 0)
  }

  @Test
  fun `parses 8-digit concatenated date`() {
    assertParsedDate("20261225T09:30", 2026, 12, 25, 9, 30)
  }

  @Test
  fun `parses date with leading whitespace`() {
    assertParsedDate("  2026-04-06T15:00  ", 2026, 4, 6, 15, 0)
  }

  // ─── Different time values ───

  @Test
  fun `parses midnight`() {
    assertParsedDate("2026-04-06T00:00", 2026, 4, 6, 0, 0)
  }

  @Test
  fun `parses end of day`() {
    assertParsedDate("2026-04-06T23:59", 2026, 4, 6, 23, 59)
  }

  @Test
  fun `parses noon`() {
    assertParsedDate("2026-04-06T12:00", 2026, 4, 6, 12, 0)
  }

  // ─── Null for unparseable ───

  @Test
  fun `returns null for empty string`() {
    assertNull(skills.parseDateTimeLenient(""))
  }

  @Test
  fun `returns null for random text`() {
    assertNull(skills.parseDateTimeLenient("tomorrow afternoon"))
  }

  @Test
  fun `returns null for just a time`() {
    assertNull(skills.parseDateTimeLenient("15:00"))
  }
}
