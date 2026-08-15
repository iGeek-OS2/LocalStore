# LocalStore

LocalStoreは、iPhoneだけでIPAを署名・インストールするためのiOSアプリです。
Appleアカウントの2ファクタ認証、個人用署名、端末とのペアリング、インストールまでをアプリ内で行います。

## 主な機能

- 暗号化されていないIPAの読み込みと情報確認
- Appleアカウントによる署名とインストール
- 個人用署名アプリの一覧表示と削除
- インストール状況とエラー内容の表示
- 認証情報のiOSキーチェーン保存

無料のAppleアカウントでは、インストール数や署名期間などApple側の制限が適用されます。

## ビルド

Xcode 26、Rust、XcodeGenが必要です。

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./build-rust.sh
xcodegen generate
open LocalStore.xcodeproj
```

Xcodeで自分のDevelopment Teamを選択し、実機へビルドしてください。
`OnDeviceCore.xcframework`はリポジトリに含まれず、`build-rust.sh`で生成されます。

## クレジット

認証・署名・RPPairing・端末通信の基盤には、
[SideInstaller by FrizzleM](https://github.com/FrizzleM/SideInstaller)由来のコードを使用しています。

利用条件は[LICENSE.md](LICENSE.md)、主な変更点は[CHANGES.md](CHANGES.md)、
第三者ライセンスは[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を確認してください。
