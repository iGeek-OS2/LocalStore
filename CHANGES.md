# Changes from SideInstaller

LocalStore preserves SideInstaller's working on-device authentication,
provisioning, signing, RPPairing, RSD, AFC, and installation foundation. The
following product-level changes define this application:

- Replaced the SideInstaller product interface with a LocalStore app
  centered on arbitrary user-imported IPAs.
- Added a local install-history screen that records only successful installs
  performed by LocalStore and can uninstall those apps explicitly.
- Added first-run Apple Account verification with 2FA, certificate display,
  on-device pairing setup, and loopback-VPN prerequisites before IPA selection.
- Added unsigned-IPA metadata and icon extraction for the confirmation sheet.
- Added a visible step-by-step install progress and error flow.
- Added optional Apple Account persistence in the device-only iOS Keychain.
- Reduced the top-level interface to Installed and Settings.
- Kept RPPairing setup visible while making pairing-file placement and
  Anisette-provider fallback internal implementation details.
- Removed standalone pairing-file generation/export/injection management.
- Removed SideStore and LiveContainer download/release logic and the
  SideStore-specific `Account.sideconf` exporter.
- Removed upstream multilingual dictionaries and language selection.
- Removed the upstream update checker, download manager, certificate tab,
  welcome/TOS UI, branded theme components, and bundled artwork.
- Kept certificate revocation available only when a signing conflict requires
  an explicit recovery decision.
- Added iOS-device and iOS-simulator build verification that asserts the real
  authentication, IPA inspection, signing, RPPairing, RSD, AFC, install, and uninstall
  entry points remain linked.

No success-path mock replaces the SideInstaller-derived core. Attribution and
the governing license are preserved in `README.md`, `LICENSE.md`, and the app's
About section.
# Remote Pairing接続先の修正

- `_remotepairing._tcp` をBonjourで解決し、固定値ではなくこのiPhoneが実際に公開している動的ポートへ接続するよう変更しました。
- 同一ネットワーク上に複数のiPhoneがある場合は、解決先IPと端末自身のWi-Fiアドレスを照合して誤接続を防ぎます。
- Apple ID認証・署名中にRemote Pairingサービスが再起動する可能性があるため、インストール直前にもポートを再解決します。
- `code=16 / Connection refused` をRSDやペアリング解除として扱わず、Remote PairingのTCP接続エラーとして表示します。
