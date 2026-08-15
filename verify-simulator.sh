#!/bin/zsh
set -euo pipefail

root=${0:A:h}
cd "$root"

xcodegen generate
xcodebuild build \
  -project LocalStore.xcodeproj \
  -scheme LocalStore \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath .deriveddata

binary=.deriveddata/Build/Products/Debug-iphonesimulator/LocalStore.app/LocalStore.debug.dylib
test -f "$binary"

symbols=$(nm -gU "$binary" 2>/dev/null)
for required in \
  _si_apple_signin \
  _si_ipa_metadata \
  _si_sign_ipa \
  _si_pairing_run_host \
  _tunnel_create_rppairing \
  _afc_client_connect_rsd \
  _installation_proxy_install_with_callback \
  _installation_proxy_uninstall
do
  if ! grep -q " $required$" <<< "$symbols"; then
    print -u2 "Missing real pipeline symbol: $required"
    exit 1
  fi
done

# SideStore's account-config exporter is intentionally not part of this app.
ffi_lib=OnDeviceCore.xcframework/ios-arm64-simulator/libondevice_core.a
if nm -gU "$ffi_lib" 2>/dev/null | grep -q ' _si_account_config$'; then
  print -u2 "Unexpected SideStore-specific symbol: _si_account_config"
  exit 1
fi

if grep -q 'static let rsdPort.*49152' ios-app/DeviceConnection.swift; then
  print -u2 "Remote Pairing port must not be hard-coded to 49152"
  exit 1
fi
grep -q '_remotepairing\._tcp' ios-app/Info.plist
grep -q 'RemotePairingServiceResolver' ios-app/PairingController.swift
grep -q 'validateSavedPairingIfNeeded(vpnAvailable: vpn, forceServiceRefresh: true)' ios-app/Engine.swift

print "Simulator build linked the real authentication/signing/install pipeline."
