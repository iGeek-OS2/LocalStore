#!/bin/bash
# Builds the Rust FFI for device and simulator and repackages
# OnDeviceCore.xcframework. Run on any rust-core/ change, then regenerate
# the project with `xcodegen generate`.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
# Match the app's deployment floor, or cc-rs objects trip linker warnings.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.4}"
# Make ~/.cargo visible to non-login shells such as Xcode's.
# shellcheck disable=SC1090
source "$HOME/.cargo/env" 2>/dev/null || true

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: Rust is required. Install rustup, then add aarch64-apple-ios and aarch64-apple-ios-sim." >&2
  exit 1
fi

# Rewrite $HOME to /build, since Rust bakes absolute source paths in as string
# constants that survive stripping and reach the app's log console.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/build"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${HOME}=/build"
export TARGET_CFLAGS="${TARGET_CFLAGS:-} -ffile-prefix-map=${HOME}=/build"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/rust-core"

echo "==> Building Rust static libs (release)"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

cd "$ROOT"
echo "==> Repackaging OnDeviceCore.xcframework"
rm -rf "$ROOT/OnDeviceCore.xcframework"
xcodebuild -create-xcframework \
  -library rust-core/target/aarch64-apple-ios/release/libondevice_core.a -headers rust-core/include \
  -library rust-core/target/aarch64-apple-ios-sim/release/libondevice_core.a -headers rust-core/include \
  -output "$ROOT/OnDeviceCore.xcframework"

echo "==> Done. (Re)generate the project with: xcodegen generate"
