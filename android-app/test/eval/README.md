# EdgeCat Android eval harness

Mirror of `ios-app-wip/test/eval/`. Drives an ADB-connected Android device
through a set of agentic tasks, captures a JSONL trace per run, and
produces an OQI-shaped report. The trace schema is byte-compatible with
the iOS scorers (`scorers/{structural,state,perf}.py` are shared) so
cross-platform comparison is direct.

## Layout

```
test/eval/
├── run.py                 # Runner: drives device via adb am start
├── compare.py             # A/B diff between two run dirs (exit codes 0/1/2)
├── README.md              # This file
├── datasets/
│   ├── schema.json        # Task schema
│   ├── v1_basic.jsonl     # Baseline tasks
│   ├── v2-androidworld.jsonl
│   ├── v3-androidworld-expanded.jsonl
│   └── v3_multi_turn.jsonl  # Multi-turn cases (parity with iOS)
├── scorers/
│   ├── structural.py      # plan_validity, tool_correctness, step_order_lcs, ...
│   ├── state.py           # output_regex + ADB-driven device-state checks
│   ├── perf.py            # latency_stats, thermal_events, peak_memory_mb
│   ├── test_scorers.py    # Smoke tests — `python -m pytest scorers/`
│   ├── test_run_log.py    # Tests for run_log.md renderer
│   └── test_state_verifiers.py  # Tests for the multi-turn state verifiers
├── scripts/
│   └── preflight.sh       # adb pm grant for runtime permissions
└── runs/<label>-<ts>/
    ├── results.json       # Full per-task rows + summary
    ├── results.partial.json  # Written after every task — Ctrl-C survives
    ├── report.md          # Human summary
    ├── run_log.md         # Per-turn transcript with latency + token approx
    └── traces/<run_id>.jsonl  # Raw device traces
```

## Quickstart

### One-time per device

```bash
# Pick a device (adb -s <serial> elsewhere if more than one).
adb devices

# Build + install the EdgeCat APK from the project root.
cd android-app
./gradlew :app:installDebug

# Pre-grant runtime permissions so the headless EvalActivity doesn't
# hang on permission dialogs.
test/eval/scripts/preflight.sh
```

### Run a dataset

```bash
python android-app/test/eval/run.py \
    --dataset datasets/v1_basic.jsonl \
    --label main
```

For a single task:

```bash
python android-app/test/eval/run.py \
    --dataset datasets/v3_multi_turn.jsonl \
    --task multi-weather-cloth-001
```

### Inspect

```bash
open android-app/test/eval/runs/main-*/report.md       # high-level summary
open android-app/test/eval/runs/main-*/run_log.md      # per-turn transcript
```

### Compare two runs

```bash
python android-app/test/eval/compare.py \
    runs/main-20260502-... \
    runs/exp-20260502-...
```

Exit codes: `0` = no regression, `1` = OQI dropped, `2` = error.

## How it works

`run.py` per task:

1. `adb shell am force-stop com.edgecat.app` (free LiteRT-LM memory between tasks).
2. Wait until `pidof com.edgecat.app` returns empty (force-stop returns before
   native threads fully exit; racing `am start` against cleanup yields a
   silently-failing run).
3. `adb shell rm -f /sdcard/Android/data/com.edgecat.app/files/edgecat-traces/<run_id>.jsonl`
   so the file-stability poll has a clean start.
4. Single-turn: `adb shell am start -a com.edgecat.app.EVAL_RUN -n com.edgecat.app/.eval.EvalActivity --es prompt "..." --es run_id "..."`.
   Multi-turn: same intent with `--es prompts_json '["p1","p2"]'`.
5. Poll the trace file size; treat 2 consecutive equal reads as final.
6. Pull the trace to `runs/<label>-<ts>/traces/<run_id>.jsonl`.
7. Score it (structural + state + perf scorers).
8. Save `results.partial.json` after each task — Ctrl-C survives.

## Trace schema

Each line is one of:

```json
{"type": "span", "run_id": "calc-001",
 "span": {"kind": "phase", "name": "plan",
          "start_ms": 1761617783447, "end_ms": 1761617801171,
          "duration_ms": 17723,
          "status": "ok", "thermal": 0, "mem_pss_mb": 3631,
          "attrs": {"prompt_chars": 6253, "response_chars": 602,
                    "thinking": true, "iteration": 0}}}
```

```json
{"type": "run", "run": {"run_id": "calc-001", "schema_version": 1,
 "user_message": "What is 42 times 17?", "final_status": "ok",
 "final_output": "714", "iteration": 0,
 "start_ms": 1761617783376, "end_ms": 1761617819172, "duration_ms": 35796,
 "plan": {...}, "step_results": {...}, "evaluation": {...},
 "extras": {"model_name": "...", "memory_isolated": true},
 "device": {"manufacturer": "Google", "model": "Pixel 7 Pro", "sdk": 34}}}
```

For multi-turn runs, each turn additionally emits `eval.start` (turn 0) /
`eval.turn-start` (turn N≥1) / `eval.turn-response` / `eval.turn-complete`
spans so `render_run_log()` can rebuild the per-turn transcript.

## Troubleshooting

- **"no model loaded"** — open the EdgeCat app first, pick a model in the
  manager, and let it finish initializing. Eval refuses to auto-pull a model
  per *Rule #7* (production config only).
- **Trace empty / missing** — the EvalActivity intent didn't reach the app.
  Verify the package is installed (`adb shell pm list packages | grep edgecat`)
  and that the trace dir is writable
  (`adb shell ls -la /sdcard/Android/data/com.edgecat.app/files/edgecat-traces`).
- **Permission dialogs hang** — re-run `scripts/preflight.sh`. Some
  permissions (e.g. `POST_NOTIFICATIONS`) only exist on API 33+; the script
  silently skips ones the device rejects.
- **Tasks time out** — check thermal throttling. Use `--cooldown-every` and
  `--thermal-stretch-after` to give the SoC a break and grant later tasks
  more wall-clock budget.

## CI guidance

- **Don't run full evals in CI.** A `v1_basic` run on a Pixel 7 Pro is 5–10
  min and needs Gemma sideloaded. Keep evals local-only or in a scheduled job.
- **Do** run scorer unit tests: `python -m pytest android-app/test/eval/scorers/`
  (fast + offline).
- **Do** run the JVM unit tests: `./gradlew :app:testDebugUnitTest` for
  Planner/EvalActivity coverage.
