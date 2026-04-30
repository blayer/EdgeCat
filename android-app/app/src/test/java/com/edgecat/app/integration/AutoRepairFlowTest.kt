package com.edgecat.app.integration

import com.edgecat.app.orchestration.EvaluationResult
import com.edgecat.app.orchestration.PlanStep
import com.edgecat.app.orchestration.Planner
import com.edgecat.app.orchestration.SelfEvaluator
import com.edgecat.app.orchestration.SkillCreator
import com.edgecat.app.orchestration.SkillSummary
import com.edgecat.app.orchestration.StepResult
import com.edgecat.app.orchestration.StepStatus
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Integration test for the full auto-repair loop:
 *
 * 1. Plan a multi-step task
 * 2. Simulate a step failure
 * 3. Diagnose the failure via SkillCreator
 * 4. Build a replan prompt with diagnostic notes injected
 * 5. Parse the replanned result and verify the fix
 */
@RunWith(RobolectricTestRunner::class)
class AutoRepairFlowTest {

  private lateinit var planner: Planner
  private lateinit var evaluator: SelfEvaluator
  private lateinit var creator: SkillCreator

  @Before
  fun setUp() {
    planner = Planner()
    evaluator = SelfEvaluator()
    creator = SkillCreator()
  }

  @Test
  fun `repair flow - retry with fixed args after date parse failure`() = runBlocking {
    val userMessage = "Create a calendar event for tomorrow at 3pm called Team Meeting"
    val skills = listOf(
      SkillSummary(name = "create-calendar-event", description = "Create a new calendar event"),
      SkillSummary(name = "set-reminder", description = "Set a reminder"),
    )

    // ── Step 1: Plan ──

    val planJson = """
    {
      "goal": "Create a calendar event for Team Meeting at 3pm tomorrow",
      "reasoning": "Use create-calendar-event to add the event",
      "steps": [
        {
          "id": "step_1",
          "description": "Create calendar event",
          "skillName": "create-calendar-event",
          "toolName": null,
          "toolArgs": {"title": "Team Meeting", "startDateTime": "20260411T15:00"},
          "dependsOn": []
        }
      ]
    }
    """.trimIndent()

    val plan = planner.parsePlan(planJson, userMessage)
    assertEquals(1, plan.steps.size)
    assertEquals("create-calendar-event", plan.steps[0].skillName)

    // ── Step 2: Simulate failure ──

    val failedResult = StepResult(
      stepId = "step_1",
      status = StepStatus.FAILED,
      output = "",
      error = "Unparseable date: \"20260411T15:00\"",
    )
    val results = mapOf("step_1" to failedResult)

    // ── Step 3: Diagnose ──

    val diagnosticPrompt = creator.buildDiagnosticPrompt(
      failedStep = plan.steps[0],
      error = failedResult.error!!,
      deviceInfo = "Android 14 (SDK 34), Pixel 8",
      skillInstructions = "Create a new event in the device calendar.",
    )

    assertTrue(diagnosticPrompt.contains("20260411T15:00"))
    assertTrue(diagnosticPrompt.contains("Unparseable date"))
    assertTrue(diagnosticPrompt.contains("create-calendar-event"))

    // Simulate LLM diagnostic response
    val diagnosticJson = """
    {
      "diagnosis": "The date format is malformed - missing hyphens. Should be 2026-04-11T15:00 instead of 20260411T15:00",
      "fixType": "retry_with_different_args",
      "alternativeSkillName": null,
      "alternativeArgs": {"title": "Team Meeting", "startDateTime": "2026-04-11T15:00", "endDateTime": "2026-04-11T16:00"},
      "updatedInstructions": null
    }
    """.trimIndent()

    val diagnostic = creator.parseDiagnostic(diagnosticJson)
    assertEquals("retry_with_different_args", diagnostic.fixType)
    assertEquals("2026-04-11T15:00", diagnostic.alternativeArgs["startDateTime"])

    // ── Step 4: Evaluate and replan ──

    val evaluation = EvaluationResult(
      goalAchieved = false,
      assessment = "Calendar event creation failed due to date format error",
      missingItems = listOf("Calendar event not created"),
      shouldReplan = true,
    )

    // Build diagnostic notes (same logic as OrchestrationController)
    val diagnosticNotes = buildString {
      append("\n\nDiagnostic for failed step 'step_1' (create-calendar-event):")
      append("\n- Diagnosis: ${diagnostic.diagnosis}")
      append("\n- Suggested fix: Retry with corrected args: ${diagnostic.alternativeArgs}")
    }

    val replanPrompt = planner.buildReplanPrompt(
      userMessage = userMessage + diagnosticNotes,
      prevPlan = plan,
      results = results,
      evaluation = evaluation,
      skills = skills,
    )

    assertTrue(replanPrompt.contains("retry_with_different_args").not()) // diagnostic notes are in userMessage
    assertTrue(replanPrompt.contains("2026-04-11T15:00"))
    assertTrue(replanPrompt.contains("Calendar event not created"))

    // ── Step 5: Parse replanned result ──

    val replanJson = """
    {
      "goal": "Create a calendar event for Team Meeting at 3pm tomorrow",
      "reasoning": "Retry with corrected ISO date format",
      "steps": [
        {
          "id": "step_1",
          "description": "Create calendar event with fixed date",
          "skillName": "create-calendar-event",
          "toolName": null,
          "toolArgs": {"title": "Team Meeting", "startDateTime": "2026-04-11T15:00", "endDateTime": "2026-04-11T16:00"},
          "dependsOn": []
        }
      ]
    }
    """.trimIndent()

    val newPlan = planner.parsePlan(replanJson, userMessage)
    assertEquals(1, newPlan.steps.size)
    assertEquals("create-calendar-event", newPlan.steps[0].skillName)
    assertEquals("2026-04-11T15:00", newPlan.steps[0].toolArgs["startDateTime"])
    assertEquals("2026-04-11T16:00", newPlan.steps[0].toolArgs["endDateTime"])
  }

