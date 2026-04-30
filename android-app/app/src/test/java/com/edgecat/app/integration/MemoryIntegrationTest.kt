package com.edgecat.app.integration

import com.edgecat.app.memory.DefaultMemoryRepository
import com.edgecat.app.memory.Episode
import com.edgecat.app.memory.FakeMemoryDao
import com.edgecat.app.memory.RepairRecord
import com.edgecat.app.orchestration.Planner
import com.edgecat.app.orchestration.SkillCreator
import com.edgecat.app.orchestration.SkillSummary
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Integration test: memory context flows into planner and diagnostic prompts.
 */
@RunWith(RobolectricTestRunner::class)
class MemoryIntegrationTest {

  private lateinit var repo: DefaultMemoryRepository
  private lateinit var planner: Planner
  private lateinit var creator: SkillCreator

  @Before
  fun setUp() {
    repo = DefaultMemoryRepository(FakeMemoryDao())
    planner = Planner()
    creator = SkillCreator()
  }

  @Test
  fun `memory context injected into planning prompt`() = runBlocking {
    // Save a device fact and a past episode
    repo.saveDeviceFact("alt_skill_set-alarm", "No Clock app; use set-reminder instead of set-alarm")
    repo.saveEpisode(
      Episode(
        id = "ep-1",
        userMessage = "Set an alarm for 6am",
        goal = "Set alarm",
        skillsUsed = listOf("set-alarm", "set-reminder"),
        outcome = "partial",
        stepCount = 2,
        finalOutput = "Reminder set via fallback",
      )
    )

    val memoryContext = repo.recallForPlanning("Set an alarm for 7am")
    assertTrue("Memory context should contain device facts", memoryContext.contains("[Device Knowledge]"))
    assertTrue("Memory context should mention set-reminder", memoryContext.contains("set-reminder"))

    // Inject into planning prompt
    val skills = listOf(
      SkillSummary(name = "set-alarm", description = "Set an alarm"),
      SkillSummary(name = "set-reminder", description = "Set a reminder"),
    )
    val prompt = planner.buildPlanningPrompt("Set an alarm for 7am", skills, memoryContext)
    assertTrue("Planning prompt should contain device knowledge", prompt.contains("[Device Knowledge]"))
    assertTrue("Planning prompt should mention set-reminder alternative", prompt.contains("set-reminder"))
  }

  @Test
  fun `memory context injected into replan prompt`() = runBlocking {
    repo.saveDeviceFact("alt_skill_set-alarm", "Use set-reminder instead")
    val memoryContext = repo.recallForPlanning("Set alarm")

    val skills = listOf(
      SkillSummary(name = "set-alarm", description = "Set an alarm"),
      SkillSummary(name = "set-reminder", description = "Set a reminder"),
    )
    val prevPlan = planner.parsePlan("""
      {"goal":"Set alarm","reasoning":"use set-alarm","steps":[{"id":"step_1","description":"Set alarm","skillName":"set-alarm","toolName":null,"toolArgs":{},"dependsOn":[]}]}
    """.trimIndent(), "Set alarm")

    val results = mapOf(
      "step_1" to com.edgecat.app.orchestration.StepResult(
        stepId = "step_1",
        status = com.edgecat.app.orchestration.StepStatus.FAILED,
        error = "ActivityNotFoundException",
      )
    )
    val evaluation = com.edgecat.app.orchestration.EvaluationResult(
      goalAchieved = false,
      assessment = "Alarm skill failed",
      missingItems = listOf("alarm not set"),
      shouldReplan = true,
    )

    val replanPrompt = planner.buildReplanPrompt("Set alarm", prevPlan, results, evaluation, skills, memoryContext)
    assertTrue("Replan prompt should contain device knowledge", replanPrompt.contains("[Device Knowledge]"))
  }

  @Test
  fun `past repairs injected into diagnostic prompt`() = runBlocking {
    repo.saveRepair(
      RepairRecord(
        id = "rep-1",
        skillName = "set-alarm",
        errorSummary = "ActivityNotFoundException",
        fixType = "use_alternative_skill",
        fixDescription = "No Clock app on Samsung S23",
        alternativeSkill = "set-reminder",
        success = true,
      )
    )

    val pastRepairs = repo.recallRepairs("set-alarm", "ActivityNotFoundException")
    val pastRepairsStr = pastRepairs.joinToString("\n") { r ->
      val successStr = if (r.success) "worked" else "did not work"
      "- ${r.fixType}: ${r.fixDescription} ($successStr)"
    }

    val failedStep = com.edgecat.app.orchestration.PlanStep(
      id = "step_1",
      description = "Set alarm for 7am",
      skillName = "set-alarm",
    )
    val diagPrompt = creator.buildDiagnosticPrompt(
      failedStep = failedStep,
      error = "ActivityNotFoundException: No activity found to handle intent",
      deviceInfo = "Android 13, Samsung SM-S918U1",
      skillInstructions = "",
      pastRepairs = pastRepairsStr,
    )
    assertTrue("Diagnostic prompt should contain past repair info", diagPrompt.contains("use_alternative_skill"))
    assertTrue("Diagnostic prompt should mention it worked", diagPrompt.contains("worked"))
  }

  @Test
  fun `recallForPlanning returns empty string with no data`() = runBlocking {
    val result = repo.recallForPlanning("Something new")
    assertTrue("Should be empty with no data", result.isEmpty())
  }

  @Test
  fun `planning prompt works without memory context`() {
    val skills = listOf(SkillSummary(name = "search-web", description = "Search the web"))
    val prompt = planner.buildPlanningPrompt("Search for news", skills)
    assertFalse("No memory section when context is empty", prompt.contains("[Device Knowledge]"))
    assertTrue("Prompt should still have skill list", prompt.contains("search-web"))
  }
}
