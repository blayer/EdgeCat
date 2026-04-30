package com.edgecat.app.orchestration

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SelfEvaluatorTest {

  private lateinit var evaluator: SelfEvaluator

  @Before
  fun setUp() {
    evaluator = SelfEvaluator()
  }

  // ─── parseEvaluation: JSON ───

  @Test
  fun `parseEvaluation handles success JSON`() {
    val json = """
      {
        "goalAchieved": true,
        "assessment": "The search returned relevant results",
        "missingItems": [],
        "shouldReplan": false
      }
    """.trimIndent()

    val result = evaluator.parseEvaluation(json)
    assertTrue(result.goalAchieved)
    assertEquals("The search returned relevant results", result.assessment)
    assertTrue(result.missingItems.isEmpty())
    assertFalse(result.shouldReplan)
  }

  @Test
  fun `parseEvaluation handles failure JSON`() {
    val json = """
      {
        "goalAchieved": false,
        "assessment": "Search timed out",
        "missingItems": ["search results", "summary"],
        "shouldReplan": true
      }
    """.trimIndent()

    val result = evaluator.parseEvaluation(json)
    assertFalse(result.goalAchieved)
    assertTrue(result.shouldReplan)
    assertEquals(2, result.missingItems.size)
    assertEquals("search results", result.missingItems[0])
  }

  @Test
  fun `parseEvaluation handles JSON in markdown code block`() {
    val markdown = """
      Here is my evaluation:
      ```json
      {
        "goalAchieved": true,
        "assessment": "All steps completed",
        "missingItems": [],
        "shouldReplan": false
      }
      ```
    """.trimIndent()

    val result = evaluator.parseEvaluation(markdown)
    assertTrue(result.goalAchieved)
  }

  @Test
  fun `parseEvaluation handles JSON with extra text around it`() {
    val text = """
      Let me evaluate this...
      {"goalAchieved": false, "assessment": "failed", "missingItems": ["data"], "shouldReplan": true}
      That's my assessment.
    """.trimIndent()

    val result = evaluator.parseEvaluation(text)
    assertFalse(result.goalAchieved)
    assertTrue(result.shouldReplan)
  }

  // ─── parseEvaluation: fallback ───

  @Test
  fun `parseEvaluation fallback detects success`() {
    val text = "The goal was achieved successfully. All steps completed."
    val result = evaluator.parseEvaluation(text)
    assertTrue(result.goalAchieved)
  }

  @Test
  fun `parseEvaluation fallback detects failure`() {
    val text = "The goal was not achieved. The search failed and results are missing."
    val result = evaluator.parseEvaluation(text)
    assertFalse(result.goalAchieved)
    assertTrue(result.shouldReplan)
  }

  @Test
  fun `parseEvaluation fallback handles ambiguous text`() {
    val text = "Some steps completed but others failed. Results are incomplete."
    val result = evaluator.parseEvaluation(text)
    // Should not crash, should return a valid result.
    assertFalse(result.goalAchieved) // "failed" + "incomplete" are negative signals
  }

  // ─── buildEvaluationPrompt ───

  @Test
  fun `buildEvaluationPrompt includes goal and results`() {
    val plan = ExecutionPlan(
      goal = "find weather",
      reasoning = "use search",
      steps = listOf(
        PlanStep(id = "step_1", description = "search web"),
      ),
    )
    val results = mapOf(
      "step_1" to StepResult(
        stepId = "step_1",
        status = StepStatus.COMPLETED,
        output = "Tokyo: 25°C, sunny",
      ),
    )

    val prompt = evaluator.buildEvaluationPrompt("what is the weather in Tokyo", plan, results)
    assertTrue(prompt.contains("what is the weather in Tokyo"))
    assertTrue(prompt.contains("COMPLETED"))
    assertTrue(prompt.contains("Tokyo: 25°C"))
  }

  @Test
  fun `buildEvaluationPrompt includes errors for failed steps`() {
    val plan = ExecutionPlan(
      goal = "test",
      reasoning = "",
      steps = listOf(PlanStep(id = "step_1", description = "search")),
    )
    val results = mapOf(
      "step_1" to StepResult(
        stepId = "step_1",
        status = StepStatus.FAILED,
        error = "Connection timeout",
      ),
    )

    val prompt = evaluator.buildEvaluationPrompt("test", plan, results)
    assertTrue(prompt.contains("FAILED"))
    assertTrue(prompt.contains("Connection timeout"))
  }
}
