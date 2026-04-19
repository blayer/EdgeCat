# Mobile-Claw: Challenges & Learnings

Building an agentic AI assistant that runs entirely on-device with a 2B/4B parameter LLM (Gemma-3 E2B via MediaPipe/LiteRT on Android). This document captures the key challenges encountered and the optimizations developed across 51 commits and ~20K lines of code.

---

## 1. Small Model Output Quality

### Challenge
A 2B model hallucates, produces malformed JSON, garbles dates, and inconsistently formats tool names. It cannot reliably follow complex multi-field instructions in a single pass.

### What we learned
- **Lenient parsing beats strict validation.** A recursive date normalizer that handles garbled outputs (missing hyphens, concatenated digits, "today at 11pm") recovered far more results than rejecting malformed input.
- **Normalize everything at the bridge layer.** Case-insensitive arg key matching (`datetime` vs `dateTime`), underscore-to-hyphen skill name normalization, and placeholder resolution all live in the orchestration bridge — the model never sees the inconsistency.
- **Give the model answers to copy, not problems to solve.** Pre-computing today's date and providing format examples in the prompt dramatically reduced date computation errors.
- **Trim prompts aggressively.** Removing redundant JSON fields, collapsing CoT instructions, and sharing format notes between plan/replan saved ~370 tokens — meaningful headroom in an 8K context window.

## 2. Orchestration Loop Design

### Challenge
A 2B model cannot plan, execute, and evaluate in a single LLM call. Monolithic prompts cause the model to lose track of the task midway.

### What we learned
- **Decompose into specialized stages.** The Plan -> Execute -> Evaluate loop with separate prompts per stage (Planner, ExecutionOrchestrator, SelfEvaluator, ResponseFormatter) lets each call focus on one job.
- **Dependency DAGs enable parallel execution.** The planner emits steps with explicit `dependsOn` fields; independent steps run concurrently while dependent steps wait.
- **Short-circuit when you can.** Skipping the evaluator LLM call when all steps completed cleanly saves one full inference per happy-path turn. Detect success programmatically before spending tokens on evaluation.
- **Hallucination guard at the evaluator.** The model sometimes rubber-stamps failures as `goalAchieved=true`. Scanning for refusal language ("I cannot", "not possible") in outputs catches this.

## 3. Thinking Mode Policy

### Challenge
Blanket thinking-on or thinking-off both hurt quality. Thinking helps the planner reason through multi-step DAGs but causes format drift in the formatter and rationalization in the evaluator.

### What we learned
- **Per-call-site thinking policy is essential.** We route Gemma's chain-of-thought selectively:
  - Planner (first pass): on — needs reasoning headroom
  - Replan: on only from iteration 2+ — escalate after a cheap retry fails
  - Evaluator / formatter / LLM-step: always off — prevents drift
- **Three user-facing modes (Auto, Off, Aggressive) cover all preferences** without exposing per-stage complexity. The proto zero-value maps to Auto, so no migration is needed.
- **Double-thinking is confusing UX.** When the model's thinking tokens and the agent's orchestration traces both display, users see two "thinking" phases. Chat follow-ups now use `allowThinking=false` to avoid this.

## 4. Self-Repair & Failure Recovery

### Challenge
Device skills fail unpredictably — Samsung alarm APIs differ from stock Android, permissions get denied, date formats vary by locale. A single failure shouldn't kill the entire orchestration.

### What we learned
- **Diagnose before replanning.** Sending failures to the LLM for diagnosis (alternative skill, different args, skip, update instructions) produces better replans than blindly retrying.
- **Inject diagnostic notes into the replan prompt.** This prevents the planner from repeating the same failure — it knows `set-alarm` failed on Samsung and should try `set-reminder` instead.
- **Persistent skill instruction updates are powerful.** When the LLM recommends updating a skill's instructions (e.g., "use ISO date format for this device"), the fix persists for all future invocations.
- **Simplify the retry loop.** We initially had a per-step diagnose-retry sub-loop; replacing it with raw error injection into the replan prompt eliminated LLM calls without losing recovery quality.

## 5. Memory & Conversation Context

### Challenge
The on-device KV cache resets when the app is killed. The planner runs on a fresh session every time. Follow-up messages ("what should we do then?") unnecessarily trigger full orchestration.

### What we learned
- **Three memory layers serve different purposes:**
  1. **Persistent memory** (Room/SQLite + FTS4): episodes, repairs, device facts — recalled into planning prompts for task-relevant context.
  2. **User portrait** (~200 tokens): durable profile injected into every chat and plan call — the model knows "I'm vegetarian" without being told each time.
  3. **Sliding window** (last K exchanges): prefilled into KV cache on conversation reopen — the model remembers recent back-and-forth.
