package com.mobileclaw.app.orchestration

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SkillCreatorTest {

  private lateinit var creator: SkillCreator

  @Before
  fun setUp() {
    creator = SkillCreator()
  }

  // ─── buildSkillCreationPrompt ───

  @Test
  fun `prompt includes skill name`() {
    val plan = ExecutionPlan(
      goal = "check weather and remind",
      reasoning = "two steps",
      steps = listOf(
        PlanStep(id = "step_1", description = "Search weather", skillName = "search-web", toolArgs = mapOf("query" to "Tokyo weather")),
        PlanStep(id = "step_2", description = "Create reminder", skillName = "create-calendar-event", dependsOn = listOf("step_1")),
      ),
    )
    val results = mapOf(
      "step_1" to StepResult(stepId = "step_1", status = StepStatus.COMPLETED, output = "25C sunny"),
      "step_2" to StepResult(stepId = "step_2", status = StepStatus.COMPLETED, output = "Event created"),
    )

    val prompt = creator.buildSkillCreationPrompt("weather-reminder", "check tokyo weather and remind me", plan, results)
    assertTrue(prompt.contains("weather-reminder"))
    assertTrue(prompt.contains("search-web"))
    assertTrue(prompt.contains("create-calendar-event"))
    assertTrue(prompt.contains("check tokyo weather"))
    assertTrue(prompt.contains("SKILL.md"))
  }

  @Test
  fun `prompt includes step dependencies`() {
    val plan = ExecutionPlan(
      goal = "test",
      reasoning = "chain",
      steps = listOf(
        PlanStep(id = "step_1", description = "first"),
        PlanStep(id = "step_2", description = "second", dependsOn = listOf("step_1")),
      ),
    )
    val results = mapOf(
      "step_1" to StepResult(stepId = "step_1", status = StepStatus.COMPLETED, output = "ok"),
      "step_2" to StepResult(stepId = "step_2", status = StepStatus.COMPLETED, output = "ok"),
    )

    val prompt = creator.buildSkillCreationPrompt("my-skill", "do stuff", plan, results)
    assertTrue(prompt.contains("depends on: step_1"))
  }

  @Test
  fun `prompt includes tool args`() {
    val plan = ExecutionPlan(
      goal = "test",
      reasoning = "",
      steps = listOf(
        PlanStep(id = "step_1", description = "search", skillName = "search-web", toolArgs = mapOf("query" to "AI news")),
      ),
    )
    val results = mapOf(
      "step_1" to StepResult(stepId = "step_1", status = StepStatus.COMPLETED, output = "results"),
    )

    val prompt = creator.buildSkillCreationPrompt("news-skill", "search AI news", plan, results)
    assertTrue(prompt.contains("query=AI news"))
  }

  // ─── parseSkillMd ───

  @Test
  fun `parseSkillMd extracts clean content`() {
    val input = """
      ---
      name: my-skill
      description: Does something
      ---

      # Instructions
      Do the thing.
    """.trimIndent()

    val result = creator.parseSkillMd(input)
    assertTrue(result.startsWith("---"))
    assertTrue(result.contains("name: my-skill"))
    assertTrue(result.contains("# Instructions"))
  }

  @Test
  fun `parseSkillMd strips markdown code block`() {
    val input = """
      Here is the skill:
      ```markdown
      ---
      name: test-skill
      description: A test
      ---

      # Instructions
      Step 1: Do this
      ```
    """.trimIndent()

    val result = creator.parseSkillMd(input)
    assertTrue(result.startsWith("---"))
    assertTrue(result.contains("name: test-skill"))
    assertFalse(result.contains("```"))
    assertFalse(result.contains("Here is the skill"))
  }

  @Test
  fun `parseSkillMd strips yaml code block`() {
    val input = """
      ```yaml
      ---
      name: yaml-skill
      description: YAML test
      ---

      # Instructions
      Do stuff
      ```
    """.trimIndent()

    val result = creator.parseSkillMd(input)
    assertTrue(result.startsWith("---"))
    assertTrue(result.contains("name: yaml-skill"))
  }

  @Test
  fun `parseSkillMd handles content with prefix text`() {
    val input = "Sure! Here is the SKILL.md:\n\n---\nname: prefix-skill\ndescription: test\n---\n\n# Instructions\nDo it."

    val result = creator.parseSkillMd(input)
    assertTrue(result.startsWith("---"))
    assertTrue(result.contains("name: prefix-skill"))
    assertFalse(result.contains("Sure!"))
  }

  @Test
  fun `parseSkillMd returns input when no delimiter found`() {
    val input = "No delimiters here just plain text"
    val result = creator.parseSkillMd(input)
    assertEquals(input, result)
  }
}
