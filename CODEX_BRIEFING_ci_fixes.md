# PR #24 — fix CI job failures

PR: https://github.com/blayer/Mobile-Claw/pull/24
Branch: `feat/ios-port-phase-a` (already pushed locally as `5f19c43`).
Working tree: `/Users/nali/MyProject/Mobile-Claw` — note there are uncommitted bundle-ID-rename changes you should keep, do not revert.

Two CI jobs are failing on this PR. Fix both, commit the fixes on the same branch, and push. **Do not** create a new branch or new PR.

---

## Failure 1 — `ios-lint` (SwiftLint, exit code 2)

Job: https://github.com/blayer/Mobile-Claw/actions/runs/24965416903/job/73099248650

```
Done linting! Found 12 violations, 12 serious in 84 files.
##[error]Process completed with exit code 2.
```

All 12 violations are `force_unwrapping` (the `--strict` flag upgrades warnings → errors). Affected files include at least:

- `ios-app-wip/MobileClaw/UI/ModelSelect/ModelManagerView.swift` (1)
- `ios-app-wip/MobileClaw/UI/ModelSelect/ModelCatalog.swift` (1)
- `ios-app-wip/MobileClaw/UI/LlmChat/ChatViewModel.swift` (2)
- `ios-app-wip/MobileClaw/Persistence/Conversation.swift` (1)
- `ios-app-wip/MobileClaw/Persistence/ConversationStore.swift` (1)
- `ios-app-wip/MobileClawTests/SelfEvaluatorTests.swift` (1)
- 5 more — find them by running `swiftlint lint --strict --reporter github-actions-logging` from `ios-app-wip/`.

There are also two SwiftLint config warnings:

```
warning: 'unused_declaration' should be listed in the 'analyzer_rules' configuration section
warning: 'unused_import' should be listed in the 'analyzer_rules' configuration section
```

### What to fix

1. Open `ios-app-wip/.swiftlint.yml`. Move `unused_declaration` and `unused_import` from `opt_in_rules:` into a new `analyzer_rules:` section. Those rules only run under `swiftlint analyze`, not plain `swiftlint lint`.

2. For every `force_unwrapping` violation, **fix the code**, not the config — that's why the rule was opted in. Typical patterns to replace:
   - `try!` for SwiftData `ModelContainer` setup → use `do { try ... } catch { fatalError("...") }` if it really must crash on invariant violation, with a meaningful message; otherwise propagate the throw.
   - `Bundle.main.url(forResource:)!` → `guard let url = Bundle.main.url(...) else { return ... }`.
   - `as!` casts that are actually `as?` opportunities → switch to `as?` with a fallback.
   - Force-unwrap inside test code → use `XCTUnwrap(...)` instead.

   Do **not** disable the rule in `.swiftlint.yml`; the codebase wants it loud.

3. After every change, run `(cd ios-app-wip && swiftlint lint --strict --reporter github-actions-logging)` until exit code is 0.

---

## Failure 2 — `ios-test` (xcodebuild, exit code 64)

Job: https://github.com/blayer/Mobile-Claw/actions/runs/24965416903/job/73099248632

Two distinct errors:

```
xcodebuild: error: Unable to find a destination matching the provided destination specifier:
		{ platform:iOS Simulator, OS:latest, name:iPhone 16 Pro }

	Ineligible destinations for the "MobileClaw" scheme:
		{ ... name:Any iOS Device, error:iOS 18.0 is not installed. To use with Xcode, first download and install the platform }
```

```
xcodebuild: error: Existing file at -resultBundlePath
"/Users/runner/work/Mobile-Claw/Mobile-Claw/ios-app-wip/TestResults.xcresult"
```

### Root causes

- `macos-15` GitHub runners no longer ship `iPhone 16 Pro` matching `OS=latest` for iOS 17. `iPhone 16 Pro` is the simulator name we picked, but the OS that's actually installed differs from what we asked for.
- The workflow retries `xcodebuild test` if the first piped attempt fails — but the first attempt left a partial `TestResults.xcresult` directory, and the retry refuses to overwrite it.

### What to fix

Edit `.github/workflows/ci-ios.yml`:

1. **Simulator destination**: replace the hard-coded `iPhone 16 Pro,OS=latest` with logic that picks an actually-installed simulator. Two options — pick whichever is cleaner:
   - Use a generic destination: `-destination 'generic/platform=iOS Simulator'` (won't gather coverage but always builds).
   - Or, before the test step, pick a real simulator name dynamically: `xcrun simctl list devices available -j | jq -r '.devices | to_entries[] | select(.key | startswith("com.apple.CoreSimulator.SimRuntime.iOS")) | .value[]?.name' | head -1` then pass that into `-destination "platform=iOS Simulator,name=$NAME"`. Prefer the second so coverage gathers.

2. **Result bundle path collision**: before the second `xcodebuild` attempt (the `||` fallback), `rm -rf TestResults.xcresult`. Also, the current shape of the run (try with xcbeautify, fall back to plain) is brittle — if you can collapse to a single invocation with `set -o pipefail` and `xcbeautify --renderer github-actions || cat`, do that and drop the duplicate command entirely.

3. **xcbeautify install**: not present in the failure output, but for safety, add a step before the test runs that ensures `xcbeautify` is on the runner: `brew install xcbeautify` (idempotent — `brew install` no-ops when already installed).

---

## Constraints

- Do not skip the `--strict` SwiftLint flag.
- Do not edit `.swiftlint.yml` to disable `force_unwrapping` — fix the code instead.
- Do not change the iOS deployment target in `project.yml` (`iOS: "17.0"`).
- Do not commit `MobileClaw.xcodeproj/` regenerated output unless it's already tracked. Re-run `xcodegen` only if you modified `project.yml`.
- Keep all changes on the existing branch `feat/ios-port-phase-a`.

---

## Verification before pushing

```bash
cd /Users/nali/MyProject/Mobile-Claw/ios-app-wip
xcodegen   # only if project.yml changed
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -sdk iphonesimulator -scheme MobileClaw \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug test 2>&1 | tail -10
# → must end with TEST SUCCEEDED

swiftlint lint --strict --reporter github-actions-logging
# → must exit 0 with no violations
```

After both pass, commit + push:

```bash
git add -A
git commit -m "ci: fix SwiftLint --strict violations + iOS test runner destination"
git push
```

Then verify on GitHub: PR #24 ios-lint and ios-test should both be green.

---

## Deliverable

After fixes, write a short status file at `/Users/nali/MyProject/Mobile-Claw/CODEX_SOLUTION_ci_fixes.md` summarizing:

- Final commit SHA pushed.
- Number of force-unwrap violations fixed (should be 12) with file:line references.
- The exact CI workflow change that picks the simulator + cleans the result bundle.
- Any unexpected gotchas hit.