- **Intent classification prevents wasted orchestration.** A rule-based classifier checks: chat patterns -> task keywords -> follow-up markers (with prior turn check) -> question length. "What should we do then?" routes to chat; "search for train schedules" routes to task. Task keywords override follow-up markers so "then set an alarm" still triggers orchestration.
- **Planner needs explicit conversation context.** Since the planner runs on a fresh session, recent exchanges must be passed as text in the prompt. Without this, "check train schedule" after discussing Tokyo searches for local trains instead of Tokyo trains.
- **Token budget matters.** Portrait (~200) + window K=6 (~1.4K) + planner base (~1.5K) + message + output reserve = ~4.1K of 8K ceiling. Every token counts.

## 6. OOM & Resource Management

### Challenge
Loading a 2B+ model can exhaust device memory, causing a silent SIGKILL with no user feedback.

### What we learned
- **Pre-flight memory checks prevent silent crashes.** Checking `ActivityManager.MemoryInfo` before model load — rejecting when available memory < 1.7x model size + 500MB LMK cushion — surfaces a readable error instead of a mysterious app kill.
- **Catch `OutOfMemoryError` as a fallback.** The pre-flight check can't cover every allocation pattern; a top-level catch ensures any slip-through gets the same error path.

## 7. Web Search on a 2B Model

### Challenge
The model can't reliably copy URLs from search results. Browser-based search via WebView hits CORS issues.

### What we learned
- **Auto-fetch and extract, don't ask the model to browse.** Fetching top search result URLs server-side, extracting clean content (skip nav/footer, prefer `<main>`/`<article>`), and feeding text to the formatter produces reliable answers.
- **Cite domains, not URLs.** The 2B model mangles long URLs; citing "according to weather.com" works reliably.
- **DuckDuckGo POST avoids CAPTCHA.** GET requests trigger bot detection; POST with a browser-like User-Agent does not.
- **Block-page detection prevents garbage input.** Check for paywall/cookie-wall markers before feeding HTML to the model.

## 8. Skill Architecture

### Challenge
Balancing a growing skill catalog (23 native + JS/MCP) while keeping the system prompt within token budget and the UI manageable.

### What we learned
- **Two-tier skill separation works well.** Base skills (18 always-on, hidden from UI) vs. regular skills (user-visible, editable). The system prompt always includes base skills; users manage the rest.
- **SKILL.md as the single source of truth.** Each skill has a markdown spec file that serves as both documentation and the LLM's instruction set. The planner reads these to understand available tools.
- **"Save as Skill" enables user-driven growth.** After a successful multi-step orchestration, users can capture the plan as a reusable parameterized skill. The LLM generates the SKILL.md; future invocations replay the same plan structure with different inputs.

## 9. Testing Strategy

### Challenge
An agentic system has three distinct failure surfaces: logic bugs (unit), flow bugs (integration), and device-specific bugs (on-device). Standard Android testing doesn't cover all three.

### What we learned
- **Three-level pipeline with fail-fast:**
  1. **Unit tests** (140+): planner parsing, date normalization, calculator, HTML extraction, evaluator, skill catalog — no device needed.
  2. **Integration tests**: save-as-skill flow, auto-repair loop, conversation context — mock LLM responses, test full orchestration flows.
  3. **On-device tests**: ADB-driven skill tests and orchestration scenarios on real hardware.
- **Parallel CI matters.** Splitting lint and unit tests into parallel jobs cut CI time significantly. Lint baseline suppresses pre-existing warnings so new code stays clean.
- **Golden tests catch prompt regressions.** Planner and skill-catalog tests verify that prompt changes don't break existing behavior.

## 10. Empty Conversation Cleanup

### Challenge
Creating a conversation and navigating away before sending any messages leaves ghost entries in the conversation list.

### What we learned
- **Filter at the query level.** `WHERE message_count > 0` in the DAO keeps the list clean without background cleanup jobs.
- **Reap on next creation.** `deleteEmptyConversations()` runs before each new conversation insert — lazy cleanup with zero background work.

---

## Stats

- **51 commits** from initial project to v0.1.0 release
- **324 files changed**, ~20,600 lines added
- **23 native device skills** + JS/MCP skill support
- **140+ unit and integration tests**
- **3-level test pipeline**: unit -> integration -> on-device
- **Target model**: Gemma-3 E2B (2B params, 8K context, ~4 chars/token)
