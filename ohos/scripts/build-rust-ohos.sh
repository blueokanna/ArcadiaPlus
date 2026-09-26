#!/usr/bin/env bash
# Build the ArcadiaPlus Rust engine for HarmonyOS (arm64) and stage the
# artifacts the HAP build consumes.
#
# What it produces
#   * ohos/entry/src/main/cpp/thirdparty/arm64-v8a/librust_lib_arcadiaplus.a
#     — statically linked into libarcadia_core.so, the engine the VPN
#       extension process runs.
#   * ohos/entry/libs/arm64-v8a/librust_lib_arcadiaplus.so
#     — the cdylib the Flutter OHOS embedding loads in the UI process.
#       entry/libs is the module's native-library directory: hvigor packs
#       everything in it into the HAP next to libapp.so, which is exactly
#       where flutter_rust_bridge's loader (`loadExternalLibrary`, ohos
#       branch) expects to find it.
#
# Requirements
#   * Rust 1.97 through rustup (the workspace pins it). The target is
#     installed on demand:  rustup target add aarch64-unknown-linux-ohos
#   * The HarmonyOS NDK that ships with DevEco Studio, or with the
#     command-line-tools SDK (…/sdk/default/openharmony/native). Point
#     OHOS_NDK at its `native` directory or let the script probe the usual
#     locations.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET=aarch64-unknown-linux-ohos
ABI=arm64-v8a

find_ndk() {
  if [[ -n "${OHOS_NDK:-}" ]]; then echo "$OHOS_NDK"; return; fi
  local candidates=(
    "${DEVECO_SDK_HOME:-}/default/openharmony/native"
    "${HOME}/OpenHarmony/Sdk/latest/native"
    "${HOME}/OpenHarmony/Sdk/12/native"
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate/llvm/bin/clang" ]]; then echo "$candidate"; return; fi
  done
  return 1
}

NDK="$(find_ndk)" || {
  echo "error: the HarmonyOS NDK was not found. Set OHOS_NDK to its 'native' directory." >&2
  exit 1
}

if [[ ! -d "$NDK/sysroot" ]]; then
  echo "error: $NDK does not look like a HarmonyOS NDK (no sysroot)." >&2
  exit 1
fi

installed_targets="$(rustup target list --installed)"
if ! grep -qx "$TARGET" <<< "$installed_targets"; then
  echo "Installing missing Rust target $TARGET"
  rustup target add "$TARGET"
fi

# Target-scoped variables only: exporting global RUSTFLAGS would leak into
# every other target the workspace builds (Android, desktop) in the same job.
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$NDK/llvm/bin/clang"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS="-Clink-arg=--target=aarch64-linux-ohos -Clink-arg=--sysroot=$NDK/sysroot"

# Dependencies that compile a C shim (flutter_rust_bridge's dart-sys among
# them) go through cc-rs; pointed at the NDK's clang they cross-compile the
# same way the linker does.
export CC_aarch64_unknown_linux_ohos="$NDK/llvm/bin/clang"
export AR_aarch64_unknown_linux_ohos="$NDK/llvm/bin/llvm-ar"
export CFLAGS_aarch64_unknown_linux_ohos="--target=aarch64-linux-ohos --sysroot=$NDK/sysroot"

echo "Engine target : $TARGET"
echo "HarmonyOS NDK : $NDK"
echo "Rust toolchain: $(rustc --version)"

# File-existence alone must never be read as "the build succeeded": a failed
# cargo run with a stale artifact still looks green. The artifacts are removed
# first, cargo's own exit code decides, and the checks below re-assert.
rm -f "$ROOT/rust/target/$TARGET/release/librust_lib_arcadiaplus.a" \
      "$ROOT/rust/target/$TARGET/release/librust_lib_arcadiaplus.so"

cargo build --manifest-path "$ROOT/rust/Cargo.toml" --target "$TARGET" --release

STATIC="$ROOT/rust/target/$TARGET/release/librust_lib_arcadiaplus.a"
SHARED="$ROOT/rust/target/$TARGET/release/librust_lib_arcadiaplus.so"

if [[ ! -f "$STATIC" ]]; then
  echo "error: $STATIC was not produced" >&2
  exit 1
fi
if [[ ! -f "$SHARED" ]]; then
  echo "error: $SHARED was not produced" >&2
  exit 1
fi

mkdir -p "$ROOT/ohos/entry/src/main/cpp/thirdparty/$ABI"
cp "$STATIC" "$ROOT/ohos/entry/src/main/cpp/thirdparty/$ABI/"

mkdir -p "$ROOT/ohos/entry/libs/$ABI"
cp "$SHARED" "$ROOT/ohos/entry/libs/$ABI/"

echo "Engine staged:"
echo "  ohos/entry/src/main/cpp/thirdparty/$ABI/librust_lib_arcadiaplus.a"
echo "  ohos/entry/libs/$ABI/librust_lib_arcadiaplus.so"
