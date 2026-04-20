package com.mobileclaw.app.orchestration

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ExecutionOrchestratorTest {

  private lateinit var orchestrator: ExecutionOrchestrator

  @Before
  fun setUp() {
    // Create orchestrator with dummy providers — we're only testing helper methods.
    orchestrator = ExecutionOrchestrator(
      llmProvider = object : LlmInferenceProvider {
        override suspend fun generateResponse(prompt: String, enableThinking: Boolean): String = ""
        override fun cancel() {}
      },
      toolExecutor = object : ToolExecutor {
        override suspend fun executeTool(toolName: String, args: Map<String, String>): ToolExecutionResult {
          return ToolExecutionResult(success = false, output = "", error = "not implemented")
        }
        override fun getAvailableSkills(): List<SkillSummary> = emptyList()
      },
    )
  }

  // ─── fixDateTimeArgs ───

  @Test
  fun `fixDateTimeArgs leaves valid format unchanged`() {
    val args = mutableMapOf("startDateTime" to "2026-04-06T15:00")
    orchestrator.fixDateTimeArgs(args, "startDateTime")
    assertEquals("2026-04-06T15:00", args["startDateTime"])
  }

  @Test
  fun `fixDateTimeArgs fixes 8-digit concatenated date`() {
    val args = mutableMapOf("startDateTime" to "20260406T15:00")
    orchestrator.fixDateTimeArgs(args, "startDateTime")
    assertEquals("2026-04-06T15:00", args["startDateTime"])
  }

  @Test
  fun `fixDateTimeArgs fixes garbled 6-digit date`() {
    // "2026" + "46" -> month=4, day=6
    val args = mutableMapOf("startDateTime" to "202646T15:00")
    orchestrator.fixDateTimeArgs(args, "startDateTime")
    // Should extract year 2026, and parse remaining "46" as month 4, day 6
    val result = args["startDateTime"]!!
    assertTrue("Expected valid date format, got: $result", result.matches(Regex("""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}""")))
  }

  @Test
  fun `fixDateTimeArgs does nothing for missing key`() {
    val args = mutableMapOf("title" to "Dentist")
    orchestrator.fixDateTimeArgs(args, "startDateTime")
    assertFalse(args.containsKey("startDateTime"))
  }

  @Test
  fun `fixDateTimeArgs fixes date with partial hyphens`() {
    val args = mutableMapOf("startDateTime" to "2026-0406T15:00")
    orchestrator.fixDateTimeArgs(args, "startDateTime")
    // After stripping non-digits before T, we get "20260406" -> 2026-04-06
    assertEquals("2026-04-06T15:00", args["startDateTime"])
  }

  @Test
  fun `fixDateTimeArgs handles December date`() {
    val args = mutableMapOf("startDateTime" to "20261225T09:30")
    orchestrator.fixDateTimeArgs(args, "startDateTime")
    assertEquals("2026-12-25T09:30", args["startDateTime"])
  }

  // ─── normalizeCalendarArgs ───

  @Test
  fun `normalizeCalendarArgs maps lowercase keys`() {
    val args = mutableMapOf(
      "title" to "Dentist",
      "startdatetime" to "2026-04-06T15:00",
      "enddatetime" to "2026-04-06T16:00",
    )
    orchestrator.normalizeCalendarArgs(args)
    assertEquals("2026-04-06T15:00", args["startDateTime"])
    assertEquals("2026-04-06T16:00", args["endDateTime"])
    assertFalse(args.containsKey("startdatetime"))
    assertFalse(args.containsKey("enddatetime"))
  }

  @Test
  fun `normalizeCalendarArgs does not overwrite existing camelCase keys`() {
    val args = mutableMapOf(
      "startDateTime" to "2026-04-06T15:00",
      "startdatetime" to "2026-04-06T14:00", // should be ignored
    )
    orchestrator.normalizeCalendarArgs(args)
    assertEquals("2026-04-06T15:00", args["startDateTime"])
  }

  @Test
  fun `normalizeCalendarArgs auto-fills endDateTime when missing`() {
    val args = mutableMapOf(
      "startDateTime" to "2026-04-06T15:00",
      "title" to "Meeting",
    )
    orchestrator.normalizeCalendarArgs(args)
    assertEquals("2026-04-06T16:00", args["endDateTime"])
  }

  @Test
  fun `normalizeCalendarArgs auto-fill wraps around midnight`() {
    val args = mutableMapOf(
      "startDateTime" to "2026-04-06T23:30",
    )
    orchestrator.normalizeCalendarArgs(args)
    assertEquals("2026-04-06T00:30", args["endDateTime"])
  }

  @Test
  fun `normalizeCalendarArgs maps start and end shorthand`() {
    val args = mutableMapOf(
      "start" to "2026-04-06T15:00",
      "end" to "2026-04-06T16:00",
    )
    orchestrator.normalizeCalendarArgs(args)
    assertEquals("2026-04-06T15:00", args["startDateTime"])
    assertEquals("2026-04-06T16:00", args["endDateTime"])
  }

  @Test
  fun `normalizeCalendarArgs handles snake_case keys`() {
    val args = mutableMapOf(
      "start_date_time" to "2026-04-06T15:00",
      "end_date_time" to "2026-04-06T16:00",
    )
    orchestrator.normalizeCalendarArgs(args)
    assertEquals("2026-04-06T15:00", args["startDateTime"])
    assertEquals("2026-04-06T16:00", args["endDateTime"])
  }

  // ─── rescueCalendarFromDescription ───

  @Test
  fun `rescue title from called-X pattern`() {
    val args = mutableMapOf<String, String>()
    orchestrator.rescueCalendarFromDescription(
      args,
      "Create a calendar event for tomorrow at 3pm called Team Meeting",
    )
    assertEquals("Team Meeting", args["title"])
  }

  @Test
  fun `rescue title from quoted pattern`() {
    val args = mutableMapOf<String, String>()
    orchestrator.rescueCalendarFromDescription(
      args,
      "Create calendar event \"Project Kickoff\" tomorrow 9am",
    )
    assertEquals("Project Kickoff", args["title"])
  }

  @Test
  fun `rescue startDateTime from tomorrow-at-time pattern`() {
    val args = mutableMapOf<String, String>()
    orchestrator.rescueCalendarFromDescription(
      args,
      "Set a reminder for tomorrow at 9am to buy groceries",
    )
    val start = args["startDateTime"]!!
    assertTrue(start.endsWith("T09:00"))
    assertTrue(start.matches(Regex("""\d{4}-\d{2}-\d{2}T09:00""")))
  }

  @Test
  fun `rescue defaults endDateTime to start plus one hour`() {
    val args = mutableMapOf<String, String>()
    orchestrator.rescueCalendarFromDescription(
      args,
      "Create event tomorrow at 3pm called Team Meeting",
    )
    val start = args["startDateTime"]!!
    val end = args["endDateTime"]!!
    assertTrue(start.endsWith("T15:00"))
    assertTrue(end.endsWith("T16:00"))
  }

  @Test
  fun `rescue does not overwrite existing title`() {
    val args = mutableMapOf("title" to "Existing")
    orchestrator.rescueCalendarFromDescription(
      args,
      "Create event called Team Meeting tomorrow",
    )
    assertEquals("Existing", args["title"])
  }
}
