import Foundation

private let japaneseStrings: [String: String] = [
    "Unnamed certificate": "名称のない証明書",
    "Enter your Apple ID email and password first.": "先にAppleアカウントのメールアドレスとパスワードを入力してください。",
    "This certificate has no serial number, so it can't be revoked.": "この証明書にはシリアル番号がないため、失効できません。",
    "Two-factor verification was cancelled.": "2ファクタ認証がキャンセルされました。",
    "the anisette server": "Anisetteサーバー",
    "all %d anisette servers": "%d件すべてのAnisetteサーバー",
    "Apple ID sign-in failed on %@. Last error: %@": "%@でAppleアカウントへのサインインに失敗しました。最後のエラー：%@",
    "Not signed in.": "サインインしていません。",
    "Connect the VPN": "VPNに接続",
    "Pair with this iPhone": "このiPhoneとペアリング",
    "Open the device link": "デバイス接続を開始",
    "Sign in to Apple ID": "Appleアカウントにサインイン",
    "Prepare the imported IPA": "読み込んだIPAを準備",
    "Sign the app": "アプリを署名",
    "Install the app": "アプリをインストール",
    "Apple won't issue a signing certificate for this Apple ID: it reports that one already exists, or that a request for one is still pending (error 7460). LocalStore couldn't reuse the certificate that's already there, so it stopped instead of replacing it. See the steps above.": "このAppleアカウントには既存の署名証明書、または処理中の証明書要求があるため、Appleから新しい証明書を発行できませんでした（エラー7460）。既存証明書を再利用できないため、置き換えずに処理を中止しました。表示された案内を確認してください。",
    " (UDID %@)": "（UDID：%@）",
    "Couldn't register this iPhone%@ with your Apple ID's developer team, so Apple won't issue a provisioning profile. %@ — see the steps above.": "このiPhone%@をAppleアカウントの開発チームへ登録できなかったため、プロビジョニングプロファイルを取得できませんでした。%@。表示された案内を確認してください。",
    "not paired": "ペアリングされていません",
    "your app": "アプリ",
    "Pairing didn't finish — no pairing file yet.": "ペアリングが完了していません。ペアリング情報がまだ作成されていません。",
    "connected": "接続済み",
    "device": "デバイス",
    "Enter your Apple ID email + password.": "Appleアカウントのメールアドレスとパスワードを入力してください。",
    "Incorrect Apple ID or password. Check your Apple Account email and password, then try again.": "Appleアカウントまたはパスワードが正しくありません。入力内容を確認して、もう一度試してください。",
    "No IPA imported yet. Tap “Import .ipa” and pick one.": "IPAが読み込まれていません。「IPAを選択」からファイルを選んでください。",
    "%@ isn't a valid IPA. Replace it and try again.": "%@は有効なIPAではありません。別のファイルを選んでください。",
    "%@ isn't an IPA. Pick the .ipa file itself — if it looks right, the download may have saved an error page instead, or stopped partway.": "%@はIPAではありません。.ipaファイル本体を選んでください。正しいファイルに見える場合は、ダウンロードが途中で止まったか、エラーページが保存された可能性があります。",
    "Couldn't import %@: %@": "%@を読み込めませんでした：%@",
    "No IPA imported.": "IPAが読み込まれていません。",
    "Signing failed: %@": "署名に失敗しました：%@",
    "No signed bundle to install.": "インストールできる署名済みアプリがありません。",
    "Device link dropped — reconnect.": "デバイスとの接続が切れました。再接続してください。",
    "No loopback VPN is connected. Turn one on, then try again.": "ループバックVPNが接続されていません。VPNを接続して、もう一度試してください。",
    "Connect to Wi-Fi": "Wi-Fiに接続",
    "Open Settings › Wi-Fi and join a network.": "設定からWi-Fiを開き、ネットワークへ接続してください。",
    "Pairing this iPhone needs it: LocalStore advertises itself on the local network for Settings to find.": "このiPhoneとのペアリングにはWi-Fiが必要です。設定アプリが検出できるよう、LocalStoreをローカルネットワーク上に公開します。",
    "Then come back here — this continues automatically.": "接続後にこの画面へ戻ると、自動的に続行します。",
    "Turn on a loopback VPN": "ループバックVPNを接続",
    "Open a VPN app that tunnels to this iPhone — LocalDevVPN, ClashMi, or another. Any of them works.": "LocalDevVPNやClashMiなど、このiPhoneへ接続できるVPNアプリを開いてください。",
    "Tap Connect so the toggle turns on.": "接続操作を行い、VPNを有効にしてください。",
    "Keep Wi-Fi on, then come back here — this continues automatically.": "Wi-Fiを有効にしたままこの画面へ戻ると、自動的に続行します。",
    "Get LocalDevVPN": "LocalDevVPNを入手",
    "Wrong device IP": "デバイスIPが正しくありません",
    "The address in Settings › Advanced › Device IP is one this iPhone already holds, so there's nothing at the other end to connect to.": "設定の詳細にあるデバイスIPが、このiPhone自身のアドレスになっています。そのため接続先が見つかりません。",
    "Set it back to 10.7.0.1, the default. In LocalDevVPN that's the value under Settings › Device IP — not the address on its main screen, which is the tunnel's own end.": "既定値の10.7.0.1へ戻してください。LocalDevVPNでは、メイン画面のアドレスではなく、設定内のデバイスIPに表示される値です。",
    "If you changed LocalDevVPN's addresses, put its Device IP here, and make sure its Tunnel IP and subnet mask cover it.": "LocalDevVPNのアドレスを変更した場合は、そのデバイスIPを入力し、トンネルIPとサブネットマスクの範囲内にあることを確認してください。",
    "Import an .ipa first": "先にIPAを選択",
    "Tap “Import .ipa” above and pick the file — it can live anywhere the Files app can reach, including iCloud Drive or a USB drive.": "「IPAを選択」からファイルを選んでください。iCloud DriveやUSBドライブなど、ファイルアプリから参照できる場所を利用できます。",
    "Pair this iPhone in Settings": "設定でこのiPhoneをペアリング",
    "Open the Settings app, then go to Privacy & Security › Developer Mode.": "設定アプリを開き、プライバシーとセキュリティからデベロッパモードへ進んでください。",
    "Tap “Pair with LocalStore”.": "「LocalStoreとペアリング」を選択してください。",
    "Enter your iPhone’s passcode if it asks for it.": "求められた場合は、iPhoneのパスコードを入力してください。",
    "Come back to LocalStore, read the code it shows you, then type that same code into the prompt in Settings.": "LocalStoreへ戻り、表示された確認コードを設定アプリへ入力してください。",
    "A signing certificate already exists": "署名証明書がすでに存在します",
    "Apple returned error 7460: this Apple ID already has an iOS development certificate, or a request for one is still pending.": "Appleからエラー7460が返されました。このAppleアカウントにはiOS開発用証明書がすでに存在するか、証明書の要求が処理中です。",
    "LocalStore couldn't reuse it. That happens when the certificate was issued somewhere else — AltStore, SideStore, Sideloadly or Xcode on another device — so the private key it needs isn't on this iPhone.": "既存の証明書を再利用できませんでした。別の端末上のAltStore、SideStore、Sideloadly、Xcodeなどで証明書が発行され、必要な秘密鍵がこのiPhoneにない場合に発生します。",
    "Use “Revoke and retry” in the install screen to choose the certificate explicitly.": "インストール画面から証明書を確認し、失効させる証明書を選択してください。",
    "Revoking is permanent: every app already signed with that certificate stops launching, on every device.": "証明書の失効は取り消せません。その証明書で署名したすべてのアプリが、すべての端末で起動できなくなります。",
    "Alternatively, save a different Apple Account in Settings, then try the install again.": "別のAppleアカウントを設定して、インストールをやり直すこともできます。",
    "Your Apple ID has hit its limit of registered devices. Free accounts can only register a handful of devices per year and can't remove old ones until the year resets.": "Appleアカウントのデバイス登録上限に達しています。無料アカウントで年間に登録できる端末数には制限があり、期間が更新されるまで古い端末を削除できません。",
    "Easiest fix: save a different Apple Account in Settings, then try the install again.": "別のAppleアカウントを設定して、インストールをやり直してください。",
    "LocalStore couldn't add this iPhone to your Apple ID's developer team automatically. Tapping Install again often works — Apple's developer service is sometimes briefly unavailable.": "このiPhoneをAppleアカウントの開発チームへ自動登録できませんでした。Appleの開発者サービスが一時的に利用できない場合があるため、もう一度インストールすると成功することがあります。",
    "If it keeps failing, add the device by hand. Its UDID is:": "失敗が続く場合は、端末を手動で追加してください。UDID：",
    "Paste that into the “Register a Device” form in the Apple Developer portal (this requires a paid Apple Developer account), then tap Install again.": "Apple Developerポータルの端末登録フォームへ貼り付けてください。この操作には有料のApple Developerアカウントが必要です。登録後、もう一度インストールしてください。",
    "Couldn't register this device": "端末を登録できませんでした",
    "Open device list": "端末一覧を開く",
    "Last step: trust %@": "最後の手順：%@を信頼",
    "Open Settings › General › VPN & Device Management.": "設定の一般からVPNとデバイス管理を開いてください。",
    "Tap your Apple ID under “Developer App”, then tap Trust.": "デベロッパAppに表示されたAppleアカウントを選び、「信頼」をタップしてください。",
    "Open %@ from your Home Screen — you're done.": "ホーム画面から%@を開けば完了です。",
    "Pairing is already in progress.": "ペアリングはすでに進行中です。",
    "Local Network permission is off. Enable it in Settings › LocalStore › Local Network, then try again.": "ローカルネットワークの権限が無効です。設定のLocalStoreからローカルネットワークを有効にして、もう一度試してください。",
    "Pairing produced an empty file. Make sure you approved the pairing request, then try again.": "ペアリング情報が空です。ペアリング要求を許可したことを確認して、もう一度試してください。",
    "requesting Local Network…": "ローカルネットワークの許可を確認中…",
    "Local Network denied": "ローカルネットワークは未許可",
    "waiting for device…": "端末を待機中…",
    "failed: empty pairing file": "失敗：ペアリング情報が空です",
    "paired: %@ (%dB)": "ペアリング済み：%@（%dバイト）",
    "failed: %@": "失敗：%@",
    "advertising — open Settings › Privacy & Security › Developer Mode": "ペアリング待機中：設定のプライバシーとセキュリティからデベロッパモードを開いてください",
    "enter PIN %@ in Settings": "設定画面へ確認コード%@を入力してください",
]

