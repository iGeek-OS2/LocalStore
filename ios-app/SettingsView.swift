import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var certManager: CertManager
    @Binding var path: [SettingsRoute]

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    NavigationLink(value: SettingsRoute.account) {
                        LabeledContent("アカウント") {
                            Text(engine.normalizedAppleID.isEmpty ? "未設定" : engine.normalizedAppleID)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Appleアカウント")
                } footer: {
                    Text("Appleで本人確認を行い、確認できた開発用証明書を表示します。")
                }

                Section("セットアップ") {
                    NavigationLink(value: SettingsRoute.pairing) {
                        LabeledContent("このiPhoneとのペアリング") {
                            Text(pairingSummary)
                                .foregroundStyle(engine.pairingVerified ? .green : .red)
                        }
                    }
                }

                Section("接続") {
                    LabeledContent("ループバックVPN") {
                        Text(engine.vpnConnected ? "接続済み" : "未接続")
                            .foregroundStyle(engine.vpnConnected ? .green : .red)
                    }
                    if !engine.vpnConnected {
                        Link("LocalDevVPNをApp Storeで入手",
                             destination: URL(string: "https://apps.apple.com/app/id6755608044")!)
                    }
                }

                Section("詳細") {
                    HStack {
                        Text("デバイスIP")
                        Spacer()
                        TextField("10.7.0.1", text: $engine.deviceIP)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("アクティビティログ", value: SettingsRoute.activity)
                }

                Section {
                    LabeledContent("アプリ", value: "LocalStore")
                    LabeledContent("バージョン", value: Bundle.main.releaseVersionNumber ?? "-")
                    Link("基盤：FrizzleM氏のSideInstaller",
                         destination: URL(string: "https://github.com/FrizzleM/SideInstaller")!)
                } header: {
                    Text("アプリについて")
                } footer: {
                    Text("認証・署名・端末接続の基盤には、FrizzleM氏のSideInstaller由来コードを使用しています。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .account:
                    AccountSettingsView()
                case .pairing:
                    PairingSetupView()
                case .activity:
                    ActivityLogView()
                }
            }
            .onAppear {
                engine.refreshNetworkStatus()
            }
        }
    }

    private var pairingSummary: String {
        engine.pairingVerified ? "ペアリング済み" : "ペアリングされていません"
    }
}

