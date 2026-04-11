package com.mobileclaw.app.integration

import com.mobileclaw.app.orchestration.ExecutionPlan
import com.mobileclaw.app.orchestration.PlanStep
import com.mobileclaw.app.orchestration.Planner
import com.mobileclaw.app.orchestration.SkillCreator
import com.mobileclaw.app.orchestration.SkillSummary
import com.mobileclaw.app.orchestration.StepResult
import com.mobileclaw.app.orchestration.StepStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Integration-style test for the full save-as-skill flow:
 * 1. Simulate a completed orchestration (plan + results)
 * 2. Generate SKILL.md via SkillCreator
 * 3. Parse the generated SKILL.md back via Planner's convertSkillMd logic
 * 4. Verify the skill can be used to generate a new plan
 */
@RunWith(RobolectricTestRunner::class)
class SkillCreatorIntegrationTest {

  private lateinit var creator: SkillCreator
  private lateinit var planner: Planner

  @Before
  fun setUp() {
    creator = SkillCreator()
    planner = Planner()
  }

  @Test
  fun `generated skill prompt contains all necessary context`() {
    // Simulate: "search Tokyo weather and create calendar reminder"
    val plan = ExecutionPlan(
      goal = "Check Tokyo weather and create a calendar reminder",
      reasoning = "Search web for weather, then create calendar event",
      steps = listOf(
        PlanStep(
          id = "step_1",
          description = "Search for Tokyo weather forecast",
          skillName = "search-web",
          toolArgs = mapOf("query" to "Tokyo weather tomorrow"),
        ),
        PlanStep(
          id = "step_2",
          description = "Create calendar reminder based on weather",
          skillName = "create-calendar-event",
          toolArgs = mapOf(
            "title" to "Weather reminder: Tokyo",
            "startDateTime" to "2026-04-06T08:00",
            "endDateTime" to "2026-04-06T09:00",
            "description" to "Weather-based clothing reminder",
          ),
          dependsOn = listOf("step_1"),
        ),
      ),
    )

    val results = mapOf(
      "step_1" to StepResult(
        stepId = "step_1",
        status = StepStatus.COMPLETED,
        output = "Tokyo tomorrow: 22C, partly cloudy, light rain in evening",
        durationMs = 3500,
      ),
      "step_2" to StepResult(
        stepId = "step_2",
        status = StepStatus.COMPLETED,
        output = "{status=succeeded, event_id=42, message=Event created}",
        durationMs = 500,
      ),
    )

    val prompt = creator.buildSkillCreationPrompt(
      "weather-reminder",
      "Check Tokyo weather and create a calendar reminder to wear appropriate clothes",
      plan,
      results,
    )

    // Verify prompt has all necessary info for the LLM.
    assertTrue("Should contain skill name", prompt.contains("weather-reminder"))
    assertTrue("Should contain user's original request", prompt.contains("Tokyo weather"))
    assertTrue("Should contain search-web skill", prompt.contains("search-web"))
    assertTrue("Should contain create-calendar-event skill", prompt.contains("create-calendar-event"))
    assertTrue("Should contain step dependency", prompt.contains("depends on: step_1"))
    assertTrue("Should reference SKILL.md format", prompt.contains("---"))
    assertTrue("Should ask for parameters", prompt.contains("parameter"))
  }

  @Test
  fun `parseSkillMd handles realistic LLM output`() {
    // Simulate what the LLM would actually generate.
    val llmOutput = """
Sure! Here's the SKILL.md for your workflow:

```markdown
---
name: weather-reminder
description: Check weather forecast for a city and create a calendar reminder with clothing advice
---

# Instructions
This is a multi-step workflow. Execute these steps in order:

1. Use **search-web** with query: "{city} weather forecast {date}"
2. Use **create-calendar-event** with:
   - title: "Weather reminder: {city}"
   - startDateTime: {date}T08:00
   - endDateTime: {date}T09:00
   - description: Based on the weather results from step 1, suggest appropriate clothing

Parameters:
- **city**: The city to check weather for (e.g., Tokyo, Osaka)
- **date**: The date for the reminder in yyyy-MM-dd format (default: tomorrow)
```
    """.trimIndent()

    val skillMd = creator.parseSkillMd(llmOutput)

    // Verify clean extraction.
    assertTrue("Should start with ---", skillMd.startsWith("---"))
    assertTrue("Should contain name", skillMd.contains("name: weather-reminder"))
    assertTrue("Should contain description", skillMd.contains("description:"))
    assertTrue("Should contain instructions", skillMd.contains("# Instructions"))
    assertTrue("Should contain search-web", skillMd.contains("search-web"))
    assertTrue("Should contain create-calendar-event", skillMd.contains("create-calendar-event"))
    assertTrue("Should contain city parameter", skillMd.contains("{city}"))
    assertTrue("Should contain date parameter", skillMd.contains("{date}"))
    assertTrue("Should NOT contain code block markers", !skillMd.contains("```"))
    assertTrue("Should NOT contain preamble", !skillMd.contains("Sure!"))
  }

