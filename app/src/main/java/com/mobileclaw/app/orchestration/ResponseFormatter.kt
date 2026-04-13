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
 * Utilities for the final user-facing response step.
 *
 * Design (from Claude/Gemini/Codex synthesis):
 * 1. Preprocess Kotlin [Map.toString] into indented key/value text so the 4B model doesn't
 *    have to decode `{k=v, items=[{…}]}` at generation time.
 * 2. Short-circuit trivial outputs (single scalar or list of scalars) with a Kotlin-rendered
 *    template — no LLM call needed.
 * 3. For the remaining cases, build a few-shot prompt that wraps the answer in `<msg>…</msg>`.
 *    The caller sets a stop sequence on `</msg>` to kill trailing filler.
 */
object ResponseFormatter {

  /**
   * Convert Kotlin map/list [toString] output into indented `key: value` text.
   *
   * Example input:  `{status=succeeded, result=[{title=A, url=B}, {title=C, url=D}]}`
   * Example output:
   * ```
   * status: succeeded
   * result:
   *   - title: A
   *     url: B
   *   - title: C
   *     url: D
   * ```
   *
   * Best-effort parser — if the input doesn't look like a map, returns it unchanged.
   */
  fun preprocess(raw: String): String {
    val trimmed = raw.trim()
    if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return raw
    return try {
      val (parsed, _) = parseValue(trimmed, 0)
      render(parsed, 0).trimEnd()
    } catch (e: Exception) {
      raw
    }
  }

