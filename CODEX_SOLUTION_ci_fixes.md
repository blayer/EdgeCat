# CI fixes status

- Final commit SHA pushed: not available from this sandbox. The current branch HEAD is `5f19c4394001214e354fc6bb6bf9db12f9019525`, but creating a new commit and pushing were blocked because writes inside `.git/` are denied here (`.git/index.lock: Operation not permitted`).

## Force-unwrap fixes

I removed all remaining `!` sites from `ios-app-wip/MobileClaw` and `ios-app-wip/MobileClawTests` in a direct source scan. The CI run cited 12 `force_unwrapping` violations; I could not rerun `swiftlint lint --strict` locally because `swiftlint` is not installed in this sandbox and `brew install swiftlint` is blocked by Homebrew directory permissions outside the workspace.

Primary force-unwrap removal sites:

1. `ios-app-wip/MobileClaw/Auth/HuggingFaceOAuthSession.swift:40`
2. `ios-app-wip/MobileClaw/Auth/HuggingFaceOAuthSession.swift:78`
3. `ios-app-wip/MobileClaw/Orchestration/ThinkingPolicy.swift:69`
4. `ios-app-wip/MobileClaw/UI/LlmChat/ChatView.swift:23`
5. `ios-app-wip/MobileClaw/UI/ModelSelect/ModelManagerView.swift:99`
6. `ios-app-wip/MobileClaw/UI/ModelSelect/ModelManagerView.swift:174`
7. `ios-app-wip/MobileClaw/UI/ModelSelect/ModelDownloader.swift:32`
8. `ios-app-wip/MobileClaw/UI/ModelSelect/ModelDownloader.swift:97`
9. `ios-app-wip/MobileClawTests/SamplerSettingsTests.swift:10`
10. `ios-app-wip/MobileClawTests/ConversationStoreTests.swift:16`
11. `ios-app-wip/MobileClawTests/ConversationStoreTests.swift:18`
12. `ios-app-wip/MobileClawTests/SwiftDataMemoryRepositoryTests.swift:17`

Additional hardening in the same linted target set:

- `ios-app-wip/MobileClawTests/ConversationStoreTests.swift:7`
- `ios-app-wip/MobileClawTests/ConversationStoreTests.swift:8`
- `ios-app-wip/MobileClawTests/ConversationStoreTests.swift:9`
- `ios-app-wip/MobileClawTests/SwiftDataMemoryRepositoryTests.swift:7`
- `ios-app-wip/MobileClawTests/SwiftDataMemoryRepositoryTests.swift:8`
- `ios-app-wip/MobileClawTests/SwiftDataMemoryRepositoryTests.swift:9`
- `ios-app-wip/MobileClawTests/SamplerSettingsTests.swift:5`
- `ios-app-wip/MobileClaw/Skills/Js/JsSkillRunner.swift:51`
- `ios-app-wip/MobileClaw/Skills/Js/JsSkillRunner.swift:58`

## Workflow change

- Moved `unused_import` and `unused_declaration` out of `opt_in_rules` into `analyzer_rules` in `ios-app-wip/.swiftlint.yml`.
- In `.github/workflows/ci-ios.yml`, added `brew install xcbeautify`, added a `Select simulator` step that parses `xcrun simctl list devices available -j` with `/usr/bin/python3` and exports the first available iOS simulator name to `SIMULATOR_NAME`, replaced the hard-coded `iPhone 16 Pro,OS=latest` destination with `-destination "platform=iOS Simulator,name=${SIMULATOR_NAME}"`, and removed the duplicate fallback `xcodebuild` invocation in favor of a single `set -o pipefail` pipeline that first `rm -rf TestResults.xcresult`.
- Applied the same simulator-selection logic to `ios-build` so the build job does not keep the stale hard-coded simulator destination.

## Unexpected gotchas

- `.git/` is not writable in this sandbox, so `git add`, `git commit`, and `git push` cannot complete.
- `swiftlint` is unavailable locally, and Homebrew cannot install it here because `/opt/homebrew` and related cache/log directories are not writable.
- CoreSimulator is unavailable in this sandbox, so the requested `xcodebuild test` command cannot find or boot simulator destinations.
- The fallback generic simulator build required a writable derived data path; with `-derivedDataPath /tmp/mobileclaw-derived`, Xcode progressed past Swift compilation and then failed in asset catalog processing rather than in the edited Swift files.
