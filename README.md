# LocalStore
iPhone単体で個人署名でIPAをインストールするためのプロジェクト。
Appleアカウントにサインインし、端末のペアリング、VPNの設定をして、インストールができます。

このアプリ自体を使うにも署名を使ったインストールは必須です。リリースされてるipaを各自で個人署名、企業用署名等を利用してインストールしてください。(どこか本末転倒感はありますが...)

念のためにサイト上でインストールできるようになりました➔[LocalStore Installer](https://github.com/)
署名切れが起きたら、すみません。

## 主な機能
- Appleアカウントによる署名とインストール
- インストール状況とエラー内容の表示

無料のAppleアカウントでは、3つまでのインストール数や7日間の署名期間の制限がかかります。

## 対応バージョン
- iOS/iPadOS27(b1〜)
- テストデバイス:iPhone17 Pro Max(iOS27b4)
- iOS27からの開発者モードの内で端末内でのペアリング機能を利用したアプリですので、iOS26では使えません。

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