  @Test
  fun `repair flow - swap skill after intent not found`() = runBlocking {
    val userMessage = "Set an alarm for 7:30am tomorrow"
    val skills = listOf(
      SkillSummary(name = "set-alarm", description = "Set an alarm"),
      SkillSummary(name = "set-reminder", description = "Set a reminder"),
      SkillSummary(name = "create-calendar-event", description = "Create calendar event"),
    )

    // ── Plan with set-alarm ──

    val planJson = """
    {
      "goal": "Set an alarm for 7:30am tomorrow",
      "reasoning": "Use set-alarm to create the alarm",
      "steps": [
        {
          "id": "step_1",
          "description": "Set alarm for 7:30am",
          "skillName": "set-alarm",
          "toolName": null,
          "toolArgs": {"hour": "7", "minute": "30", "label": "Wake up"},
          "dependsOn": []
        }
      ]
    }
    """.trimIndent()

    val plan = planner.parsePlan(planJson, userMessage)

    // ── Failure: no clock app ──

    val failedResult = StepResult(
      stepId = "step_1",
      status = StepStatus.FAILED,
      output = "",
      error = "No Activity found to handle Intent { act=android.intent.action.SET_ALARM }",
    )

    // ── Diagnose ──

    val diagnosticPrompt = creator.buildDiagnosticPrompt(
      failedStep = plan.steps[0],
      error = failedResult.error!!,
      deviceInfo = "Android 14 (SDK 34), samsung SM-S918U1",
      skillInstructions = "Set an alarm at a specific time on the device clock.",
    )

    assertTrue(diagnosticPrompt.contains("SET_ALARM"))
    assertTrue(diagnosticPrompt.contains("samsung"))

    val diagnosticJson = """
    {
      "diagnosis": "Samsung devices don't have a standard clock app that handles SET_ALARM intent",
      "fixType": "use_alternative_skill",
      "alternativeSkillName": "set-reminder",
      "alternativeArgs": {"title": "Wake up", "dateTime": "2026-04-11T07:30"},
      "updatedInstructions": null
    }
    """.trimIndent()

    val diagnostic = creator.parseDiagnostic(diagnosticJson)
    assertEquals("use_alternative_skill", diagnostic.fixType)
    assertEquals("set-reminder", diagnostic.alternativeSkillName)

    // ── Replan with diagnostic notes ──

    val evaluation = EvaluationResult(
      goalAchieved = false,
      assessment = "Alarm could not be set - device lacks compatible clock app",
      missingItems = listOf("Alarm not set"),
      shouldReplan = true,
    )

    val diagnosticNotes = buildString {
      append("\n\nDiagnostic for failed step 'step_1' (set-alarm):")
      append("\n- Diagnosis: ${diagnostic.diagnosis}")
      append("\n- Suggested fix: Use skill '${diagnostic.alternativeSkillName}' instead")
      if (diagnostic.alternativeArgs.isNotEmpty()) {
        append(" with args: ${diagnostic.alternativeArgs}")
      }
    }

    val replanPrompt = planner.buildReplanPrompt(
      userMessage = userMessage + diagnosticNotes,
      prevPlan = plan,
      results = mapOf("step_1" to failedResult),
      evaluation = evaluation,
      skills = skills,
    )

    assertTrue(replanPrompt.contains("set-reminder"))
    assertTrue(replanPrompt.contains("Samsung"))

    // ── Replanned: uses set-reminder instead ──

    val replanJson = """
    {
      "goal": "Set a reminder for 7:30am tomorrow as alarm alternative",
      "reasoning": "Use set-reminder since set-alarm is not available on this device",
      "steps": [
        {
          "id": "step_1",
          "description": "Set reminder as alarm alternative",
          "skillName": "set-reminder",
          "toolName": null,
          "toolArgs": {"title": "Wake up", "dateTime": "2026-04-11T07:30"},
          "dependsOn": []
        }
      ]
    }
    """.trimIndent()

    val newPlan = planner.parsePlan(replanJson, userMessage)
    assertEquals(1, newPlan.steps.size)
    assertEquals("set-reminder", newPlan.steps[0].skillName) // Swapped from set-alarm
    assertTrue(newPlan.steps[0].toolArgs["dateTime"]!!.contains("07:30"))
  }

