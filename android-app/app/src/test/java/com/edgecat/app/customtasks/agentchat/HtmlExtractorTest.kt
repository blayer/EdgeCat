package com.edgecat.app.customtasks.agentchat

import kotlinx.coroutines.channels.Channel
import com.edgecat.app.common.AgentAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for HTML-to-text extraction and search result parsing in DeviceSkills.
 * Tests pure string functions — no Android context needed.
 */
class HtmlExtractorTest {

  private lateinit var skills: DeviceSkills

  @Before
  fun setUp() {
    val channel = Channel<AgentAction>(Channel.UNLIMITED)
    skills = DeviceSkills(
      contextProvider = { throw UnsupportedOperationException("No context in unit tests") },
      actionChannel = channel,
    )
  }

  // ─── extractTextFromHtml ───

  @Test
  fun `strips HTML tags`() {
    val html = "<p>Hello <b>world</b></p>"
    val text = skills.extractTextFromHtml(html)
    assertEquals("Hello world", text.trim())
  }

  @Test
  fun `removes script blocks`() {
    val html = "<p>Before</p><script>alert('x')</script><p>After</p>"
    val text = skills.extractTextFromHtml(html)
    assertTrue(text.contains("Before"))
    assertTrue(text.contains("After"))
    assertFalse(text.contains("alert"))
  }

  @Test
  fun `removes style blocks`() {
    val html = "<style>.foo { color: red; }</style><p>Content</p>"
    val text = skills.extractTextFromHtml(html)
    assertFalse(text.contains("color"))
    assertTrue(text.contains("Content"))
  }

  @Test
  fun `decodes HTML entities`() {
    val html = "Tom &amp; Jerry &lt;3&gt; &quot;cheese&quot;"
    val text = skills.extractTextFromHtml(html)
    assertEquals("Tom & Jerry <3> \"cheese\"", text)
  }

  @Test
  fun `converts br and p to newlines`() {
    val html = "Line one<br>Line two<p>Paragraph</p>"
    val text = skills.extractTextFromHtml(html)
    assertTrue(text.contains("Line one"))
    assertTrue(text.contains("Line two"))
    assertTrue(text.contains("Paragraph"))
  }

  @Test
  fun `collapses whitespace`() {
    val html = "<p>  Too   many    spaces  </p>"
    val text = skills.extractTextFromHtml(html)
    assertFalse(text.contains("  "))
  }

  @Test
  fun `handles empty input`() {
    assertEquals("", skills.extractTextFromHtml(""))
  }

  // ─── extractDuckDuckGoResults ───

  @Test
  fun `parses DuckDuckGo result links with single quotes`() {
    // DuckDuckGo lite uses single quotes for class attributes and href before class.
    val html = """
      <a rel="nofollow" href="https://example.com" class='result-link'>Example Title</a>
      <td class='result-snippet'>This is a snippet.</td>
    """.trimIndent()
    val results = skills.extractDuckDuckGoResults(html)
    assertTrue(results.contains("Example Title"))
    assertTrue(results.contains("https://example.com"))
    assertTrue(results.contains("This is a snippet."))
  }

  @Test
  fun `parses DuckDuckGo result links with double quotes`() {
    val html = """
      <a href="https://example.com" class="result-link">Example Title</a>
      <td class="result-snippet">This is a snippet.</td>
    """.trimIndent()
    val results = skills.extractDuckDuckGoResults(html)
    assertTrue(results.contains("Example Title"))
    assertTrue(results.contains("https://example.com"))
  }

  @Test
  fun `handles no results gracefully`() {
    val html = "<html><body>No results found</body></html>"
    val results = skills.extractDuckDuckGoResults(html)
    // Should fall back to text extraction
    assertTrue(results.contains("No results found"))
  }

  @Test
  fun `limits to 8 results`() {
    val sb = StringBuilder()
    for (i in 1..15) {
      sb.append("""<a rel="nofollow" href="https://ex.com/$i" class='result-link'>Result $i</a>""")
      sb.append("""<td class='result-snippet'>Snippet $i</td>""")
    }
    val results = skills.extractDuckDuckGoResults(sb.toString())
    // Should have results 1-8 but not 9+
    assertTrue(results.contains("Result 1"))
    assertTrue(results.contains("Result 8"))
    assertFalse(results.contains("Result 9"))
  }
}
