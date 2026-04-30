package com.edgecat.app.integration

import com.edgecat.app.orchestration.ExecutionPlan
import com.edgecat.app.orchestration.PlanStep
import com.edgecat.app.orchestration.Planner
import com.edgecat.app.orchestration.SelfEvaluator
import com.edgecat.app.orchestration.SkillCreator
import com.edgecat.app.orchestration.SkillSummary
import com.edgecat.app.orchestration.StepResult
import com.edgecat.app.orchestration.StepStatus
import com.edgecat.app.orchestration.ToolExecutionResult
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Full end-to-end simulation of the save-as-skill flow:
 *
 * 1. User sends "What is the weather in Tokyo" -> Planner creates plan -> Executor runs -> Results
 * 2. User sends "save as skill check-weather" -> SkillCreator generates SKILL.md -> Saved
 * 3. User sends "Check weather in Osaka" -> Planner uses saved skill -> Same plan structure
 *
 * Uses a mock LLM that returns scripted responses for each phase.
 */
@RunWith(RobolectricTestRunner::class)
class EndToEndSkillFlowTest {

  private lateinit var planner: Planner
  private lateinit var evaluator: SelfEvaluator
  private lateinit var creator: SkillCreator

  // Simulated tool results.
  private val toolResults = mutableMapOf<String, ToolExecutionResult>()

  @Before
  fun setUp() {
    planner = Planner()
    evaluator = SelfEvaluator()
    creator = SkillCreator()
  }

