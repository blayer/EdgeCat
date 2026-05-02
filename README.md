<p align="center">
  <img src="docs/icon.png" alt="EdgeCat" width="160" height="160">
</p>

# EdgeCat

**Agentic orchestration for on-device LLMs.** Turn a 2B/4B chat model into a task-executing assistant that plans, calls device skills, recovers from failure, and answers in natural language — all offline, on **Android and iOS**.

> Built on top of [Google AI Edge Gallery](https://github.com/google-ai-edge/gallery). EdgeCat is an extension focused on **expanding the skill system and layering agentic orchestration** (planner → executor → evaluator) around the same on-device runtime. All credit for the underlying model-hosting app, UI shell, and LiteRT-LM integration goes to the AI Edge Gallery team.

## Status (2026-05-01)

- **iOS / Android parity.** The Android orchestration stack (Planner, ExecutionOrchestrator, SelfEvaluator, ResponseFormatter, ThinkingPolicy, SkillCreator) is fully ported to iOS under `ios-app-wip/EdgeCat/Orchestration/`, including the eval harness and ~28 native skills (calendar, health, directions, PDFs, etc.). Android remains the primary platform; iOS is feature-complete on orchestration and tracking the same prompts.
- **Multi-turn robustness.** Planner now carries explicit pronoun-resolution and continuation rules; per-turn latency and token telemetry recorded by the eval harness; calendar.read surfaces free morning slots; multi-turn evaluation runs against four state verifiers.
- **Thinking Mode toggle.** `enable_thinking` is wired end-to-end into LiteRT-LM via extra_context. Default is **off** to preserve baseline latency; planner stays on, evaluator/formatter/LLM-step stay off (see [ThinkingPolicy](#thinking-policy-orchestrationthinkingpolicykt)).
- **Planner hardening.** JSON repair for small-model malformations, regex fallback for ambiguous inputs, dependency chaining for Q&A flows (`search-web → fetch-web-content`), and goal-keyword rescue for empty/placeholder args.
- **Skill tuning.** Calculator removed (hallucination surface); calendar/reminder skills now accept natural-language dates; descriptions sharpened to reduce mis-routing.

Active focus: multi-turn quality, planner prompt tuning, evaluator grounding. No major architectural changes pending.

## Download

- **Release APKs** — [GitHub Releases](https://github.com/blayer/EdgeCat/releases/latest). Signed, tagged builds produced by the `Release` workflow.
- **Debug APKs (per-commit)** — available as artifacts on each [CI run](https://github.com/blayer/EdgeCat/actions/workflows/ci.yml) for 14 days after the commit.

## Why orchestration?

A raw on-device model like Gemma-4-2B (8K context) can chat, but it can't reliably:

- **Call the right tool.** It hallucinates tool names (`generate_X`), misformats JSON, and skips dependencies.
- **Handle failure.** One wrong arg and the whole turn is lost — no retry, no alternative.
- **Stay grounded.** It invents URLs, paraphrases numbers, rubber-stamps its own refusals.
- **Fit the context.** A 29-skill catalog, tool outputs, and conversation history blow past 8K quickly.

EdgeCat wraps the base model in a **planner → executor → evaluator loop** that compensates for each of these weaknesses with targeted subsystems. The model stays the same; what changes is the scaffolding around it.

## Architecture at a glance

```
User request
     │
     ▼
┌──────────────┐    JSON plan (DAG of steps)
│   Planner    │─────────────────────────────────┐
└──────────────┘                                 │
     │                                           ▼
     │                              ┌──────────────────────┐
     │                              │ ExecutionOrchestrator│
     │                              │  • parallel batches  │
     │                              │  • native tools      │
     │                              │  • WebView skills    │
     │                              │  • LLM-only steps    │
     │                              └──────────────────────┘
     │                                           │
     │         ┌───────────────────────┐         │ step results
     │         │      Triage rules     │◀────────┘
     │         │ (skip LLM when clear) │
     │         └───────────────────────┘
     │                  │
     │                  ▼ ambiguous only
     │         ┌───────────────────────┐
     │         │    Self-Evaluator     │  rubric + evidence grounding
     │         └───────────────────────┘
     │                  │
     │    replan        │ goal achieved
     └──────────────────┤
                        ▼
              ┌──────────────────┐
              │ ResponseFormatter│  few-shot + stop sequence
              └──────────────────┘
                        │
                        ▼
                   Final reply
```

All five components call the **same on-device LLM** through a single `LlmInferenceProvider` interface. What makes the system work isn't a bigger model — it's the **prompts, guards, and routing decisions** between calls.

## Subsystems

### Planner (`orchestration/Planner.kt`)

Translates a natural-language request into a typed `ExecutionPlan` — a DAG of steps, each bound to a skill with concrete args.

- **Skill catalog rendering.** Splits the catalog into *base* skills (full detail) and *deferred* skills (name + description only). The deferred tier keeps the main prompt compact; the agent calls `search-skills` to load a deferred skill's full instructions only when it's actually needed.
- **Intent classifier.** Short greetings and chitchat are routed straight to the chat path without an LLM planning call. Rule-based, zero latency.
- **JSON repair.** Small models emit trailing commas, stray `,  ,` gaps, and bare skill names. The parser repairs common malformations before falling back to regex extraction.
- **Topological batching.** Independent steps in the DAG are grouped into parallel batches for the executor.
- **Shared date context.** Every plan is prefaced with today's date and tomorrow's date in ISO format; the prompt forbids words like "tomorrow" and "11pm" in tool args, forcing `yyyy-MM-ddTHH:mm` everywhere.

### Execution Orchestrator (`orchestration/ExecutionOrchestrator.kt`)

Runs the plan. Three execution paths, chosen per step:

| Path | Used for | Concurrency |
|---|---|---|
| **Native tool** | On-device features (calendar, SMS, location, web search, ...) | Parallel within a batch |
| **WebView JS** | Packaged skills with an `index.html` sandbox | Parallel within a batch |
| **LLM-only** | `summarize`, `compose` — pure text synthesis | Serialized (single Conversation) |

LLM steps are serialized through a `Mutex` because the LiteRT-LM Conversation is single-threaded. Tool-only batches parallelize freely — a plan like "get location AND search weather" runs both in flight simultaneously.

### Self-Evaluator (`orchestration/SelfEvaluator.kt`)

Decides whether the goal was achieved. Two modes:

- **Rubric mode** — when the planner emitted `successCriteria`, each criterion is judged individually. The model must produce a **verbatim quote** from a step output supporting `met=true`; the parser rejects paraphrased or invented quotes. This catches the "rubber-stamp" failure mode small models fall into when evaluating their own work.
- **Holistic mode** — fallback when criteria are absent.

Two layers sit before the LLM even sees the prompt:

- **Rules-first triage.** All steps COMPLETED with non-empty, error-free output → skip evaluation entirely. All FAILED with no recovery → skip, mark failure. Only ambiguous cases hit the LLM judge. Saves one inference per successful turn.
- **Relevance guard.** If none of the user's goal tokens appear in any step output, triage defers to the LLM instead of rubber-stamping clean-but-irrelevant work.
- **Refusal guard.** After the judge, output is scanned for refusal language ("I cannot", "not possible"). If the judge marked goalAchieved=true while the steps contain a refusal, the verdict is flipped. Small models occasionally approve their own excuses.

### Response Formatter (`orchestration/ResponseFormatter.kt`)

Turns raw tool output (Kotlin maps, search blobs, JSON dumps) into a natural chat reply.

- **Preprocessor.** A tiny hand-rolled parser converts `{status=succeeded, result=[{title=A, url=B}]}` into indented `key: value` text. The model never has to decode Kotlin's `toString()` syntax at generation time.
- **Trivial short-circuit.** Single scalars or flat lists render directly in Kotlin — no LLM call at all.
- **Few-shot with stop sequence.** The LLM is given 2 examples (content-based answer, error message) and wraps its reply in `<msg>…</msg>`. The caller sets `</msg>` as a stop sequence to kill trailing filler.
- **Multi-step weighting.** In sequential plans the final step almost always holds the answer (search, fetch, compose). That step gets 2800 chars of the prompt budget; earlier plumbing steps (location, device-info) get 400 chars each.
- **Domain-only citations.** 2B models can't reliably copy long URL paths (digit hallucination: `226396` becomes `2226396`). The formatter is instructed to cite only the domain — `Source: accuweather.com` — never the full URL.

### Thinking Policy (`orchestration/ThinkingPolicy.kt`)

Gemma's chain-of-thought mode roughly doubles latency. Blanket-on is wasteful; blanket-off degrades planning. EdgeCat turns thinking on surgically:

| Call site | AUTO mode |
|---|---|
| First-pass planner | On (unless request is trivial: short, or single-skill verb prefix) |
| Replan | On only from attempt 2+ |
| Evaluator | **Off** — CoT makes small models rationalize flipped verdicts |
| Formatter | **Off** — #1 source of format drift |
| LLM-only step | **Off** — pure synthesis, no reasoning needed |

### Skill Creator (`orchestration/SkillCreator.kt`)

After a successful multi-step run, the user can tap "Save as Skill." The creator asks the LLM to generalize the executed plan into a reusable `SKILL.md` with parameterized inputs (`{city}`, `{date}`), which gets written to the skill library and loaded on the next turn. Also powers **auto-repair**: when a step fails, the creator diagnoses the error and proposes updated skill instructions for future runs.

## Skill system

Skills are the unit of extensibility. Three kinds coexist:

- **Native app skills** (~28 baseline) — device features exposed through `DeviceSkills.kt`: calendar, contacts, photos, SMS, clipboard, location, web search, barcode scanning, and so on.
- **WebView JS skills** — packaged folders under `app/src/main/assets/skills/<name>/` with a `SKILL.md` (instructions) and optional `index.html` (sandboxed script). Good for stateful flows, scraping logic, API glue.
- **LLM-only skills** — `summarize` and `compose` live in the orchestrator itself and are routed straight to the model with dependency outputs in context.

A skill's `SKILL.md` is a plain markdown file with YAML frontmatter:

```markdown
---
name: search-web
description: Search the web and return results with titles and URLs.
---

# Instructions

Call the `run_js` tool using `index.html` with data containing:
- **query**: Required. Keyword search query.

Returns up to 8 results plus extracted content from the top hit...
```

The planner reads `description` for catalog listings and `instructions` when the skill is active. Skill creators can tag a skill as **deferred** (name-only in the catalog) — the agent calls `search-skills` to load its details on demand, keeping the 8K context window usable for long conversations.

## Memory

`MemoryRepository` stores episodes from past runs — the request, the plan, the outcome. On a new turn, memory is recalled into the planning prompt so the agent can reuse a known-working pattern. Episodes are tagged `success`, `partial`, or `failure` at the end of every run.

## Failure modes this addresses

| Failure mode (raw 2B) | EdgeCat mitigation |
|---|---|
| Hallucinates tool names | Constrained catalog; JSON repair; `search-skills` for unknowns |
| Mangles arg JSON | Typed `ExecutionPlan`; schema-bound parser with regex fallback |
| Dumps Kotlin `Map.toString()` at user | Preprocessor + few-shot formatter with `<msg>` wrapper |
| Butchers long URLs | Domain-only citation rule in formatter |
| Rubber-stamps failures | Evidence grounding, refusal guard, rules-first triage |
| One failure = dead turn | Evaluator → replan loop (up to 3 iterations); auto-repair of skill instructions |
| Date-format ambiguity | ISO-format rule in every plan; shared date note constant |
| 8K context blown by 29-skill catalog | Deferred-skill tier; step-output budgeting; trimmed few-shot |

## Directory layout

```
android-app/
├── app/src/main/java/com/edgecat/app/
│   ├── orchestration/                    ← plan→execute→evaluate loop
│   │   ├── OrchestrationController.kt
│   │   ├── Planner.kt                    ← NL → JSON plan
│   │   ├── ExecutionOrchestrator.kt      ← DAG execution, parallel batches
│   │   ├── SelfEvaluator.kt              ← rubric + evidence grounding
│   │   ├── ResponseFormatter.kt          ← raw output → chat reply
│   │   ├── ThinkingPolicy.kt             ← per-call-site CoT routing
│   │   ├── SkillCreator.kt               ← save-as-skill + auto-repair
│   │   └── OrchestrationTypes.kt
│   ├── customtasks/agentchat/
│   │   ├── DeviceSkills.kt               ← native device features
│   │   ├── OrchestrationBridge.kt        ← app ↔ orchestration glue
│   │   └── AgentChatTaskModule.kt        ← system prompt, model init
│   └── memory/                           ← episodic memory
├── app/src/main/assets/skills/           ← packaged SKILL.md + JS
└── test/                                 ← on-device test harness

ios-app-wip/EdgeCat/                  ← iOS port (parity with Android)
├── Orchestration/                    ← Planner, ExecutionOrchestrator, SelfEvaluator, ...
├── Skills/                           ← native iOS skill implementations
├── Eval/                             ← eval harness
├── Memory/                           ← episodic memory
├── Runtime/                          ← LiteRT-LM bridge
└── UI/                               ← chat, model manager, conversation history

docs/                                 ← project assets (icon, learnings)
```

## Running on-device tests

```bash
cd android-app/test
./orchestration.sh local-search           # single scenario
./orchestration.sh                        # all scenarios from TEST-PLAN.md
```

Each scenario validates plan creation, execution, and final-answer pattern on a connected Android device. Screenshots land in `android-app/test/screenshots/`.

## License

EdgeCat is released under the [Apache License, Version 2.0](LICENSE) — the same license as the upstream [Google AI Edge Gallery](https://github.com/google-ai-edge/gallery). Existing Apache 2.0 headers in ported source files are preserved verbatim.
