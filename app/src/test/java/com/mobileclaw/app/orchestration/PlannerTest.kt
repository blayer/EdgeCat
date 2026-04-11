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
class PlannerTest {

  private lateinit var planner: Planner

  @Before
  fun setUp() {
    planner = Planner()
  }

  // ─── parsePlan: valid JSON ───

  @Test
  fun `parsePlan handles well-formed JSON`() {
    val json = """
      {
        "goal": "search the web",
        "reasoning": "Use search skill",
        "steps": [
          {
            "id": "step_1",
            "description": "Search for weather",
            "skillName": "search-web",
            "toolName": null,
            "toolArgs": {"query": "Tokyo weather"},
            "dependsOn": []
          }
        ]
      }
    """.trimIndent()

    val plan = planner.parsePlan(json, "search the web")
    assertEquals("search the web", plan.goal)
    assertEquals("Use search skill", plan.reasoning)
    assertEquals(1, plan.steps.size)
    assertEquals("step_1", plan.steps[0].id)
    assertEquals("search-web", plan.steps[0].skillName)
    assertNull(plan.steps[0].toolName)
    assertEquals("Tokyo weather", plan.steps[0].toolArgs["query"])
    assertTrue(plan.steps[0].dependsOn.isEmpty())
  }

  @Test
  fun `parsePlan handles JSON in markdown code block`() {
    val markdown = """
      Here is the plan:
      ```json
      {
        "goal": "calculate tip",
        "reasoning": "simple math",
        "steps": [
          {
            "id": "step_1",
            "description": "Calculate 15% of 50",
            "skillName": "calculator",
            "toolName": null,
            "toolArgs": {"expression": "50 * 0.15"},
            "dependsOn": []
          }
        ]
      }
      ```
    """.trimIndent()

    val plan = planner.parsePlan(markdown, "calculate tip")
    assertEquals("calculate tip", plan.goal)
    assertEquals(1, plan.steps.size)
    assertEquals("calculator", plan.steps[0].skillName)
    assertEquals("50 * 0.15", plan.steps[0].toolArgs["expression"])
  }

  @Test
  fun `parsePlan handles multi-step plan with dependencies`() {
    val json = """
      {
        "goal": "search and summarize",
        "reasoning": "two-step process",
        "steps": [
          {
            "id": "step_1",
            "description": "Search the web",
            "skillName": "search-web",
            "toolName": null,
            "toolArgs": {"query": "AI news"},
            "dependsOn": []
          },
          {
            "id": "step_2",
            "description": "Summarize results",
            "skillName": "summarize",
            "toolName": null,
            "toolArgs": {},
            "dependsOn": ["step_1"]
          }
        ]
      }
    """.trimIndent()

    val plan = planner.parsePlan(json, "search and summarize")
    assertEquals(2, plan.steps.size)
    assertEquals(listOf("step_1"), plan.steps[1].dependsOn)
  }

  @Test
  fun `parsePlan treats toolName null string as null`() {
    val json = """
      {
        "goal": "test",
        "reasoning": "test",
        "steps": [
          {
            "id": "step_1",
            "description": "test step",
            "skillName": "calculator",
            "toolName": "null",
            "toolArgs": {},
            "dependsOn": []
          }
        ]
      }
    """.trimIndent()

    val plan = planner.parsePlan(json, "test")
    assertNull(plan.steps[0].toolName)
  }

  @Test
  fun `parsePlan treats empty skillName as null`() {
    val json = """
      {
        "goal": "test",
        "reasoning": "test",
        "steps": [
          {
            "id": "step_1",
            "description": "test step",
            "skillName": "",
            "toolName": null,
            "toolArgs": {},
            "dependsOn": []
          }
        ]
      }
    """.trimIndent()

    val plan = planner.parsePlan(json, "test")
    assertNull(plan.steps[0].skillName)
  }

  // ─── parsePlan: fallback parsing ───

  @Test
  fun `parsePlan falls back to regex for non-JSON text`() {
    val text = """
      Step 1: Search for weather in Tokyo
      Step 2: Summarize the results
    """.trimIndent()

    val plan = planner.parsePlan(text, "weather in Tokyo")
    assertEquals("weather in Tokyo", plan.goal)
    assertTrue(plan.steps.isNotEmpty())
  }

  @Test
  fun `parsePlan creates single step for unstructured text`() {
    val text = "I don't know how to respond"

    val plan = planner.parsePlan(text, "do something")
    assertEquals("do something", plan.goal)
    assertEquals(1, plan.steps.size)
    assertEquals("step_1", plan.steps[0].id)
  }

  // ─── getExecutionBatches ───

  @Test
  fun `getExecutionBatches empty plan returns empty`() {
    val plan = ExecutionPlan(goal = "test", reasoning = "", steps = emptyList())
    val batches = planner.getExecutionBatches(plan)
    assertTrue(batches.isEmpty())
  }

  @Test
  fun `getExecutionBatches single step returns one batch`() {
    val plan = ExecutionPlan(
      goal = "test",
      reasoning = "",
      steps = listOf(PlanStep(id = "step_1", description = "do something")),
    )
    val batches = planner.getExecutionBatches(plan)
    assertEquals(1, batches.size)
    assertEquals(1, batches[0].size)
    assertEquals("step_1", batches[0][0].id)
  }