  /**
   * If [raw] is a single scalar or a list of scalars, render it directly without an LLM call.
   * Returns null when the output needs LLM formatting.
   *
   * Handles:
   * - Plain strings (not containing `{` or `=`) → returned as-is
   * - `{status=succeeded, result=VALUE}` where VALUE is a scalar → returned
   * - `{status=succeeded, items=[a, b, c]}` where items are scalars → bullet list
   */
  fun tryTrivialRender(raw: String): String? {
    val trimmed = raw.trim()
    // Plain string — no structure to process.
    if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) {
      if (trimmed.length <= 200 && !trimmed.contains("=") && !trimmed.contains("Step:")) {
        return trimmed
      }
      return null
    }
    val parsed = try {
      parseValue(trimmed, 0).first
    } catch (e: Exception) {
      return null
    }
    if (parsed !is MapNode) return null
    // Drop bookkeeping keys.
    val data = parsed.entries.filterKeys { it != "status" && it != "error" }
    if (data.isEmpty()) return null
    // Single scalar value.
    if (data.size == 1) {
      val (_, v) = data.entries.first()
      if (v is Scalar) return v.text
      if (v is ListNode && v.items.all { it is Scalar }) {
        val items = v.items.map { (it as Scalar).text }
        if (items.isEmpty()) return null
        return items.joinToString("\n") { "• $it" }
      }
    }
    return null
  }

  /** Strip wrapper tags and leading filler from an LLM response. */
  fun extractMessage(response: String): String {
    val tagMatch = Regex("<msg>(.*?)(?:</msg>|$)", RegexOption.DOT_MATCHES_ALL).find(response)
    val body = tagMatch?.groupValues?.get(1)?.trim() ?: response.trim()
    // Strip common preamble even if tags were ignored.
    val preamble = Regex(
      "(?i)^(sure[!,.]?|of course[!,.]?|here(?:'s| is)[^:\\n]*:?|the (?:result|answer) is:?)\\s*",
    )
    return body.replace(preamble, "").trim()
  }

  /** Heuristic: is this output complex enough that thinking helps? */
  fun isComplexOutput(preprocessed: String): Boolean {
    val stepCount = Regex("(?m)^Step:").findAll(preprocessed).count()
    return stepCount >= 2 || preprocessed.length > 500
  }

  /** Build the formatter prompt with few-shot examples and `<msg>` wrapper. */
  fun buildPrompt(userMessage: String, preprocessed: String): String {
    return """
You rewrite raw tool output into a concise chat reply. Wrap your reply in <msg>...</msg>.

Rules:
- Use ONLY facts in "Raw result". Do not invent, guess, or add disclaimers.
- Copy numbers, names, and error messages exactly, character for character.
- No preamble ("Sure!", "Here's..."). No trailing chatter.
- If the raw result has multiple "Step:" blocks, the LAST step usually holds the answer — focus on it. Earlier steps (e.g. location lookup) are context; do not describe them.
- If the raw result has a "Page content from <url>" section, ANSWER the user's question using facts from that content. Cite ONLY the domain (e.g. "Source: accuweather.com") — never copy the full URL path, and never invent a path. Do NOT list the search result links.
- If there is no fetched page content, fall back to a short bulleted list of the top 3 result titles, citing only the domain for each (e.g. "• Coroutines guide — kotlinlang.org"). Never copy full URL paths.

Example — search with fetched content (ANSWER from content):
User: weather in Paris tomorrow
Raw result:
Search results for: weather in Paris tomorrow

1. Paris 14-day weather - weather.com
   https://weather.com/paris
   Updated hourly forecast for Paris, France.

Page content from https://weather.com/paris

Paris, France — Tomorrow: partly cloudy, high 18°C, low 11°C. Light winds 8 km/h. 20% chance of rain in the afternoon. Sunrise 6:42, sunset 20:15.
Reply: <msg>Paris tomorrow: partly cloudy, high 18°C, low 11°C, light winds 8 km/h, 20% chance of afternoon rain. Sunrise 6:42, sunset 20:15.
Source: weather.com</msg>

Example — error:
User: send sms to alice
Raw result:
status: failed
error: Permission denied
Reply: <msg>Couldn't send: SMS permission denied. Grant it in Settings and try again.</msg>

Now format this one. Remember: no preamble, copy values verbatim, wrap in <msg>.

User: ${userMessage}
Raw result:
${preprocessed}
Reply: <msg>""".trimIndent()
  }

  // ---- Internal tiny parser for Kotlin map/list toString ----

  private sealed interface Node
  private data class Scalar(val text: String) : Node
  private data class ListNode(val items: List<Node>) : Node
  private data class MapNode(val entries: Map<String, Node>) : Node

  private fun parseValue(s: String, start: Int): Pair<Node, Int> {
    val i = skipWs(s, start)
    return when {
      i >= s.length -> Scalar("") to i
      s[i] == '{' -> parseMap(s, i)
      s[i] == '[' -> parseList(s, i)
      else -> parseScalar(s, i)
    }
  }

  private fun parseMap(s: String, start: Int): Pair<MapNode, Int> {
    require(s[start] == '{')
    var i = start + 1
    val entries = linkedMapOf<String, Node>()
    i = skipWs(s, i)
    if (i < s.length && s[i] == '}') return MapNode(entries) to i + 1
    while (i < s.length) {
      i = skipWs(s, i)
      val keyEnd = findChar(s, i, '=')
      if (keyEnd < 0) break
      val key = s.substring(i, keyEnd).trim()
      val (value, next) = parseValue(s, keyEnd + 1)
      entries[key] = value
      i = skipWs(s, next)
      if (i < s.length && s[i] == ',') {
        i++
        continue
      }
      if (i < s.length && s[i] == '}') return MapNode(entries) to i + 1
      break
    }
    return MapNode(entries) to i
  }

  private fun parseList(s: String, start: Int): Pair<ListNode, Int> {
    require(s[start] == '[')
    var i = start + 1
    val items = mutableListOf<Node>()
    i = skipWs(s, i)
    if (i < s.length && s[i] == ']') return ListNode(items) to i + 1
    while (i < s.length) {
      val (value, next) = parseValue(s, i)
      items.add(value)
      i = skipWs(s, next)
      if (i < s.length && s[i] == ',') {
        i++
        continue
      }
      if (i < s.length && s[i] == ']') return ListNode(items) to i + 1
      break
    }
    return ListNode(items) to i
  }

  private fun parseScalar(s: String, start: Int): Pair<Scalar, Int> {
    val end = findScalarEnd(s, start)
    return Scalar(s.substring(start, end).trim()) to end
  }

  /** Find the comma, `}`, or `]` that terminates a scalar at brace depth 0. */
  private fun findScalarEnd(s: String, start: Int): Int {
    var depth = 0
    for (i in start until s.length) {
      val c = s[i]
      if (c == '{' || c == '[') depth++
      else if (c == '}' || c == ']') {
        if (depth == 0) return i
        depth--
      } else if (c == ',' && depth == 0) return i
    }
    return s.length
  }

  /** Find first occurrence of [target] at brace depth 0 starting at [from]. */
  private fun findChar(s: String, from: Int, target: Char): Int {
    var depth = 0
    for (i in from until s.length) {
      val c = s[i]
      if (c == '{' || c == '[') depth++
      else if (c == '}' || c == ']') {
        if (depth == 0) return -1
        depth--
      } else if (c == target && depth == 0) return i
    }
    return -1
  }

  private fun skipWs(s: String, i: Int): Int {
    var j = i
    while (j < s.length && s[j].isWhitespace()) j++
    return j
  }

  private fun render(node: Node, indent: Int): String {
    val pad = "  ".repeat(indent)
    return when (node) {
      is Scalar -> node.text
      is ListNode -> {
        if (node.items.isEmpty()) "[]"
        else node.items.joinToString("\n") { item ->
          when (item) {
            is Scalar -> "$pad- ${item.text}"
            is ListNode, is MapNode -> {
              val inner = render(item, indent + 1)
              val firstLine = inner.lineSequence().first().trimStart()
              val rest = inner.lineSequence().drop(1).joinToString("\n")
              if (rest.isEmpty()) "$pad- $firstLine"
              else "$pad- $firstLine\n$rest"
            }
          }
        }
      }
      is MapNode -> {
        if (node.entries.isEmpty()) "{}"
        else node.entries.entries.joinToString("\n") { (k, v) ->
          when (v) {
            is Scalar -> "$pad$k: ${v.text}"
            is ListNode -> if (v.items.isEmpty()) "$pad$k: []"
              else "$pad$k:\n${render(v, indent + 1)}"
            is MapNode -> if (v.entries.isEmpty()) "$pad$k: {}"
              else "$pad$k:\n${render(v, indent + 1)}"
          }
        }
      }
    }
  }
}
