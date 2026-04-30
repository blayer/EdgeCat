package com.edgecat.app.integration

import com.edgecat.app.orchestration.Planner
import com.edgecat.app.orchestration.SkillSummary
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Integration test: conversation context and user portrait flow into the planner
 * so that referential follow-ups stay on-topic.
 */
@RunWith(RobolectricTestRunner::class)
class ConversationContextIntegrationTest {

  private lateinit var planner: Planner
  private val skills = listOf(
    SkillSummary(name = "search-web", description = "Search the web"),
    SkillSummary(name = "compose", description = "Write long-form text"),
  )

  @Before
  fun setUp() {
    planner = Planner()
  }

  // ─── Scenario: Tokyo trip follow-up ───

  @Test
  fun `referential follow-up routes to chat, not orchestration`() {
    // Turn 1: user asks about Tokyo weather → orchestration handled it.
    // Turn 2: "what should we do then?" — no task keyword, follow-up marker, prior turn exists.
    val result = planner.classifyIntent(
      "what should we do then?",
      hasPriorAssistantTurn = true,
    )
    assertEquals("chat", result)
  }

  @Test
  fun `explicit new task still routes to orchestration even with prior turn`() {
    // Same conversation, but user says something actionable.
    val result = planner.classifyIntent(
      "search for train schedules from Shinjuku to Hakone",
      hasPriorAssistantTurn = true,
    )
    assertEquals("task", result)
  }

  @Test
  fun `planning prompt with conversation context mentions prior topic`() {
    // Simulate: prior turns discussed Tokyo weather, now user asks about trains.
    val conversationContext = buildString {
      appendLine("User: check weather in tokyo today")
      appendLine("Assistant: Tokyo weather: rainy, 15°C. Bring an umbrella.")
      appendLine("User: the weather is not well in tokyo")
      appendLine("Assistant: Forecast: rain continues through Wednesday.")
    }
    val prompt = planner.buildPlanningPrompt(
      userMessage = "check train schedule and routes",
      skills = skills,
      conversationContext = conversationContext,
    )
    // The planner should see Tokyo context so it can plan Tokyo train searches.
    assertTrue("prompt should include prior Tokyo discussion",
      prompt.contains("tokyo"))
    assertTrue("prompt should include current request",
      prompt.contains("train schedule"))
    assertTrue("prompt should have context section",
      prompt.contains("Recent conversation"))
  }

  @Test
  fun `planning prompt without context has no stale section`() {
    val prompt = planner.buildPlanningPrompt(
      userMessage = "check train schedule",
      skills = skills,
      conversationContext = "",
    )
    assertFalse("no context header when empty", prompt.contains("Recent conversation"))
  }

  // ─── Scenario: portrait influences planning ───

  @Test
  fun `user portrait appears in planning prompt for personalized planning`() {
    val prompt = planner.buildPlanningPrompt(
      userMessage = "plan dinner nearby",
      skills = skills,
      userPortrait = "I'm vegetarian, live in San Francisco, prefer casual spots",
    )
    assertTrue("portrait should be in prompt", prompt.contains("vegetarian"))
    assertTrue("portrait should be in prompt", prompt.contains("San Francisco"))
    assertTrue("portrait header present", prompt.contains("About the user"))
  }

  @Test
  fun `portrait and context combine in planning prompt`() {
    val prompt = planner.buildPlanningPrompt(
      userMessage = "find me a restaurant there",
      skills = skills,
      userPortrait = "I'm vegetarian",
      conversationContext = "User: what's the best area in tokyo for food?\nAssistant: Shibuya and Shinjuku are popular.",
    )
    assertTrue("portrait present", prompt.contains("vegetarian"))
    assertTrue("context present", prompt.contains("Shibuya"))
    assertTrue("user request present", prompt.contains("restaurant"))
  }

  // ─── Scenario: classifier edge cases ───

  @Test
  fun `short ambiguous follow-up without prior turn defaults to chat`() {
    // "ok cool" is <= 3 words, no task keyword → chat even without prior turn.
    assertEquals("chat", planner.classifyIntent("ok cool", hasPriorAssistantTurn = false))
  }

  @Test
  fun `why question routes to chat with prior turn`() {
    assertEquals("chat", planner.classifyIntent("why?", hasPriorAssistantTurn = true))
  }

  @Test
  fun `why question without prior turn routes to chat (short)`() {
    // "why?" is <= 3 words, no task keyword → chat.
    assertEquals("chat", planner.classifyIntent("why?", hasPriorAssistantTurn = false))
  }

  @Test
  fun `compound follow-up with task keyword routes to task`() {
    // "so can you search for alternatives?" has follow-up "so" but also "search".
    assertEquals("task", planner.classifyIntent(
      "so can you search for alternatives?",
      hasPriorAssistantTurn = true,
    ))
  }
}