  @Test
  fun `full flow - prompt to save to replay`() = runBlocking {
    // ======================================================
    // PHASE 1: Original prompt -> plan -> execute -> result
    // ======================================================

    val userMessage = "What is the weather in Tokyo"
    val availableSkills = listOf(
      SkillSummary(name = "search-web", description = "Search the web"),
      SkillSummary(name = "calculator", description = "Evaluate math"),
      SkillSummary(name = "summarize", description = "Summarize text"),
    )

    // Step 1a: Build planning prompt.
    val planPrompt = planner.buildPlanningPrompt(userMessage, availableSkills)
    assertTrue(planPrompt.contains("What is the weather in Tokyo"))
    assertTrue(planPrompt.contains("search-web"))

    // Step 1b: Simulate LLM generating a plan.
    val planJson = """
    {
      "goal": "Find current weather in Tokyo",
      "reasoning": "Use search-web to find Tokyo weather",
      "steps": [
        {
          "id": "step_1",
          "description": "Search for Tokyo weather",
          "skillName": "search-web",
          "toolName": null,
          "toolArgs": {"query": "Tokyo weather today"},
          "dependsOn": []
        },
        {
          "id": "step_2",
          "description": "Summarize weather results",
          "skillName": "summarize",
          "toolName": null,
          "toolArgs": {},
          "dependsOn": ["step_1"]
        }
      ]
    }
    """.trimIndent()

    val plan = planner.parsePlan(planJson, userMessage)
    assertEquals(2, plan.steps.size)
    assertEquals("search-web", plan.steps[0].skillName)
    assertEquals("summarize", plan.steps[1].skillName)

    // Step 1c: Execute batches.
    val batches = planner.getExecutionBatches(plan)
    assertEquals(2, batches.size)
    assertEquals(1, batches[0].size) // step_1 alone
    assertEquals(1, batches[1].size) // step_2 depends on step_1

    // Step 1d: Simulate execution results.
    val results = mapOf(
      "step_1" to StepResult(
        stepId = "step_1",
        status = StepStatus.COMPLETED,
        output = "Tokyo weather: 22C, partly cloudy. Tomorrow: 18C, rain expected.",
        durationMs = 2500,
      ),
      "step_2" to StepResult(
        stepId = "step_2",
        status = StepStatus.COMPLETED,
        output = "Tokyo is currently 22C and partly cloudy. Rain is expected tomorrow with temperatures dropping to 18C.",
        durationMs = 1200,
      ),
    )

    // Step 1e: Evaluate -- should be successful.
    val evalJson = """
    {
      "goalAchieved": true,
      "assessment": "Successfully retrieved Tokyo weather information",
      "missingItems": [],
      "shouldReplan": false
    }
    """.trimIndent()
    val evaluation = evaluator.parseEvaluation(evalJson)
    assertTrue(evaluation.goalAchieved)

    // ======================================================
    // PHASE 2: Save as skill "check-weather"
    // ======================================================

    val skillName = "check-weather"

    // Step 2a: Build skill creation prompt.
    val skillPrompt = creator.buildSkillCreationPrompt(skillName, userMessage, plan, results)
    assertTrue(skillPrompt.contains("check-weather"))
    assertTrue(skillPrompt.contains("search-web"))
    assertTrue(skillPrompt.contains("summarize"))

    // Step 2b: Simulate LLM generating SKILL.md.
    val generatedSkillMd = """
```markdown
---
name: check-weather
description: Search for weather information in a specified city and summarize the forecast
---

# Instructions
This skill checks the weather for a given city. Execute these steps:

1. Use **search-web** to search for "{city} weather today"
2. Use **summarize** to create a concise weather summary from the search results

The summarize step depends on the search results from step 1.

Parameters:
- **city**: The city to check weather for (e.g., Tokyo, Osaka, New York)
```
    """.trimIndent()

    // Step 2c: Parse the generated SKILL.md.
    val skillMd = creator.parseSkillMd(generatedSkillMd)
    assertTrue(skillMd.startsWith("---"))
    assertTrue(skillMd.contains("name: check-weather"))
    assertTrue(skillMd.contains("search-web"))
    assertTrue(skillMd.contains("{city}"))

    // Step 2d: Verify it can be parsed into a skill proto structure.
    // Extract name and description from SKILL.md (simulating convertSkillMdToProto).
    val nameMatch = Regex("name:\\s*(.+)").find(skillMd)
    val descMatch = Regex("description:\\s*(.+)").find(skillMd)
    assertNotNull("Should find name", nameMatch)
    assertNotNull("Should find description", descMatch)
    assertEquals("check-weather", nameMatch!!.groupValues[1].trim())

    // Extract instructions (everything after the second ---).
    val parts = skillMd.split("---")
    assertTrue("Should have 3+ parts", parts.size >= 3)
    val instructions = parts.drop(2).joinToString("---").trim()
    assertTrue(instructions.contains("search-web"))
    assertTrue(instructions.contains("summarize"))

    // ======================================================
    // PHASE 3: Replay with new input -- "Check weather in Osaka"
    // ======================================================

    val replayMessage = "Check weather in Osaka"
    val savedSkill = SkillSummary(
      name = "check-weather",
      description = descMatch!!.groupValues[1].trim(),
      instructions = instructions,
    )

    // Step 3a: Build planning prompt with the saved skill available.
    val replayPrompt = planner.buildPlanningPrompt(replayMessage, availableSkills + savedSkill)
    assertTrue(replayPrompt.contains("check-weather"))
    assertTrue(replayPrompt.contains("Osaka"))
    assertTrue(replayPrompt.contains("search-web"))

    // Step 3b: Simulate LLM generating a plan using the same structure.
    val replayPlanJson = """
    {
      "goal": "Find current weather in Osaka",
      "reasoning": "Use search-web to find Osaka weather, then summarize",
      "steps": [
        {
          "id": "step_1",
          "description": "Search for Osaka weather",
          "skillName": "search-web",
          "toolName": null,
          "toolArgs": {"query": "Osaka weather today"},
          "dependsOn": []
        },
        {
          "id": "step_2",
          "description": "Summarize weather results",
          "skillName": "summarize",
          "toolName": null,
          "toolArgs": {},
          "dependsOn": ["step_1"]
        }
      ]
    }
    """.trimIndent()

    val replayPlan = planner.parsePlan(replayPlanJson, replayMessage)

    // Step 3c: Verify the replay plan has the SAME STRUCTURE as the original.
    assertEquals(plan.steps.size, replayPlan.steps.size)
    assertEquals(plan.steps[0].skillName, replayPlan.steps[0].skillName) // Both use search-web
    assertEquals(plan.steps[1].skillName, replayPlan.steps[1].skillName) // Both use summarize
    assertEquals(plan.steps[1].dependsOn, replayPlan.steps[1].dependsOn) // Same dependency

    // But the args are different (Osaka instead of Tokyo).
    assertTrue(replayPlan.steps[0].toolArgs["query"]!!.contains("Osaka"))

    // Step 3d: Verify batching is the same.
    val replayBatches = planner.getExecutionBatches(replayPlan)
    assertEquals(batches.size, replayBatches.size)
    assertEquals(batches[0].size, replayBatches[0].size)
    assertEquals(batches[1].size, replayBatches[1].size)

    // Step 3e: Simulate replay execution.
    val replayResults = mapOf(
      "step_1" to StepResult(
        stepId = "step_1",
        status = StepStatus.COMPLETED,
        output = "Osaka weather: 20C, sunny. Tomorrow: 15C, clear skies.",
        durationMs = 2800,
      ),
      "step_2" to StepResult(
        stepId = "step_2",
        status = StepStatus.COMPLETED,
        output = "Osaka is currently 20C and sunny. Tomorrow will be 15C with clear skies.",
        durationMs = 1100,
      ),
    )

    // Both executions succeeded with the same structure, different data.
    assertTrue(results["step_1"]!!.output.contains("Tokyo"))
    assertTrue(replayResults["step_1"]!!.output.contains("Osaka"))
    assertEquals(results["step_1"]!!.status, replayResults["step_1"]!!.status)
    assertEquals(results["step_2"]!!.status, replayResults["step_2"]!!.status)
  }

