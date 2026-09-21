#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
source "$HOME/.cargo/env" 2>/dev/null || true

# Do not leak the CI runner/user path into Rust panic strings.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/build"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${HOME}=/build"
export TARGET_CFLAGS="${TARGET_CFLAGS:-} -ffile-prefix-map=${HOME}=/build"

cd "$ROOT"
cargo build --release --target aarch64-apple-ios

rm -rf "$ROOT/PanicPairingFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$ROOT/target/aarch64-apple-ios/release/libpanic_pairing_ffi.a" \
  -headers "$ROOT/include" \
  -output "$ROOT/PanicPairingFFI.xcframework"

echo "Built $ROOT/PanicPairingFFI.xcframework"
