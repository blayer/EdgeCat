# LiteRT-LM iOS dylib research

Repo inspected:

- LiteRT-LM: `/tmp/litert-main` at `5e0d86bcbe31059dabfef651a85856cee837cb52`
- Resolved external `@litert`: `/private/var/tmp/_bazel_nali/2c32253142c522c1d9e030105b727811/external/litert`

## 1. How macOS prebuilts are produced

### Bottom line

The OSS LiteRT-LM checkout does **not** contain Bazel targets that produce all four macOS dylibs.

- `prebuilt/macos_arm64/BUILD` and `prebuilt/ios_arm64/BUILD` are only `exports_files(glob(["**"]))`; they are file containers, not producer rules.
- LiteRT-LM Bazel consumes those dylibs as already-built payloads.
- In the pinned external `@litert` repo, only `libLiteRt.dylib` has a visible source-producing Bazel path in OSS.
- `libLiteRtMetalAccelerator.dylib` is also treated as a prebuilt in OSS `@litert`.
- `libLiteRtTopKMetalSampler.dylib` and `libGemmaModelConstraintProvider.dylib` have no source-producing Bazel label in this checkout.

### Evidence in LiteRT-LM

- `prebuilt/macos_arm64/BUILD` and `prebuilt/ios_arm64/BUILD` only export files.
- `python/litert_lm/BUILD:140-194` copies prebuilt dylibs into the wheel; it does not build them.
- `runtime/components/constrained_decoding/BUILD:130-165` selects `//prebuilt/.../libGemmaModelConstraintProvider.dylib` as an input.
- `runtime/components/sampler_factory.cc` dynamically loads `libLiteRtTopKMetalSampler.dylib` by filename at runtime.

### Actual producer rule found for `libLiteRt.dylib`

This one lives in the external LiteRT workspace, not in LiteRT-LM:

- `@litert//litert/c:build_litert_runtime_c_api_dylib`
- `@litert//litert/c:litert_runtime_c_api_dylib`

From `@litert//litert/c/BUILD:826-838`:

- `macos_dylib(name = "build_litert_runtime_c_api_dylib", ...)`
- `copy_file(name = "litert_runtime_c_api_dylib", src = ":build_litert_runtime_c_api_dylib", target = "libLiteRt.dylib")`

There is also a filegroup alias path at `@litert//litert/c:libLiteRt.so` via `SELECT_LITERT_RUNTIME_C_API_SHARED_LIB` (`@litert//litert/c/BUILD:933-945`), which resolves to the dylib on Apple platforms.

Likely macOS command:

```bash
bazel build --config=macos_arm64 @litert//litert/c:litert_runtime_c_api_dylib
```

or, equivalently, the Apple-selected filegroup:

```bash
bazel build --config=macos_arm64 @litert//litert/c:libLiteRt.so
```

### What produces the other three macOS dylibs in this checkout?

No OSS producer rules are present.

#### `libLiteRtMetalAccelerator.dylib`

In external `@litert`, GPU accelerator dylibs are still treated as prebuilts:

- `@litert//litert/build_common/special_rule.bzl:90-114` maps Apple builds to `@litert_prebuilts//:macos_arm64/libLiteRtMetalAccelerator.dylib`, `@litert_prebuilts//:ios_arm64/libLiteRtMetalAccelerator.dylib`, etc.

There is a general `litert_accelerator_library(...)` macro in `@litert//litert/build_common/litert_build_defs.bzl:662-738`, but the OSS tree I inspected does not expose a concrete Apple source target for `libLiteRtMetalAccelerator.dylib`; the tools path still pulls it from prebuilts.

#### `libLiteRtTopKMetalSampler.dylib`

LiteRT-LM only loads this by filename from `runtime/components/sampler_factory.cc`; there is no source Bazel rule for it in LiteRT-LM, and I did not find one in OSS `@litert` either.

#### `libGemmaModelConstraintProvider.dylib`

LiteRT-LM uses it as a prebuilt input:

- `runtime/components/constrained_decoding/BUILD:130-165`

There is no Bazel target in the repo that builds a shared library with that output name from source.

### Release / CI evidence

The repo CI builds:

- `//...`
- `//runtime/engine:litert_lm_main`
- `//runtime/engine:litert_lm_main` with dynamic runtime flags
- iOS simulator `//...` and `//runtime/engine:litert_lm_main`

See `.github/workflows/ci-build-mac.yml:101-148`.

It does **not** build or publish the four Apple dylibs from source in OSS CI. The only release upload in that workflow is `litert_lm_main(.macos_arm64/.ios_sim_arm64)`.

### Therefore

The strict answer to “which Bazel target labels produce each of the four macOS dylibs today?” is:

