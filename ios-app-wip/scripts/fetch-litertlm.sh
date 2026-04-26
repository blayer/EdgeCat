#!/usr/bin/env bash
# Builds LiteRT-LM as a self-contained iOS arm64 dylib from source via Bazel,
# and copies it (plus the Gemma constraint provider prebuilt) into
# LiteRtLmBridge/Vendor/. This is the path Phase A's bridge target links against.
#
# Why from source: the upstream prebuilt set in prebuilt/ios_arm64/ is broken on
# `main` (two of four dylibs are accidentally checked in as macOS x86_64), and
# none of the prebuilts export the litert_lm_* C API anyway — that lives in
# c/engine.cc and has to be compiled locally. Multi-agent research (see
# ios-app-wip/research/) confirmed the canonical fix is a `cc_binary(linkshared=1)`
# Bazel target so rules_rust drives the final link and the Rust alloc shim +
# cxxbridge runtime resolve correctly.
#
# Usage: ./scripts/fetch-litertlm.sh [commit-or-branch]   (default: pinned commit)

set -euo pipefail

# Pinned to the commit on `main` that has the iOS Bazel configuration we verified.
# Bump only after re-verifying the build.
LITERT_LM_COMMIT="${1:-5e0d86bcbe31059dabfef651a85856cee837cb52}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VENDOR="$ROOT/LiteRtLmBridge/Vendor"

if ! command -v bazelisk >/dev/null 2>&1; then
  echo "bazelisk not installed — run \`brew install bazelisk\` first." >&2
  exit 1
fi
if ! command -v git-lfs >/dev/null 2>&1; then
  echo "git-lfs not installed — run \`brew install git-lfs && git lfs install\` first." >&2
  exit 1
fi

WORK="${TMPDIR:-/tmp}/litert-lm-build"
echo "==> Build workspace: $WORK"
if [[ -d "$WORK/.git" ]]; then
  echo "==> Updating existing checkout"
  git -C "$WORK" fetch --depth=1 origin "$LITERT_LM_COMMIT"
  git -C "$WORK" checkout "$LITERT_LM_COMMIT"
else
  echo "==> Fresh clone @ $LITERT_LM_COMMIT"
  rm -rf "$WORK"
  git clone https://github.com/google-ai-edge/LiteRT-LM.git "$WORK"
  git -C "$WORK" checkout "$LITERT_LM_COMMIT"
fi
git -C "$WORK" lfs pull --include="prebuilt/ios_arm64/libGemmaModelConstraintProvider.dylib"

# Apply the cc_binary(linkshared=1) patch to c/BUILD, idempotently.
BUILD_FILE="$WORK/c/BUILD"
if ! grep -q 'name = "libLiteRtLm.dylib"' "$BUILD_FILE"; then
  echo "==> Patching c/BUILD with libLiteRtLm.dylib target"
  cat >> "$BUILD_FILE" <<'PATCH'

# Mobile-Claw iOS port: single self-contained iOS dylib with LiteRT-LM C API +
# statically-linked transitive deps. Mirrors the Android JNI target so
# rules_rust drives the final link and rustc emits the alloc shim correctly.
cc_binary(
    name = "libLiteRtLm.dylib",
    linkshared = 1,
    linkopts = select({
        "@platforms//os:ios": [
            "-Wl,-rpath,@loader_path",
            "-Wl,-install_name,@rpath/libLiteRtLm.dylib",
            "-Wl,-exported_symbol,_litert_lm_*",
        ],
        "@platforms//os:osx": [
            "-Wl,-rpath,@loader_path",
            "-Wl,-install_name,@rpath/libLiteRtLm.dylib",
            "-Wl,-exported_symbol,_litert_lm_*",
        ],
        "//conditions:default": [],
    }),
    visibility = ["//visibility:public"],
    deps = [":engine_cpu"],
)
PATCH
fi

mkdir -p "$VENDOR/litert_lm/c" "$VENDOR/ios" "$VENDOR/sim"

build_dylib() {
  local config="$1" out_subdir="$2"
  echo "==> Building //c:libLiteRtLm.dylib --config=$config"
  ( cd "$WORK" && \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    bazelisk build //c:libLiteRtLm.dylib \
      --config="$config" \
      --define=DISABLE_HUGGINGFACE_TOKENIZER=1 )
  cp "$WORK/bazel-bin/c/libLiteRtLm.dylib" "$VENDOR/$out_subdir/libLiteRtLm.dylib"
  echo "    → $VENDOR/$out_subdir/libLiteRtLm.dylib"
}

build_dylib ios_arm64 litert_lm
# Simulator slice (uncomment when you also need iOS Simulator builds; ~5 min):
# build_dylib ios_sim_arm64 sim

# Header for the bridge .mm
cp "$WORK/c/engine.h" "$VENDOR/litert_lm/c/engine.h"

# Constraint provider — iOS-arm64 prebuilt is correctly built upstream.
cp "$WORK/prebuilt/ios_arm64/libGemmaModelConstraintProvider.dylib" \
   "$VENDOR/ios/libGemmaModelConstraintProvider.dylib"

echo ""
echo "==> Done. Vendor contents:"
ls -lh "$VENDOR/litert_lm/" "$VENDOR/ios/"