  @Test
  fun `repair flow - evaluation detects partial success and replans remaining steps`() = runBlocking {
    val userMessage = "Get device info and calculate the hash of the manufacturer name"
    val skills = listOf(
      SkillSummary(name = "device-info", description = "Get device information"),
      SkillSummary(name = "calculate-hash", description = "Calculate hash of text"),
    )

    // ── Initial plan: 2 steps ──

    val planJson = """
    {
      "goal": "Get device info then hash the manufacturer name",
      "reasoning": "Use device-info, then calculate-hash",
      "steps": [
        {
          "id": "step_1",
          "description": "Get device information",
          "skillName": "device-info",
          "toolName": null,
          "toolArgs": {},
          "dependsOn": []
        },
        {
          "id": "step_2",
          "description": "Hash the manufacturer name",
          "skillName": "calculate-hash",
          "toolName": null,
          "toolArgs": {"text": "samsung", "algorithm": "sha256"},
          "dependsOn": ["step_1"]
        }
      ]
    }
    """.trimIndent()

    val plan = planner.parsePlan(planJson, userMessage)

    // ── Step 1 succeeds, Step 2 fails ──

    val results = mapOf(
      "step_1" to StepResult(
        stepId = "step_1",
        status = StepStatus.COMPLETED,
        output = "Manufacturer: samsung, Model: SM-S918U1, Android 14",
      ),
      "step_2" to StepResult(
        stepId = "step_2",
        status = StepStatus.FAILED,
        output = "",
        error = "Unknown algorithm: sha256 (supported: md5, sha-1, sha-256)",
      ),
    )

    // ── Evaluate: partial success ──

    val evalJson = """
    {
      "goalAchieved": false,
      "assessment": "Device info retrieved but hash calculation failed",
      "missingItems": ["Hash of manufacturer name"],
      "shouldReplan": true
    }
    """.trimIndent()

    val evaluation = evaluator.parseEvaluation(evalJson)
    assertTrue(!evaluation.goalAchieved)
    assertTrue(evaluation.shouldReplan)

    // ── Diagnose step_2 ──

    val diagnosticJson = """
    {
      "diagnosis": "Algorithm name was wrong - should be 'sha-256' with hyphen, not 'sha256'",
      "fixType": "retry_with_different_args",
      "alternativeSkillName": null,
      "alternativeArgs": {"text": "samsung", "algorithm": "sha-256"},
      "updatedInstructions": null
    }
    """.trimIndent()

    val diagnostic = creator.parseDiagnostic(diagnosticJson)
    assertEquals("retry_with_different_args", diagnostic.fixType)
    assertEquals("sha-256", diagnostic.alternativeArgs["algorithm"])

    // ── Replan: only retry failed step ──

    val replanJson = """
    {
      "goal": "Hash the manufacturer name from device info",
      "reasoning": "Retry hash with corrected algorithm name sha-256",
      "steps": [
        {
          "id": "step_1",
          "description": "Hash the manufacturer name with correct algorithm",
          "skillName": "calculate-hash",
          "toolName": null,
          "toolArgs": {"text": "samsung", "algorithm": "sha-256"},
          "dependsOn": []
        }
      ]
    }
    """.trimIndent()

    val newPlan = planner.parsePlan(replanJson, userMessage)
    assertEquals(1, newPlan.steps.size)
    assertEquals("calculate-hash", newPlan.steps[0].skillName)
    assertEquals("sha-256", newPlan.steps[0].toolArgs["algorithm"])
  }
}