- `libLiteRt.dylib`: `@litert//litert/c:litert_runtime_c_api_dylib` from `macos_dylib + copy_file`
- `libLiteRtMetalAccelerator.dylib`: **no producer rule present in OSS checkout; consumed as prebuilt**
- `libLiteRtTopKMetalSampler.dylib`: **no producer rule present in OSS checkout**
- `libGemmaModelConstraintProvider.dylib`: **no producer rule present in OSS checkout; consumed as prebuilt**

## 2. Where the Rust alloc shim is resolved on macOS

### What the repo shows

The Rust bridge in LiteRT-LM is ordinary `rust_library` + generated CXX bridge glue:

- `runtime/components/rust/BUILD:32-58`
- `rust_cxx_bridge.bzl:20-76`

The app-facing C API is plain C++:

- `c/BUILD:55-80` defines `//c:engine` and `//c:engine_cpu` as `cc_library`

That means there is no special Rust final artifact for the C API in Bazel today; Rust is reached transitively through normal C++ deps.

### Why your manual archive failed

Your failure mode is consistent with “we extracted intermediate Rust/CXX objects and bypassed Bazel’s intended final link.” The unresolved names you listed are exactly the kinds of symbols that normally get fixed up when the final shared/executable link is performed in one place, rather than by `libtool`-bundling `.o` and `.rlib` contents yourself.

### What upstream already does differently when it works

The only working paths in this repo that are clearly meant to do the final link are:

- `//runtime/engine:litert_lm_main` (`cc_binary`) in Bazel
- `//kotlin/java/com/google/ai/edge/litertlm/jni:litertlm_jni` (`cc_binary(linkshared = 1)`) for Kotlin/JVM
- CMake’s final target/executable link

The Kotlin JNI library is especially relevant:

- `kotlin/java/com/google/ai/edge/litertlm/jni/BUILD:22-42`

That path links the Rust-backed `prompt_template` transitively in one Bazel final link step. There is no hand-written alloc shim on Apple in LiteRT-LM. The only explicit alloc shim sources in this repo are Windows-specific add-ons:

- `runtime/components/rust/BUILD:51-57` only adds `//rust:alloc_defs` and `//rust:global_allocator` on Windows
- `rust/BUILD`, `rust/global_allocator.rs`, `rust/alloc_defs.cc`

So the best-supported inference is:

- macOS succeeds because the final Bazel link step owns the whole graph.
- your static-archive repackaging fails because it cuts across `rules_rust`/`cxxbridge` expectations and loses the intended runtime glue.

## 3. iOS port instructions

## Reality check first

A fresh LiteRT-LM clone cannot produce all four requested iOS dylibs from source today without patches, because:

- `libLiteRt.dylib` has an Apple source-producing path only for macOS in OSS `@litert`
- `libLiteRtMetalAccelerator.dylib` is consumed from `@litert_prebuilts`
- `libLiteRtTopKMetalSampler.dylib` has no visible OSS producer rule
- `libGemmaModelConstraintProvider.dylib` has no shared-library producer rule in LiteRT-LM

So the minimal viable upstream-style plan is a **Bazel-side fix**, but it is not “invoke existing macOS-equivalent target labels unchanged.” Two new producer rules are needed in practice, and two existing prebuilt-only dependencies must either stay prebuilt or be sourced from non-OSS/internal build logic that is not in this checkout.

### What I would do

#### Step 1: Keep the C API local, exactly as the repo already expects

This repo’s own structure says the app builds the LiteRT-LM C API locally:

- `c/BUILD:55-80` defines `//c:engine` / `//c:engine_cpu`
- none of the prebuilt dylibs export `litert_lm_*`

Use:

```bash
bazel build //c:engine_cpu --config=ios_arm64 --define=DISABLE_HUGGINGFACE_TOKENIZER=1
```

Artifact:

- `bazel-bin/c/libengine_cpu.a`

There is no fifth official LiteRT-LM artifact in this repo for the app-facing `litert_lm_*` C API.

#### Step 2: Build `libLiteRt.dylib` from the external LiteRT workspace, not from LiteRT-LM

Existing macOS source producer:

- `@litert//litert/c:build_litert_runtime_c_api_dylib`
- `@litert//litert/c:litert_runtime_c_api_dylib`

Minimal patch needed:

- add an iOS sibling in `@litert//litert/c/BUILD` next to the macOS `macos_dylib(...)`
- keep the same exported-symbols script and install name pattern, but produce `libLiteRt.dylib` for `ios_arm64`

After that patch, the intended command is:

```bash
bazel build --config=ios_arm64 @litert//litert/c:litert_runtime_c_api_dylib
```

or another new iOS-specific label you add there.

#### Step 3: Add a Bazel shared-library producer for `libGemmaModelConstraintProvider.dylib`

Current state:

- LiteRT-LM only has a consumer target for the prebuilt file in `runtime/components/constrained_decoding/BUILD:130-165`

Minimal patch:

- add a new target in `runtime/components/constrained_decoding/BUILD`
- make it a real final-link shared library target, not a static archive
- give it install name `@rpath/libGemmaModelConstraintProvider.dylib`
- link the provider implementation and its deps directly in Bazel

I would prefer `cc_binary(linkshared = 1)` here over another manual archive step, specifically to let Bazel own the final link and avoid repeating the Rust/cxxbridge failure pattern elsewhere.

Intended command after patch:

```bash
bazel build --config=ios_arm64 //runtime/components/constrained_decoding:libGemmaModelConstraintProvider
```

Then copy/rename the produced Mach-O to `libGemmaModelConstraintProvider.dylib` if Bazel’s output basename differs.

#### Step 4: Do not try to rebuild `libLiteRtMetalAccelerator.dylib` and `libLiteRtTopKMetalSampler.dylib` from this checkout unless you also import their source-producing rules

What the code proves:

- `@litert` OSS still expects `libLiteRtMetalAccelerator.dylib` as a prebuilt (`special_rule.bzl:90-114`)
- LiteRT-LM expects `libLiteRtTopKMetalSampler.dylib` to exist at runtime, but does not define it

So the shortest correct path is:

- fix the broken checked-in iOS prebuilts for these two by replacing them with correct iOS arm64 builds from the real producer workspace
- do **not** pretend LiteRT-LM OSS can synthesize them from the files inspected here; it cannot

If you insist on a “fresh clone only” source build, you need extra source/build logic that is absent from this repo snapshot.

### Concrete command sequence I would use after patching

```bash
# 1. App-facing C API, still local/static
bazel build //c:engine_cpu --config=ios_arm64 --define=DISABLE_HUGGINGFACE_TOKENIZER=1

# 2. External LiteRT runtime dylib, from @litert after adding iOS dylib producer
bazel build --config=ios_arm64 @litert//litert/c:litert_runtime_c_api_dylib

# 3. LiteRT-LM constraint-provider dylib, after adding a shared target
bazel build --config=ios_arm64 //runtime/components/constrained_decoding:libGemmaModelConstraintProvider

# 4. Obtain correct iOS arm64 GPU dylibs from their real producer workspace
#    and place them under prebuilt/ios_arm64/
#    - libLiteRtMetalAccelerator.dylib
#    - libLiteRtTopKMetalSampler.dylib
```

### Why I am not recommending the archive-bundling path

Because the inspected repo already gives the answer: whenever upstream wants a consumable binary surface, it uses a final Bazel or CMake link step, not “extract every `.o` from every `.rlib` and repack.” Your unresolved `__rust_alloc*` and cxxbridge symbols are exactly the failure mode that A avoids and B preserves.

## 4. Risks

- `libLiteRtMetalAccelerator.dylib` and `libLiteRtTopKMetalSampler.dylib` are not source-producible from the inspected OSS files alone. That is the biggest delivery risk.
- `libLiteRt.dylib` iOS support needs a new Apple producer rule in external `@litert`; only macOS `macos_dylib(...)` exists in the inspected checkout.
- `libGemmaModelConstraintProvider.dylib` still needs a new shared-library target in LiteRT-LM.
- iOS runtime loading will depend on correct `@rpath` / `@loader_path` layout. LiteRT-LM already expects `@loader_path` for the constraint provider (`runtime/components/constrained_decoding/BUILD:146-149`).
- iOS app embedding and signing still matter. Unsigned dylibs can link in build products but fail at device packaging/runtime.
- `libLiteRtTopKMetalSampler.dylib` depends on `@rpath/libLiteRt.dylib`; the embedding order and runpath search paths must match.
- The checked-in iOS arm64 folder on `main` is inconsistent today: two files are real iOS arm64, two are macOS x86_64. That can mask integration mistakes if you only check filenames.

## 5. C API answer

The app developer is expected to build the LiteRT-LM C API locally and combine it with the dylibs.

- Use `//c:engine` or `//c:engine_cpu` for the `litert_lm_*` entry points from `c/engine.h`.
- Link/load the Apple dylibs separately for LiteRT runtime and plugin features.
- I found no fifth official LiteRT-LM binary artifact in this repo that replaces local C-API compilation.

## Recommendation

Choose the Bazel final-link route for every artifact you control, and treat the missing Apple plugin dylibs as a separate upstream-source-gap problem rather than papering over it with archive surgery.

**VOTE: A** because the only path that aligns with the inspected build system and avoids the Rust alloc/cxxbridge failure mode is a Bazel-owned final shared-library link; B/C keep the broken manual-link model, and D is not backed by a visible iOS packaging path in this checkout.
