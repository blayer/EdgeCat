package com.mobileclaw.app.orchestration

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SkillRepairTest {

  private lateinit var creator: SkillCreator

  @Before
  fun setUp() {
    creator = SkillCreator()
  }

  // ─── buildDiagnosticPrompt ───

  @Test
  fun `diagnostic prompt includes error and device info`() {
    val step = PlanStep(
      id = "step_1",
      description = "Set an alarm",
      skillName = "set-alarm",
      toolArgs = mapOf("hour" to "7", "minute" to "30", "label" to "Wake up"),
    )

    val prompt = creator.buildDiagnosticPrompt(
      failedStep = step,
      error = "No Activity found to handle Intent { act=android.intent.action.SET_ALARM }",
      deviceInfo = "Android 14 (SDK 34), samsung SM-S918U1",
      skillInstructions = "Set an alarm at a specific time on the device clock.",
    )

    assertTrue(prompt.contains("set-alarm"))
    assertTrue(prompt.contains("No Activity found"))
    assertTrue(prompt.contains("samsung"))
    assertTrue(prompt.contains("SET_ALARM"))
  }

  @Test
  fun `diagnostic prompt includes tool args`() {
    val step = PlanStep(
      id = "step_2",
      description = "Create calendar event",
      skillName = "create-calendar-event",
      toolArgs = mapOf("title" to "Meeting", "startDateTime" to "2066406T15:00"),
    )

    val prompt = creator.buildDiagnosticPrompt(
      failedStep = step,
      error = "Unparseable date: \"\"",
      deviceInfo = "Android 14 (SDK 34), samsung SM-S918U1",
      skillInstructions = "Create a new event in the device calendar.",
    )

    assertTrue(prompt.contains("2066406T15:00"))
    assertTrue(prompt.contains("Unparseable date"))
  }

  // ─── parseDiagnostic: JSON ───

  @Test
  fun `parseDiagnostic handles use_alternative_skill`() {
    val json = """
      {
        "diagnosis": "Samsung devices don't have a standard clock app that handles SET_ALARM intent",
        "fixType": "use_alternative_skill",
        "alternativeSkillName": "set-reminder",
        "alternativeArgs": {"title": "Wake up", "dateTime": "2026-04-06T07:30"},
        "updatedInstructions": null
      }
    """.trimIndent()

    val result = creator.parseDiagnostic(json)
    assertEquals("use_alternative_skill", result.fixType)
    assertEquals("set-reminder", result.alternativeSkillName)
    assertEquals("2026-04-06T07:30", result.alternativeArgs["dateTime"])
    assertNull(result.updatedInstructions)
    assertTrue(result.diagnosis.contains("Samsung"))
  }

  @Test
  fun `parseDiagnostic handles retry_with_different_args`() {
    val json = """
      {
        "diagnosis": "The date format is malformed, missing hyphens",
        "fixType": "retry_with_different_args",
        "alternativeSkillName": null,
        "alternativeArgs": {"startDateTime": "2026-04-06T15:00", "endDateTime": "2026-04-06T16:00"},
        "updatedInstructions": null
      }
    """.trimIndent()

    val result = creator.parseDiagnostic(json)
    assertEquals("retry_with_different_args", result.fixType)
    assertNull(result.alternativeSkillName)
    assertEquals("2026-04-06T15:00", result.alternativeArgs["startDateTime"])
  }

  @Test
  fun `parseDiagnostic handles unfixable`() {
    val json = """
      {
        "diagnosis": "Permission denied for WRITE_CALENDAR",
        "fixType": "unfixable",
        "alternativeSkillName": null,
        "alternativeArgs": {},
        "updatedInstructions": null
      }
    """.trimIndent()

    val result = creator.parseDiagnostic(json)
    assertEquals("unfixable", result.fixType)
    assertTrue(result.alternativeArgs.isEmpty())
  }

  @Test
  fun `parseDiagnostic handles skip`() {
    val json = """
      ```json
      {
        "diagnosis": "This step is redundant since the previous step already achieved the goal",
        "fixType": "skip",
        "alternativeSkillName": null,
        "alternativeArgs": {},
        "updatedInstructions": null
      }
      ```
    """.trimIndent()

    val result = creator.parseDiagnostic(json)
    assertEquals("skip", result.fixType)
  }

  @Test
  fun `parseDiagnostic handles updated instructions`() {
    val json = """
      {
        "diagnosis": "Samsung calendar uses a different content provider URI",
        "fixType": "use_alternative_skill",
        "alternativeSkillName": "set-reminder",
        "alternativeArgs": {"title": "Dentist", "dateTime": "2026-04-06T15:00"},
        "updatedInstructions": "On Samsung devices, use set-reminder instead of create-calendar-event for creating events."
      }
    """.trimIndent()

    val result = creator.parseDiagnostic(json)
    assertNotNull(result.updatedInstructions)
    assertTrue(result.updatedInstructions!!.contains("Samsung"))
  }

  @Test
  fun `parseDiagnostic fallback for malformed output`() {
    val text = "I don't know what went wrong, this is just plain text"

    val result = creator.parseDiagnostic(text)
    assertEquals("unfixable", result.fixType)
    assertTrue(result.diagnosis.isNotEmpty())
  }

  // ─── Integration: diagnostic notes injected into replan ───

  @Test
  fun `diagnostic notes format for replan prompt`() {
    // Simulate what the OrchestrationController builds.
    val diagnostic = DiagnosticResult(
      diagnosis = "Samsung doesn't have standard clock app",
      fixType = "use_alternative_skill",
      alternativeSkillName = "set-reminder",
      alternativeArgs = mapOf("title" to "Wake up", "dateTime" to "2026-04-06T07:30"),
    )

    val notes = buildString {
      append("\n\nDiagnostic for failed step 'step_1' (set-alarm):")
      append("\n- Diagnosis: ${diagnostic.diagnosis}")
      when (diagnostic.fixType) {
        "use_alternative_skill" -> {
          append("\n- Suggested fix: Use skill '${diagnostic.alternativeSkillName}' instead")
          if (diagnostic.alternativeArgs.isNotEmpty()) {
            append(" with args: ${diagnostic.alternativeArgs}")
          }
        }
      }
    }

    assertTrue(notes.contains("set-alarm"))
    assertTrue(notes.contains("Samsung"))
    assertTrue(notes.contains("set-reminder"))
    assertTrue(notes.contains("Wake up"))
  }
}
