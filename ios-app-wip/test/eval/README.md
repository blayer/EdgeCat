# Mobile-Claw iOS eval harness

Mirror of `android-app/test/eval/`. Drives a Mobile-Claw iPhone simulator
through a set of agentic tasks, captures a JSONL trace per run, and
produces an OQI-shaped report. The trace schema is byte-compatible with
the Android scorers (`scorers/{structural,state,perf}.py` are copied
verbatim) so cross-platform comparison is direct.

## Layout

```
test/eval/
├── run.py                 # Runner: drives simulator via xcrun simctl
├── compare.py             # A/B diff between two run dirs (exit codes 0/1/2)
├── datasets/
│   ├── schema.json        # Task schema (copied from Android)
│   ├── v1_basic.jsonl     # Baseline tasks (copied)
│   ├── v2-androidworld.jsonl  # AndroidWorld set with skip_on_ios decoration
│   └── v1_ios_native.jsonl    # iOS-only skills (open-url, send-email, …)
├── scorers/
│   ├── structural.py      # plan_validity, tool_correctness, step_order_lcs, …
│   ├── state.py           # output_regex, state (iOS-skipped), llm_judge
│   ├── perf.py            # latency_stats, thermal_events, peak_memory_mb, tokens_per_sec
│   └── test_scorers.py    # smoke tests — `python -m pytest scorers/`
├── scripts/
│   └── preflight.sh       # xcrun simctl privacy grant for the eval services
└── runs/<label>-<ts>/
    ├── results.json       # full per-task rows + summary
    ├── results.partial.json  # written after every task — Ctrl-C survives
    ├── report.md          # human summary
    └── traces/<run_id>.jsonl  # raw device traces
```

## Quickstart

### One-time per simulator

```bash
# Find your simulator UDID.
xcrun simctl list devices available | grep iPhone

# Boot it (or do it from Xcode).
xcrun simctl boot 80A09B97-…

# Build + install the app.
cd ios-app-wip
xcodegen
xcodebuild -scheme MobileClaw -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=80A09B97-…" \
    -derivedDataPath /tmp/mc-build build
xcrun simctl install 80A09B97-… \
    /tmp/mc-build/Build/Products/Debug-iphonesimulator/MobileClaw.app

# Pre-flight permissions.
test/eval/scripts/preflight.sh 80A09B97-…
```

### Run a dataset

```bash
python ios-app-wip/test/eval/run.py \
    --dataset ios-app-wip/test/eval/datasets/v1_basic.jsonl \
    --label main \
    --udid 80A09B97-… \
    --bundle-id com.mobileclawapp.app \
    --model gemma-4-E2B-it.litertlm \
    --model-source ~/Models/gemma-4-E2B-it.litertlm
```

The first run pushes the (~3 GB) `.litertlm` model into the app's
sandbox; subsequent runs skip the copy when sizes match.

### Inspect

```bash
open ios-app-wip/test/eval/runs/main-*/report.md
```

### Compare two runs

```bash
python ios-app-wip/test/eval/compare.py \
    runs/main-20260427-… \
    runs/exp-20260427-…
```

Exit codes: `0` = no regression, `1` = OQI dropped, `2` = error.

## How it works

`run.py` per task:

1. `xcrun simctl terminate <udid> <bundle>` (kill prior run, free LiteRT-LM memory).
2. Wait ~3s for the process to release Metal + LiteRT-LM resources.
3. Delete the previous trace file (if any) so the file-stability poll has a clean start.
4. `xcrun simctl launch --setenv MOBILECLAW_EVAL_MODE=1 <udid> <bundle>` — the env var makes `MobileClawApp` render `EvalRunnerView` (a headless status surface) instead of the normal `AppRouter`. Mirrors Android's `EvalActivity` `noHistory=true` semantics.
5. `xcrun simctl openurl <udid> "mobileclaw://eval?prompt=…&runId=…&agentic=1"` — the URL handler in `EvalEntryPoint.swift` runs the orchestrator with an `EmptyMemoryProvider` (no SwiftData write-back) and a 90s model-init deadline.
6. Poll `Documents/claw-traces/<runId>.jsonl` size; treat 2 consecutive equal reads as final.
7. Copy the trace to `runs/<label>-<ts>/traces/<runId>.jsonl`.
8. Score it (six structural scorers + perf metrics + state verifier).
9. Save `results.partial.json` after each task — Ctrl-C survives.

## Trace schema

Each line is one of:

```json
{"type": "span", "run_id": "calc-001",
 "span": {"kind": "phase", "name": "plan",
          "start_ms": 1761617783447, "end_ms": 1761617801171,
          "duration_ms": 17723.0,
          "status": "ok", "thermal": 0, "mem_pss_mb": 3631,
          "attrs": {"prompt_chars": 6253, "response_chars": 602,
                    "thinking": true, "iteration": 0}}}
```

```json
{"type": "run", "run": {"run_id": "calc-001", "schema_version": 1,
 "user_message": "What is 42 times 17?", "final_status": "ok",
 "final_output": "714", "iteration": 0,
 "start_ms": 1761617783376, "end_ms": 1761617819172, "duration_ms": 35796,
 "plan": {…}, "step_results": {…}, "evaluation": {…},
 "extras": {"model_name": "gemma-4-E2B-it", "memory_isolated": true},
 "device": {"manufacturer": "Apple", "model": "iPhone",
            "system_version": "18.0"}}}
```

The trailing `eval-complete` event is the runner's "done" sentinel.

## Troubleshooting

- **"no model loaded"** — check `Documents/Models/<file>.litertlm` exists in the sim's sandbox via `xcrun simctl get_app_container <udid> com.mobileclawapp.app data`. Re-run with `--model-source` to push.
- **Trace empty / missing** — the env var didn't reach the app. Verify with `xcrun simctl launch --setenv MOBILECLAW_EVAL_MODE=1 …` and check `MobileClawApp.isEvalMode` reads the var.
- **Permission dialogs hang** — re-run `preflight.sh`. Some services require the app to NOT be running when granted; terminate first.
- **`get_app_container` returns nothing** — the app isn't installed on that sim. Run the install step.

## CI guidance

- **Don't run full evals in CI.** A `v1_basic` run on iPhone 17 Pro sim is 5–10 min and needs Gemma sideloaded. Keep evals local-only or in a scheduled job.
- **Do** run scorer unit tests: `python -m pytest ios-app-wip/test/eval/scorers/` (fast + offline).
- **Do** run the schema parity Swift tests: included in the regular `xcodebuild test` target.

## Real-device path (deferred)

The runner accepts `--device-mode {sim,device}` (currently only `sim`). For a real iPhone, `xcrun devicectl` replaces `simctl`:

- `xcrun devicectl device process launch` (Xcode 15+)
- `xcrun devicectl device process terminate`
- `xcrun devicectl device copy` to pull traces

There's no `simctl privacy grant` equivalent — permissions are user-driven; tap-through once before a run.