  @Test
  fun `getExecutionBatches parallel steps in same batch`() {
    val plan = ExecutionPlan(
      goal = "test",
      reasoning = "",
      steps = listOf(
        PlanStep(id = "step_1", description = "first"),
        PlanStep(id = "step_2", description = "second"),
        PlanStep(id = "step_3", description = "third"),
      ),
    )
    val batches = planner.getExecutionBatches(plan)
    assertEquals(1, batches.size)
    assertEquals(3, batches[0].size)
  }

  @Test
  fun `getExecutionBatches sequential dependencies create sequential batches`() {
    val plan = ExecutionPlan(
      goal = "test",
      reasoning = "",
      steps = listOf(
        PlanStep(id = "step_1", description = "search"),
        PlanStep(id = "step_2", description = "fetch", dependsOn = listOf("step_1")),
        PlanStep(id = "step_3", description = "summarize", dependsOn = listOf("step_2")),
      ),
    )
    val batches = planner.getExecutionBatches(plan)
    assertEquals(3, batches.size)
    assertEquals("step_1", batches[0][0].id)
    assertEquals("step_2", batches[1][0].id)
    assertEquals("step_3", batches[2][0].id)
  }

  @Test
  fun `getExecutionBatches diamond dependency pattern`() {
    // step_1 -> step_2a, step_2b -> step_3
    val plan = ExecutionPlan(
      goal = "test",
      reasoning = "",
      steps = listOf(
        PlanStep(id = "step_1", description = "start"),
        PlanStep(id = "step_2a", description = "branch a", dependsOn = listOf("step_1")),
        PlanStep(id = "step_2b", description = "branch b", dependsOn = listOf("step_1")),
        PlanStep(id = "step_3", description = "merge", dependsOn = listOf("step_2a", "step_2b")),
      ),
    )
    val batches = planner.getExecutionBatches(plan)
    assertEquals(3, batches.size)
    assertEquals(1, batches[0].size) // step_1
    assertEquals(2, batches[1].size) // step_2a, step_2b in parallel
    assertEquals(1, batches[2].size) // step_3
  }

  @Test
  fun `getExecutionBatches ignores unknown dependencies`() {
    val plan = ExecutionPlan(
      goal = "test",
      reasoning = "",
      steps = listOf(
        PlanStep(id = "step_1", description = "do something", dependsOn = listOf("nonexistent")),
      ),
    )
    val batches = planner.getExecutionBatches(plan)
    assertEquals(1, batches.size)
    assertEquals("step_1", batches[0][0].id)
  }

  @Test
  fun `getExecutionBatches handles cycle by forcing into one batch`() {
    val plan = ExecutionPlan(
      goal = "test",
      reasoning = "",
      steps = listOf(
        PlanStep(id = "step_1", description = "a", dependsOn = listOf("step_2")),
        PlanStep(id = "step_2", description = "b", dependsOn = listOf("step_1")),
      ),
    )
    val batches = planner.getExecutionBatches(plan)
    // Should handle cycle gracefully (not hang or crash).
    assertTrue(batches.isNotEmpty())
    assertEquals(2, batches.sumOf { it.size })
  }

  // ─── buildPlanningPrompt ───

  @Test
  fun `buildPlanningPrompt includes skill names`() {
    val skills = listOf(
      SkillSummary(name = "search-web", description = "Search the web"),
      SkillSummary(name = "calculator", description = "Do math"),
    )
    val prompt = planner.buildPlanningPrompt("what is 2+2", skills)
    assertTrue(prompt.contains("search-web"))
    assertTrue(prompt.contains("calculator"))
    assertTrue(prompt.contains("what is 2+2"))
  }

  @Test
  fun `buildPlanningPrompt includes date information`() {
    val prompt = planner.buildPlanningPrompt("reminder for tomorrow", emptyList())
    assertTrue(prompt.contains("Today:"))
    assertTrue(prompt.contains("Tomorrow:"))
    assertTrue(prompt.contains("yyyy-MM-ddTHH:mm"))
  }

  @Test
  fun `buildPlanningPrompt handles empty skills`() {
    val prompt = planner.buildPlanningPrompt("hello", emptyList())
    assertTrue(prompt.contains("No skills available."))
  }

  @Test
  fun `buildPlanningPrompt includes data fields from instructions`() {
    val skills = listOf(
      SkillSummary(
        name = "test-skill",
        description = "A test skill",
        instructions = "- **city**: the city name\n- **country**: the country code",
      ),
    )
    val prompt = planner.buildPlanningPrompt("test", skills)
    assertTrue(prompt.contains("city"))
    assertTrue(prompt.contains("country"))
  }

  // ─── buildReplanPrompt ───

  @Test
  fun `buildReplanPrompt includes previous results and evaluation`() {
    val prevPlan = ExecutionPlan(
      goal = "search",
      reasoning = "use search",
      steps = listOf(PlanStep(id = "step_1", description = "search")),
    )
    val results = mapOf(
      "step_1" to StepResult(stepId = "step_1", status = StepStatus.FAILED, error = "timeout"),
    )
    val evaluation = EvaluationResult(
      goalAchieved = false,
      assessment = "search failed",
      missingItems = listOf("search results"),
      shouldReplan = true,
    )

    val prompt = planner.buildReplanPrompt("search for news", prevPlan, results, evaluation)
    assertTrue(prompt.contains("search for news"))
    assertTrue(prompt.contains("FAILED"))
    assertTrue(prompt.contains("timeout"))
    assertTrue(prompt.contains("search results"))
    assertTrue(prompt.contains("Today:"))
  }
}
