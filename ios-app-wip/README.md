# Mobile-Claw iOS (work-in-progress)

Native iOS Swift port of the Android Kotlin app at `../android-app/`. Same on-device LLM engine
([LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)), same feature set, same screens.

> **Status: Phase A, step 1.** Project skeleton + bridge-target shape. No model inference yet —
> the `LiteRtLmBridge` Obj-C surface is stubbed and will be wired to the C API in step 2.

## Repo layout

```
ios-app-wip/
├── project.yml                 # XcodeGen spec — single source of truth for the .xcodeproj
├── scripts/fetch-litertlm.sh   # Pulls C headers + iOS dylibs from the LiteRT-LM repo (LFS)
├── MobileClaw/                 # iOS app target (Swift / SwiftUI)
│   ├── App/                    # @main + navigation
│   ├── UI/                     # Screens + ViewModels (mirror android-app/.../ui)
│   ├── Runtime/                # LLM runtime facade (mirrors android-app/.../runtime)
│   ├── Resources/              # Asset catalog, Info.plist
│   └── …                       # Orchestration / Skills / Persistence land in later phases
└── LiteRtLmBridge/             # Obj-C++ shim wrapping LiteRT-LM's C API
    ├── include/LiteRtLmBridge.h
    ├── LiteRtLmBridge.mm
    ├── module.modulemap
    └── Vendor/                 # populated by scripts/fetch-litertlm.sh — not committed
        ├── litert_lm/          # c/engine.h + transitive headers
        └── ios/                # libLiteRt.dylib + accelerator dylibs (arm64 + sim)
```

## Prerequisites

- macOS 14+ with Xcode 15.4+
- iOS 17+ device or simulator (arm64)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [git-lfs](https://git-lfs.com) (`brew install git-lfs && git lfs install`) — needed to fetch
  the LiteRT-LM iOS dylibs, which the upstream repo stores as LFS objects.

## First-time setup

```bash
cd ios-app-wip
./scripts/fetch-litertlm.sh        # downloads C headers + iOS dylibs into LiteRtLmBridge/Vendor/
xcodegen                            # generates MobileClaw.xcodeproj from project.yml
open MobileClaw.xcodeproj
```

> **Bundle ID + signing.** Bundle ID is `com.mobileclaw.app` (matches Android). Set your team
> in Xcode → MobileClaw target → Signing & Capabilities before running on device.

## Sideloading a model

Phase A uses manual sideload (matches the Android `/data/local/tmp` flow):

1. Build & run the app once on a device — this creates the app's Documents directory.
2. In Finder → device → Files → MobileClaw → drop a `.litertlm` model (e.g. `gemma-3n-E2B-it-int4.litertlm`)
   into the `Models/` folder. (`UIFileSharingEnabled` is set in Info.plist.)
3. Restart the app and the picker will list it.

## Mapping to the Android codebase

See `../docs/` and the plan file at `~/.claude/plans/i-want-to-implement-dynamic-lark.md`
for the full Android→iOS file mapping table.

## Phased delivery

- **Phase A** — bridge + bare chat (text only). _Current._
- **Phase B** — conversations DB + model select.
- **Phase C** — multimodal (image + audio) + thinking channel.
- **Phase D** — orchestration + native skills + JS skills.
- **Phase E** — eval harness.