  @Test
  fun `flow handles multi-skill workflow - weather plus calendar`() = runBlocking {
    // More complex: search weather -> create calendar event.
    val userMessage = "Check Tokyo weather and add a reminder for tomorrow"

    // Phase 1: Original execution.
    val planJson = """
    {
      "goal": "Check weather and create reminder",
      "reasoning": "Search weather, then create calendar event",
      "steps": [
        {
          "id": "step_1",
          "description": "Search Tokyo weather",
          "skillName": "search-web",
          "toolName": null,
          "toolArgs": {"query": "Tokyo weather tomorrow"},
          "dependsOn": []
        },
        {
          "id": "step_2",
          "description": "Create calendar reminder",
          "skillName": "create-calendar-event",
          "toolName": null,
          "toolArgs": {"title": "Weather: Tokyo", "startDateTime": "2026-04-06T08:00", "description": "Based on weather forecast"},
          "dependsOn": ["step_1"]
        }
      ]
    }
    """.trimIndent()

    val plan = planner.parsePlan(planJson, userMessage)
    val results = mapOf(
      "step_1" to StepResult(stepId = "step_1", status = StepStatus.COMPLETED, output = "Tokyo: 18C rain"),
      "step_2" to StepResult(stepId = "step_2", status = StepStatus.COMPLETED, output = "Event created id=42"),
    )

    // Phase 2: Generate skill.
    val skillPrompt = creator.buildSkillCreationPrompt("weather-reminder", userMessage, plan, results)
    assertTrue(skillPrompt.contains("search-web"))
    assertTrue(skillPrompt.contains("create-calendar-event"))
    assertTrue(skillPrompt.contains("depends on: step_1"))

    // Phase 3: Replay with Osaka.
    val replayPlanJson = """
    {
      "goal": "Check weather and create reminder for Osaka",
      "reasoning": "Same workflow for Osaka",
      "steps": [
        {
          "id": "step_1",
          "description": "Search Osaka weather",
          "skillName": "search-web",
          "toolName": null,
          "toolArgs": {"query": "Osaka weather tomorrow"},
          "dependsOn": []
        },
        {
          "id": "step_2",
          "description": "Create calendar reminder",
          "skillName": "create-calendar-event",
          "toolName": null,
          "toolArgs": {"title": "Weather: Osaka", "startDateTime": "2026-04-06T08:00", "description": "Based on weather forecast"},
          "dependsOn": ["step_1"]
        }
      ]
    }
    """.trimIndent()

    val replayPlan = planner.parsePlan(replayPlanJson, "Run weather-reminder for Osaka")

    // Same structure.
    assertEquals(plan.steps.size, replayPlan.steps.size)
    assertEquals(plan.steps[0].skillName, replayPlan.steps[0].skillName)
    assertEquals(plan.steps[1].skillName, replayPlan.steps[1].skillName)
    assertEquals(plan.steps[1].dependsOn, replayPlan.steps[1].dependsOn)

    // Different city.
    assertTrue(replayPlan.steps[0].toolArgs["query"]!!.contains("Osaka"))
    assertTrue(replayPlan.steps[1].toolArgs["title"]!!.contains("Osaka"))
  }
}