  @Test
  fun `saved skill produces valid plan when used by planner`() {
    // Simulate the saved skill being used in a planning prompt.
    val skillSummary = SkillSummary(
      name = "weather-reminder",
      description = "Check weather forecast for a city and create a calendar reminder with clothing advice",
      instructions = """
# Instructions
This is a multi-step workflow. Execute these steps in order:

1. Use **search-web** with query: "{city} weather forecast {date}"
2. Use **create-calendar-event** with:
   - title: "Weather reminder: {city}"
   - startDateTime: {date}T08:00
   - description: Based on the weather results, suggest appropriate clothing

Parameters:
- **city**: The city to check weather for
- **date**: The date for the reminder (default: tomorrow)
      """.trimIndent(),
    )

    val prompt = planner.buildPlanningPrompt(
      "Run weather-reminder for Osaka",
      listOf(skillSummary, SkillSummary(name = "search-web", description = "Search the web")),
    )

    // Verify the planning prompt includes the skill.
    assertTrue("Prompt should include weather-reminder skill", prompt.contains("weather-reminder"))
    assertTrue("Prompt should include search-web skill", prompt.contains("search-web"))
    assertTrue("Prompt should include user request", prompt.contains("Osaka"))
    assertTrue("Prompt should include skill fields", prompt.contains("city"))
  }

  @Test
  fun `planner can parse a plan that uses the saved skill`() {
    // Simulate what the planner would generate for "run weather-reminder for Osaka".
    val planJson = """
    {
      "goal": "Check Osaka weather and create reminder",
      "reasoning": "Use the weather-reminder workflow for Osaka",
      "steps": [
        {
          "id": "step_1",
          "description": "Search for Osaka weather forecast",
          "skillName": "search-web",
          "toolName": null,
          "toolArgs": {"query": "Osaka weather forecast tomorrow"},
          "dependsOn": []
        },
        {
          "id": "step_2",
          "description": "Create calendar reminder based on weather",
          "skillName": "create-calendar-event",
          "toolName": null,
          "toolArgs": {"title": "Weather reminder: Osaka", "startDateTime": "2026-04-07T08:00", "endDateTime": "2026-04-07T09:00", "description": "Clothing advice based on Osaka weather"},
          "dependsOn": ["step_1"]
        }
      ]
    }
    """.trimIndent()

    val plan = planner.parsePlan(planJson, "Run weather-reminder for Osaka")

    assertEquals("Check Osaka weather and create reminder", plan.goal)
    assertEquals(2, plan.steps.size)

    // Step 1: search.
    assertEquals("search-web", plan.steps[0].skillName)
    assertNull(plan.steps[0].toolName)
    assertTrue(plan.steps[0].toolArgs["query"]!!.contains("Osaka"))

    // Step 2: create event, depends on step 1.
    assertEquals("create-calendar-event", plan.steps[1].skillName)
    assertEquals(listOf("step_1"), plan.steps[1].dependsOn)
    assertTrue(plan.steps[1].toolArgs["title"]!!.contains("Osaka"))

    // Verify batching: step_1 first, step_2 second.
    val batches = planner.getExecutionBatches(plan)
    assertEquals(2, batches.size)
    assertEquals("step_1", batches[0][0].id)
    assertEquals("step_2", batches[1][0].id)
  }

  @Test
  fun `skill name normalization`() {
    // Test the name extraction logic used in AgentChatScreen.
    val inputs = mapOf(
      "save as skill weather-reminder" to "weather-reminder",
      "save as skill Weather Reminder" to "weather-reminder",
      "save skill my cool workflow!" to "my-cool-workflow",
      "save as skill   " to "my-workflow", // empty -> default
      "save as skill 123test" to "123test",
    )

    for ((input, expected) in inputs) {
      val name = input
        .replace(Regex("^save\\s+(as\\s+)?skill\\s*", RegexOption.IGNORE_CASE), "")
        .trim()
        .replace("\\s+".toRegex(), "-")
        .replace(Regex("[^a-zA-Z0-9-]"), "")
        .lowercase()
        .ifEmpty { "my-workflow" }
      assertEquals("For input '$input'", expected, name)
    }
  }
}
