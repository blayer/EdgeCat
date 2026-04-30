package com.edgecat.app.skills

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Walks every packaged SKILL.md under app/src/main/assets/skills/ and validates the YAML
 * frontmatter. Catches malformed skills at CI time instead of first-run on device.
 */
class SkillCatalogTest {

  private val skillsDir: File by lazy {
    // Tests run with working directory = app/. Fall back to repo root for IDE runs.
    val candidates = listOf(
      File("src/main/assets/skills"),
      File("app/src/main/assets/skills"),
    )
    candidates.first { it.isDirectory }
  }

  @Test
  fun `skills directory exists and is non-empty`() {
    assertTrue("skills/ not found at ${skillsDir.absolutePath}", skillsDir.isDirectory)
    val skillDirs = skillsDir.listFiles { f -> f.isDirectory } ?: emptyArray()
    assertTrue("no skill folders under ${skillsDir.absolutePath}", skillDirs.isNotEmpty())
  }

  @Test
  fun `every skill has a SKILL_md with non-empty name and description`() {
    val skillDirs = skillsDir.listFiles { f -> f.isDirectory } ?: emptyArray()
    for (dir in skillDirs) {
      val md = File(dir, "SKILL.md")
      assertTrue("missing SKILL.md in ${dir.name}", md.isFile)
      val fm = parseFrontmatter(md.readText())
      assertNotNull("no frontmatter in ${dir.name}/SKILL.md", fm)
      val name = fm!!["name"].orEmpty()
      val description = fm["description"].orEmpty()
      assertFalse("empty name in ${dir.name}/SKILL.md", name.isBlank())
      assertFalse("empty description in ${dir.name}/SKILL.md", description.isBlank())
    }
  }

  @Test
  fun `skill directory name matches frontmatter name`() {
    val skillDirs = skillsDir.listFiles { f -> f.isDirectory } ?: emptyArray()
    for (dir in skillDirs) {
      val md = File(dir, "SKILL.md")
      val fm = parseFrontmatter(md.readText()) ?: continue
      val name = fm["name"].orEmpty()
      assertEquals(
        "directory name '${dir.name}' does not match frontmatter name '$name'",
        dir.name,
        name,
      )
    }
  }

  @Test
  fun `no duplicate skill names across the catalog`() {
    val skillDirs = skillsDir.listFiles { f -> f.isDirectory } ?: emptyArray()
    val names = mutableListOf<String>()
    for (dir in skillDirs) {
      val fm = parseFrontmatter(File(dir, "SKILL.md").readText()) ?: continue
      fm["name"]?.takeIf { it.isNotBlank() }?.let { names.add(it) }
    }
    val dupes = names.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
    assertTrue("duplicate skill names: $dupes", dupes.isEmpty())
  }

  /**
   * Minimal YAML frontmatter reader: expects a leading `---` line, then `key: value` pairs
   * until a closing `---`. Enough for our flat frontmatter; not a general YAML parser.
   */
  private fun parseFrontmatter(text: String): Map<String, String>? {
    val lines = text.lines()
    if (lines.isEmpty() || lines[0].trim() != "---") return null
    val result = linkedMapOf<String, String>()
    for (i in 1 until lines.size) {
      val line = lines[i]
      if (line.trim() == "---") return result
      val idx = line.indexOf(':')
      if (idx <= 0) continue
      val key = line.substring(0, idx).trim()
      val value = line.substring(idx + 1).trim().trim('"', '\'')
      result[key] = value
    }
    return null
  }
}