private func localizedJapanese(_ key: String) -> String {
    japaneseStrings[key] ?? key
}

func japaneseBackendError(_ raw: String, fallback: String) -> String {
    let lower = raw.lowercased()
    if raw.unicodeScalars.contains(where: {
        (0x3040...0x30ff).contains($0.value) || (0x4e00...0x9fff).contains($0.value)
    }) {
        return raw
    }
    if lower.contains("incorrect") && lower.contains("password") {
        return "Appleアカウントまたはパスワードが正しくありません。"
    }
    if lower.contains("maximum number of certificates") || lower.contains("7460") {
        return "開発用証明書の上限に達しているか、証明書要求が処理中です（エラー7460）。"
    }
    if lower.contains("maximum number of devices") {
        return "Appleアカウントの登録可能な端末数の上限に達しています。"
    }
    if lower.contains("device registration") || lower.contains("8220") {
        return "このiPhoneをAppleアカウントの開発チームへ登録できませんでした（エラー8220）。"
    }
    if lower.contains("cancel") { return "処理がキャンセルされました。" }
    if lower.contains("timeout") || lower.contains("timed out") {
        return "通信が時間内に完了しませんでした。"
    }
    if lower.contains("connection refused") || lower.contains("not connected") {
        return "端末への接続が拒否されました。接続状態を確認してください。"
    }
    if lower.contains("pair") { return "ペアリング処理に失敗しました。" }
    if lower.contains("certificate") { return "開発用証明書の処理に失敗しました。" }
    if lower.contains("provision") { return "プロビジョニングプロファイルの処理に失敗しました。" }
    if lower.contains("sign") { return "アプリの署名処理に失敗しました。" }
    if lower.contains("install") { return "アプリのインストール処理に失敗しました。" }
    return fallback
}

func japaneseTeamName(_ value: String) -> String {
    value
        .replacingOccurrences(of: "Personal Team", with: "個人チーム")
        .replacingOccurrences(of: "Individual", with: "個人")
}

func L(_ key: String) -> String {
    localizedJapanese(key)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localizedJapanese(key), locale: Locale(identifier: "ja_JP"), arguments: arguments)
}
