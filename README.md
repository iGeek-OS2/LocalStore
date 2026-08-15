# LocalStore

LocalStore is an on-device IPA installer for iOS. It accepts a user-selected,
unencrypted IPA, authenticates an Apple Account with 2FA, provisions and signs
the app for the current device, and installs it without a computer.

The product is intentionally focused on that single job:

- The Apps screen lists Personal Team apps visible on the device, including
  apps installed with LocalStore, Xcode, AltStore, or another installer.
- Initial setup verifies the Apple Account with 2FA, shows the account's iOS
  development certificates, pairs this iPhone, and checks the loopback VPN
  before enabling IPA selection.
- Picking an IPA reads its real app name, version, Bundle ID, and icon before
  presenting the install confirmation.
- Install progress and failures are shown step by step. History entries can
  uninstall the corresponding app from the device.
- Apple Account credentials are retained in this device's Keychain.
- Pairing-file placement and Anisette-server selection are internal details,
  not user-managed product features.
- There is no SideStore/LiveContainer downloader, language selector, update
  client, certificate tab, or pairing-file distributor.

The imported IPA must be unencrypted and compatible with the capabilities a
Personal Team can provision. Apple's normal limits still apply to free accounts.

## Architecture and attribution

The LocalStore application layer, install-history management, Keychain account
storage, and current SwiftUI interface are maintained as this project's product.

The underlying Apple authentication, Developer Services, signing, RPPairing,
RemoteXPC/RSD, AFC, and `installation_proxy` implementation is derived from
[SideInstaller by FrizzleM](https://github.com/FrizzleM/SideInstaller). That work
made the on-device installation path possible and remains explicitly credited
in the app and source.

SideInstaller's license and copyright notice are preserved in `LICENSE.md`.
This derivative is limited to the personal, educational, non-commercial use and
source-distribution terms granted there. It does not redistribute an official
SideInstaller build.

## Build

The repository distributes source code only. `OnDeviceCore.xcframework` is
generated locally and is intentionally excluded from Git because the
SideInstaller license grants redistribution of derivative works in source-code
form. Install Rust and XcodeGen, then build the framework and regenerate the
project:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./build-rust.sh
xcodegen generate
open LocalStore.xcodeproj
```

In Xcode, select your own development team under Signing & Capabilities,
select the target iPhone, and press Run. No development team or provisioning
profile is committed to this repository.

Verification commands:

```sh
./verify-device.sh
./verify-simulator.sh
```

The simulator validates the UI and real FFI linkage. A physical device is still
required to prove Apple provisioning, RPPairing, AFC transfer, and installation.

## Credential handling

When the user chooses to save an Apple Account, its email and password are
stored as a generic-password item in the iOS Keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The password is not written to
UserDefaults, application logs, or the installed-app cache. Authentication still
depends on an Anisette provider; the app automatically tries its internal
provider list instead of exposing a server picker.
