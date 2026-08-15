# SideInstallerからの主な変更点

- 任意のIPAを扱うLocalStore独自のSwiftUI画面へ変更
- IPA情報の確認、進捗表示、エラー表示を追加
- 個人用署名アプリの一覧表示と削除に対応
- AppleアカウントをiOSキーチェーンへ保存
- 不要なダウンロード、更新、言語選択などの機能を削除
- Remote Pairingの接続先を動的に検出

認証・署名・RPPairing・RSD・AFC・インストールの基盤は、SideInstaller由来の実装を維持しています。
