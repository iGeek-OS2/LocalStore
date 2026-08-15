# LocalStore
iPhone単体で個人署名でIPAをインストールするためのプロジェクト。
Appleアカウントにサインインし、端末のペアリング、VPNの設定をして、インストールができます。

## 主な機能
- Appleアカウントによる署名とインストール
- インストール状況とエラー内容の表示

無料のAppleアカウントでは、3つまでのインストール数や7日間の署名期間の制限がかかります。

## ビルド

Xcode 26、Rust、XcodeGenが必要。。

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./build-rust.sh
xcodegen generate
open LocalStore.xcodeproj
```

Xcodeで自分のDevelopment Teamを選択して実機へビルドしてください。
`OnDeviceCore.xcframework`はリポジトリに含まれず、`build-rust.sh`で勝手に生成されます。

## クレジット

全体的なインストールの仕組みは、
[SideInstaller by FrizzleM](https://github.com/FrizzleM/SideInstaller)由来のコードを使用しています。

利用条件は[LICENSE.md](LICENSE.md)、主な変更点は[CHANGES.md](CHANGES.md)、
第三者ライセンスは[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を確認してください。
