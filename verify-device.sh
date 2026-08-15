#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

xcodegen generate
xcodebuild build \
  -project LocalStore.xcodeproj \
  -scheme LocalStore \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath .deriveddata-device

BINARY="$ROOT/.deriveddata-device/Build/Products/Debug-iphoneos/LocalStore.app/LocalStore.debug.dylib"
test -f "$BINARY"
SYMBOLS="$(nm -gU "$BINARY" 2>/dev/null)"

for symbol in \
  _si_apple_signin \
  _si_ipa_metadata \
  _si_sign_ipa \
  _si_pairing_run_host \
  _tunnel_create_rppairing \
  _afc_client_connect_rsd \
  _installation_proxy_install_with_callback \
  _installation_proxy_uninstall
do
  if ! grep -q " $symbol$" <<< "$SYMBOLS"; then
    echo "Missing real pipeline symbol: $symbol" >&2
    exit 1
  fi
done

# SideStore's account-config exporter is intentionally not part of this app.
FFI_LIB="$ROOT/OnDeviceCore.xcframework/ios-arm64/libondevice_core.a"
if nm -gU "$FFI_LIB" 2>/dev/null | grep -q ' _si_account_config$'; then
  echo "Unexpected SideStore-specific symbol: _si_account_config" >&2
  exit 1
fi

# Remote Pairing ports are dynamically advertised by iOS. Reintroducing the
# old fixed value recreates code=16 / ECONNREFUSED after remotepairingd restarts.
if grep -q 'static let rsdPort.*49152' ios-app/DeviceConnection.swift; then
  echo "Remote Pairing port must not be hard-coded to 49152" >&2
  exit 1
fi
grep -q '_remotepairing\._tcp' ios-app/Info.plist
grep -q 'RemotePairingServiceResolver' ios-app/PairingController.swift
grep -q 'validateSavedPairingIfNeeded(vpnAvailable: vpn, forceServiceRefresh: true)' ios-app/Engine.swift

echo "Device build linked the real authentication/signing/install pipeline."