private struct AccountSettingsView: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var certManager: CertManager
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var showAccountDeletionConfirmation = false

    private var signedIn: Bool {
        certManager.isVerified(email: engine.normalizedAppleID)
    }

    var body: some View {
        Form {
            Section {
                TextField("メールアドレス", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                SecureField(engine.hasSavedAccount ? "保存済みのパスワード" : "パスワード",
                            text: $password)
                    .textContentType(.password)
            } footer: {
                Text("パスワードはiOSのキーチェーンに「このデバイスのみ・ロック解除中のみ」の条件で保存します。設定ファイルやユーザー設定には保存しません。")
            }

            Section {
                if !signedIn {
                    Button("Appleアカウントでサインイン") {
                        do {
                            let value = password.isEmpty ? engine.applePassword : password
                            certManager.signOut()
                            try engine.saveAccount(email: email, password: value)
                            password = ""
                            error = nil
                            certManager.loadCerts()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(certManager.isWorking)
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (password.isEmpty && engine.applePassword.isEmpty))
                }

                if certManager.isWorking {
                    HStack {
                        ProgressView()
                        Text("サインイン中...")
                    }
                }

                if engine.hasSavedAccount {
                    Button("このアカウントを削除", role: .destructive) {
                        showAccountDeletionConfirmation = true
                    }
                }
            }

            if signedIn,
               let team = certManager.teamSummary, !team.isEmpty {
                Section {
                    Text("team: \(teamNameWithoutLabel(team))")
                }
            }

            if certManager.hasLoaded,
               certManager.isVerified(email: engine.normalizedAppleID) {
                Section("開発用証明書") {
                    if certManager.certs.isEmpty {
                        Text("開発用証明書はありません。インストール時に必要な証明書を作成します。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(certManager.certs) { cert in
                            CertificateRow(cert: cert)
                        }
                    }
                }
            }

            if let error = error ?? certManager.lastError {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Appleアカウント")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { email = engine.appleID }
        .confirmationDialog("Appleアカウントを削除しますか？",
                            isPresented: $showAccountDeletionConfirmation,
                            titleVisibility: .visible) {
            Button("アカウントを削除", role: .destructive) {
                certManager.signOut()
                engine.forgetAccount()
                email = ""
                password = ""
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("保存したメールアドレス、パスワード、証明書情報をこのアプリから削除します。")
        }
    }

    private func teamNameWithoutLabel(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"^\s*team\s*:\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive])
    }
}

private struct CertificateRow: View {
    let cert: DevCert

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cert.displayName)
            Text(details)
                .font(.footnote)
                .foregroundStyle(cert.isExpired ? .red : .secondary)
        }
    }

    private var details: String {
        var values = [cert.localizedStatus].filter { !$0.isEmpty }
        if let date = cert.expiresAt {
            values.append("有効期限 \(date.formatted(date: .numeric, time: .omitted))")
        }
        if let machine = cert.machineLabel { values.append(machine) }
        return values.joined(separator: " · ")
    }
}

private struct PairingSetupView: View {
    @EnvironmentObject private var engine: Engine

    var body: some View {
        Form {
            Section {
                LabeledContent("状態") {
                    Text(engine.pairingVerified
                         ? "ペアリング済み"
                         : "ペアリングされていません")
                        .foregroundStyle(engine.pairingVerified ? .green : .red)
                }
                LabeledContent("Wi-Fi") {
                    Text(engine.wifiConnected ? "接続済み" : "未接続")
                        .foregroundStyle(engine.wifiConnected ? .green : .red)
                }
                Button {
                    openPairingSettings()
                } label: {
                    HStack {
                        Text("ペアリングの設定画面に移動する")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("ペアリングの設定はプライバシーとセキュリティの下部のデベロッパーモード内にあります。")
            }

            if !engine.pairingVerified {
                Section {
                    PairingStartButton()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let pin = engine.pairingPIN {
                Section("確認コード") {
                    Text(pin)
                        .font(.largeTitle.monospacedDigit().weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
            }

            if let error = engine.setupPairingError {
                Section("ペアリングできませんでした") {
                    Text(error).foregroundStyle(.red)
                }
            }

        }
        .navigationTitle("ペアリング")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { engine.refreshNetworkStatus() }
    }

    private func openPairingSettings() {
        guard let url = URL(string: "prefs:root=Privacy&path=developerMode") else { return }
        UIApplication.shared.open(url)
    }
}

private struct PairingStartButton: View {
    @EnvironmentObject private var engine: Engine

    var body: some View {
        Button {
            Task { await engine.startSetupPairing() }
        } label: {
            HStack(spacing: 8) {
                if engine.setupPairingInProgress {
                    ProgressView().tint(.white)
                }
                Text(engine.setupPairingInProgress ? "ペアリング中" : "ペアリングを開始")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.glassProminent)
        .tint(.blue)
        .controlSize(.large)
        .disabled(!engine.wifiConnected || engine.setupPairingInProgress)
    }
}

private struct ActivityLogView: View {
    @EnvironmentObject private var engine: Engine

    var body: some View {
        List(engine.lines) { line in
            Text("\(line.stamp)  \(line.text)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .navigationTitle("アクティビティログ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("コピー", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = engine.logText()
                }
                .labelStyle(.iconOnly)
                Button("消去", systemImage: "trash", role: .destructive) {
                    engine.clearLog()
                }
                .labelStyle(.iconOnly)
            }
        }
    }
}

private extension Bundle {
    var releaseVersionNumber: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
