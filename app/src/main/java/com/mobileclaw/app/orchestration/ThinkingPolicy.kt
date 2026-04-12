/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

package com.mobileclaw.app.orchestration

/**
 * User-selectable policy for when to enable Gemma's chain-of-thought thinking mode.
 *
 * Thinking mode roughly doubles latency and consumes context tokens, but improves
 * structural reasoning (DAG planning, error diagnosis). For 2B/4B on 8K context we
 * want it surgically applied, not blanket-on.
 *
 * Proto stores as int: AUTO is the default (proto zero-value) so existing users pick
 * up the recommended balanced behavior without a migration.
 */
enum class ThinkingMode(val value: Int) {
  /** Balanced default: thinking on planner-first and repeat-replan; off everywhere else. */
  AUTO(0),

  /** Everything cold. Fastest, lowest-quality planning on ambiguous requests. */
  OFF(1),

  /** Thinking on for every reasoning-oriented site (planner, replan, save-as-skill). */
  AGGRESSIVE(2);

  companion object {
    fun fromInt(i: Int): ThinkingMode = entries.firstOrNull { it.value == i } ?: AUTO
  }
}

/**
 * Resolves whether thinking mode should be on for each call site.
 *
 * Call-site policy (based on cross-model research synthesis):
 * - planner-first : AUTO/AGGRESSIVE on (unless request is a trivial one-shot)
 * - replan        : AUTO on iteration ≥ 2 only; AGGRESSIVE always on
 * - evaluator     : always OFF — small models rationalize/flip on CoT
 * - format        : always OFF — #1 source of format drift
 * - llm-step      : always OFF — pure synthesis from prior context
 * - save-as-skill : only AGGRESSIVE (template gen rarely needs CoT)
 */
class ThinkingPolicy(val mode: ThinkingMode) {

  fun planner(userMessage: String, iteration: Int): Boolean = when (mode) {
    ThinkingMode.OFF -> false
    ThinkingMode.AUTO -> iteration == 0 && !isSimpleRequest(userMessage)
    ThinkingMode.AGGRESSIVE -> true
  }

  /** [replanAttempt] is 1-indexed: the 1st replan is 1, the 2nd is 2, etc. */
  fun replan(replanAttempt: Int): Boolean = when (mode) {
    ThinkingMode.OFF -> false
    ThinkingMode.AUTO -> replanAttempt >= 2
    ThinkingMode.AGGRESSIVE -> true
  }

  fun evaluator(): Boolean = false

  fun format(): Boolean = false

  fun llmStep(): Boolean = false

  fun saveAsSkill(): Boolean = mode == ThinkingMode.AGGRESSIVE

  /**
   * Heuristic: short requests or those starting with action verbs that map 1:1 to a
   * single skill don't need DAG reasoning. Keep the list conservative — a false
   * negative here just costs latency, a false positive breaks multi-step plans.
   */
  private fun isSimpleRequest(msg: String): Boolean {
    val trimmed = msg.trim()
    val wordCount = trimmed.split(WHITESPACE).size
    if (wordCount <= 4) return true
    return SIMPLE_PREFIX.containsMatchIn(trimmed)
  }

  private companion object {
    val WHITESPACE = Regex("\\s+")
    val SIMPLE_PREFIX = Regex(
      "(?i)^(what time|what['\u2019]?s? the time|set (a )?timer|set (a )?reminder|" +
        "call |text |open |launch |show me |turn (on|off) )"
    )
  }
}
