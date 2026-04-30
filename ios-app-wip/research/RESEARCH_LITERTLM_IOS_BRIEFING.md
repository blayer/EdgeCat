# Research brief — replicate LiteRT-LM macOS prebuilt approach for iOS arm64

## Repos and refs

- LiteRT-LM upstream: https://github.com/google-ai-edge/LiteRT-LM
- Local clone: `/tmp/litert-main` (commit `5e0d86bcbe31059dabfef651a85856cee837cb52`, `main` branch as of 2026-04-26)
- Bazel: 7.6.1 (via bazelisk), rules_apple 3.22.0, rules_rust 0.61.0
- Xcode 26.4.1 at `/Applications/Xcode.app/`

## Goal

We are porting an Android Kotlin app (EdgeCat, which uses LiteRT-LM via the
`com.google.ai.edge.litertlm` Maven artifact) to native iOS Swift. We want to produce a
**clean iOS arm64 prebuilt set** structured **the same way LiteRT-LM ships its
`prebuilt/macos_arm64/` set today**, since the macOS set is the only complete, internally
consistent prebuilt distribution in upstream.

The deliverable for this research: concrete step-by-step instructions to produce four
iOS arm64 dylibs that mirror the macOS set:

```
libLiteRt.dylib
libLiteRtMetalAccelerator.dylib
libLiteRtTopKMetalSampler.dylib
libGemmaModelConstraintProvider.dylib
```

(`libLiteRtTopKWebGpuSampler.dylib` and `libLiteRtWebGpuAccelerator.dylib` are macOS-only
and out of scope.)

Plus: a note on how the C-API in `c/engine.h` (which the prebuilts do **not** export) is
expected to be combined with these dylibs by an app developer — does the app build the C-API
locally and link against the dylibs, or is there a fifth artifact the app should use?

## Verified facts (please re-verify, do not assume)

1. `prebuilt/macos_arm64/` ships **6 dylibs**, all `arm64 macOS, sdk 26.2`:
   `libLiteRt.dylib`, `libLiteRtMetalAccelerator.dylib`, `libLiteRtTopKMetalSampler.dylib`,
   `libGemmaModelConstraintProvider.dylib`, `libLiteRtTopKWebGpuSampler.dylib`,
   `libLiteRtWebGpuAccelerator.dylib`.

2. `prebuilt/ios_arm64/` is **broken on `main`**: only `libGemmaModelConstraintProvider.dylib`
   and `libLiteRtMetalAccelerator.dylib` are real iOS arm64 binaries; `libLiteRt.dylib` and
   `libLiteRtTopKMetalSampler.dylib` are accidentally checked in as **macOS x86_64** dylibs
   (verified with `lipo -info` and `vtool -show-build`). Tag `v0.10.2` only ships
   `libGemmaModelConstraintProvider.dylib`.

3. **None of the prebuilt dylibs export the `litert_lm_*` C API** declared in
   `c/engine.h`. Verified with `nm -gU` across all six macOS prebuilts: 0 `litert_lm_*`
   symbols. The C API is implemented in `c/engine.cc`, declared in the Bazel target
   `//c:engine` / `//c:engine_cpu` (see `c/BUILD`), and is expected to be compiled and
   linked by the app developer (e.g., the Kotlin AAR build adds it).

4. `bazelisk build //c:engine_cpu --config=ios_arm64 --define=DISABLE_HUGGINGFACE_TOKENIZER=1`
   succeeds: 8 min, 3462 actions, produces `bazel-bin/c/libengine_cpu.a` (1.4 MB) plus
   1823 transitive C++ `.o` files in iOS arm64 across `bazel-out/ios_arm64-opt/bin/`.

5. The Rust deps (minja, cxx, serde, etc.) compile to iOS arm64 too — but only when the
   Rust target is invoked **directly** with `--config=ios_arm64`. When pulled transitively
   through `//c:engine_cpu`, rules_rust appears to put them in the `darwin_arm64-opt-exec`
   (host) configuration. Build for iOS is `…/bazel-out/ios_arm64-opt/bin/external/crate_index__*/lib*.rlib`.

6. After bundling 1823 C++ `.o` + 449 Rust `.o` (extracted from 45 rlibs) +
   `libcxx_cc.a` (the C++ side of the cxx crate) + 46 toolchain rlibs (`libstd`, `libcore`,
   `liballoc`, etc., from `external/rust_macos_aarch64__aarch64-apple-ios__stable_tools/`)
   into a single 95 MB `libLiteRtLm.a`, Xcode's linker still reports **~50 unresolved symbols**:
   - Rust alloc shim: `___rust_alloc`, `___rust_dealloc`, `___rust_realloc`,
     `___rust_alloc_zeroed`, `___rust_alloc_error_handler`,
     `___rust_alloc_error_handler_should_panic`, `___rust_no_alloc_shim_is_unstable`
   - Some `_cxxbridge1$*` C-style runtime symbols (vec/box helpers for
     `litert$lm$JsonValue`).
   - Some `_litert$lm$cxxbridge1$JsonValue$*` application-side bindings.

