package com.edgecat.app.customtasks.agentchat

import kotlinx.coroutines.channels.Channel
import com.edgecat.app.common.AgentAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for the calculator expression evaluator in DeviceSkills.
 * Tests the pure evaluateExpression() function — no Android context needed.
 */
class CalculatorTest {

  private lateinit var skills: DeviceSkills

  @Before
  fun setUp() {
    val channel = Channel<AgentAction>(Channel.UNLIMITED)
    skills = DeviceSkills(
      contextProvider = { throw UnsupportedOperationException("No context in unit tests") },
      actionChannel = channel,
    )
  }

  // ─── Basic arithmetic ───

  @Test
  fun `addition`() {
    assertEquals(5.0, skills.evaluateExpression("2 + 3"), 0.0001)
  }

  @Test
  fun `subtraction`() {
    assertEquals(7.0, skills.evaluateExpression("10 - 3"), 0.0001)
  }

  @Test
  fun `multiplication`() {
    assertEquals(24.0, skills.evaluateExpression("6 * 4"), 0.0001)
  }

  @Test
  fun `division`() {
    assertEquals(2.5, skills.evaluateExpression("5 / 2"), 0.0001)
  }

  @Test
  fun `modulo`() {
    assertEquals(1.0, skills.evaluateExpression("7 % 3"), 0.0001)
  }

  // ─── Operator precedence ───

  @Test
  fun `multiplication before addition`() {
    assertEquals(14.0, skills.evaluateExpression("2 + 3 * 4"), 0.0001)
  }

  @Test
  fun `parentheses override precedence`() {
    assertEquals(20.0, skills.evaluateExpression("(2 + 3) * 4"), 0.0001)
  }

  @Test
  fun `nested parentheses`() {
    assertEquals(12.0, skills.evaluateExpression("((2 + 1) * (3 + 1))"), 0.0001)
  }

  // ─── Negative numbers ───

  @Test
  fun `negative number`() {
    assertEquals(-5.0, skills.evaluateExpression("-5"), 0.0001)
  }

  @Test
  fun `negative in expression`() {
    assertEquals(-2.0, skills.evaluateExpression("3 + -5"), 0.0001)
  }

  // ─── Decimals ───

  @Test
  fun `decimal arithmetic`() {
    assertEquals(7.1745, skills.evaluateExpression("47.83 * 0.15"), 0.0001)
  }

  @Test
  fun `tip calculation`() {
    assertEquals(9.1745, skills.evaluateExpression("47.83 * 0.15 + 2"), 0.0001)
  }

  // ─── Power ───

  @Test
  fun `power`() {
    assertEquals(8.0, skills.evaluateExpression("2 ^ 3"), 0.0001)
  }

  @Test
  fun `power with decimals`() {
    assertEquals(2.0, skills.evaluateExpression("4 ^ 0.5"), 0.0001)
  }

  // ─── Functions ───

  @Test
  fun `sqrt`() {
    assertEquals(12.0, skills.evaluateExpression("sqrt(144)"), 0.0001)
  }

  @Test
  fun `abs negative`() {
    assertEquals(5.0, skills.evaluateExpression("abs(-5)"), 0.0001)
  }

  @Test
  fun `log base 10`() {
    assertEquals(2.0, skills.evaluateExpression("log(100)"), 0.0001)
  }

  @Test
  fun `natural log`() {
    assertEquals(1.0, skills.evaluateExpression("ln(2.718281828)"), 0.001)
  }

  @Test
  fun `round`() {
    assertEquals(4.0, skills.evaluateExpression("round(3.7)"), 0.0001)
  }

  @Test
  fun `ceil`() {
    assertEquals(4.0, skills.evaluateExpression("ceil(3.1)"), 0.0001)
  }

  @Test
  fun `floor`() {
    assertEquals(3.0, skills.evaluateExpression("floor(3.9)"), 0.0001)
  }

  // ─── Constants ───

  @Test
  fun `pi`() {
    assertEquals(Math.PI, skills.evaluateExpression("pi"), 0.0001)
  }

  @Test
  fun `pi in expression`() {
    assertEquals(2 * Math.PI, skills.evaluateExpression("2 * pi"), 0.0001)
  }

  @Test
  fun `e constant`() {
    assertEquals(Math.E, skills.evaluateExpression("e"), 0.0001)
  }

  // ─── Complex expressions ───

  @Test
  fun `compound expression`() {
    // (100 + 50) / 3 = 50
    assertEquals(50.0, skills.evaluateExpression("(100 + 50) / 3"), 0.0001)
  }

  @Test
  fun `nested functions`() {
    assertEquals(3.0, skills.evaluateExpression("sqrt(abs(-9))"), 0.0001)
  }

  // ─── Error handling ───

  @Test
  fun `unknown function throws`() {
    try {
      skills.evaluateExpression("foo(5)")
      fail("Should have thrown")
    } catch (e: IllegalArgumentException) {
      assertTrue(e.message!!.contains("Unknown function"))
    }
  }

  @Test(expected = Exception::class)
  fun `unbalanced parens throws`() {
    skills.evaluateExpression("(2 + 3")
  }
}