7. WORKSPACE already registers iOS Rust toolchains (lines ~273-281):
   ```
   rust_register_toolchains(
       edition = "2021",
       extra_target_triples = [
           "aarch64-linux-android",
           "aarch64-apple-ios",
           "aarch64-apple-ios-sim",
           "x86_64-linux-android",
       ],
   )
   ```

8. `.bazelrc` defines `--config=ios_arm64` → `--cpu=ios_arm64
   --platforms=@build_bazel_apple_support//platforms:ios_arm64 --apple_platform_type=ios`.

## Core question

**How does the LiteRT-LM project produce the four `prebuilt/macos_arm64/lib*.dylib` files
today?** Specifically:

- Which Bazel target rules and target labels (`//path:label`) produce each of those four
  dylibs?
- What command lines produce them? (`bazel build //some:target --config=darwin_arm64 ...`?)
- Do they use `cc_shared_library`, `cc_binary -linkshared=True`, `apple_dylib`, a custom
  rule, or a manual `clang -dynamiclib` over Bazel-built static archives?
- How does the macOS build resolve the **Rust alloc shim** and **cxxbridge runtime** that
  break iOS linking? Does macOS go through the same code path or a different one?

Then: what is the **minimal change** required to produce the equivalent **four iOS arm64
dylibs** matching the macOS structure?

## Vote options

Each agent must end with `**VOTE: A/B/C/D**` and a 1-2 sentence justification.

- **A** — *Bazel-side fix: produce iOS dylibs by mirroring the exact macOS Bazel target(s).*
  Find the rule(s) that produce macOS prebuilts (likely `cc_shared_library` or
  `cc_binary -linkshared` with `linkstatic=True`), invoke them with `--config=ios_arm64`,
  patch as needed for rules_apple compatibility. Bazel handles Rust runtime + alloc shim
  correctly because final-link goes through rustc/clang in one step.

- **B** — *Add a `rust_static_library` target so rustc emits a self-contained Rust archive
  with the alloc shim baked in.* Then continue our existing approach (combine all `.o` via
  `libtool`, link as static archive in the iOS Xcode project). Smallest patch to upstream
  BUILD files; preserves our static-archive shipping model.

- **C** — *Manual alloc shim + cxxbridge stubs.* Hand-write a small `.c` file defining the
  ~7 `__rust_alloc*` symbols pointing at `malloc`/`free`, plus stubs for the missing
  cxxbridge functions. Fastest but fragile and not aligned with how upstream ships.

- **D** — *Build LiteRT-LM the way the Kotlin AAR does it for Android.* The Maven artifact
  must already solve this exact problem (Rust + cxxbridge + C-API on a non-rustc host
  link). Find the Android packaging path in upstream, mirror it for iOS using `apple_*`
  rules.

End with: `**VOTE: [A/B/C/D]** and brief justification.`

## What NOT to recommend

- Do **not** suggest "build the app linking against the static archive instead" — that's
  what we did, it's why we're here.
- Do **not** recommend Mac Catalyst.
- Do **not** recommend disabling `minja` or chat templating — needed at runtime for Gemma.
- Do **not** recommend waiting for upstream to ship correct iOS prebuilts.

## Investigation pointers

Files / locations agents should actually open:

- `/tmp/litert-main/c/BUILD` (defines `engine` and `engine_cpu` cc_library)
- `/tmp/litert-main/runtime/engine/BUILD` (likely defines `litert_lm_main`, the CLI binary
  that's released as a binary asset — clue to how they package)
- `/tmp/litert-main/prebuilt/macos_arm64/BUILD` (small file declaring the prebuilt dylibs)
- `/tmp/litert-main/prebuilt/ios_arm64/BUILD` (same shape, but for iOS)
- `/tmp/litert-main/runtime/components/rust/BUILD` (the rust_library + rust_cxx_bridge
  target)
- `/tmp/litert-main/rust_cxx_bridge.bzl`
- `/tmp/litert-main/.bazelrc`
- `/tmp/litert-main/WORKSPACE`
- `/tmp/litert-main/cmake/` and `/tmp/litert-main/CMakeLists.txt` — there's a parallel
  CMake build that may build the dylibs differently
- The kotlin/ directory of LiteRT-LM (only contains `java/` per inspection) and the
  Maven artifact `com.google.ai.edge.litertlm` — how does the AAR include the C-API +
  the prebuilt dylibs?
- GitHub Actions / Releases for the repo — release pipeline may reveal how prebuilts are
  generated.

## Deliverable format

Write findings to your designated solution file. Include:

1. **How macOS prebuilts are produced** — exact target labels + command lines + rule types.
2. **Where the Rust alloc shim is resolved on macOS** — code path / build config that makes
   it work, with file references.
3. **iOS port instructions** — concrete sequence of commands and patches (BUILD edits,
   WORKSPACE edits, command lines) to produce the four iOS arm64 dylibs from a fresh clone.
4. **Risks** — anything that might still break (codesigning, weak linking, framework
   embedding, dyld resolution at runtime).
5. **VOTE line at the end.**

End with: `**VOTE: [A/B/C/D]** and brief justification.`
