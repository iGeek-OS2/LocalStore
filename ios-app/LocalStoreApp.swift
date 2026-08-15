import SwiftUI

@main
struct LocalStoreApp: App {
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
        }
    }
}

enum AppTab: Hashable {
    case installed
    case settings
}

enum SettingsRoute: Hashable {
    case account
    case pairing
    case activity
}

struct RootView: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var certManager = CertManager()
    @StateObject private var installedApps = InstalledAppsStore.shared
    @State private var selection: AppTab = .installed
    @State private var settingsPath: [SettingsRoute] = []
    @State private var twoFactorCode = ""

    var body: some View {
        TabView(selection: $selection) {
            Tab("インストール済み", systemImage: "square.stack.3d.up", value: .installed) {
                ContentView(selectedTab: $selection, settingsPath: $settingsPath)
            }
            Tab("設定", systemImage: "gearshape", value: .settings) {
                SettingsView(path: $settingsPath)
            }
        }
        .environmentObject(certManager)
        .environmentObject(installedApps)
        .tint(.primary)
        .alert("確認コード", isPresented: $engine.pendingTwoFactor) {
            TextField("6桁のコード", text: $twoFactorCode)
                .keyboardType(.numberPad)
            Button("確認") {
                engine.submitTwoFactor(twoFactorCode)
                twoFactorCode = ""
            }
            Button("キャンセル", role: .cancel) {
                engine.cancelTwoFactor()
                twoFactorCode = ""
            }
        } message: {
            Text("信頼済みの端末に表示されたコードを入力してください。")
        }
        .task { refreshInstalledApps() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                engine.refreshPairingStatus()
                refreshInstalledApps()
            }
        }
        .onChange(of: certManager.teamSummary) { _, _ in
            refreshInstalledApps()
        }
        .onChange(of: engine.isRunning) { _, running in
            if !running { refreshInstalledApps() }
        }
    }

    private func refreshInstalledApps() {
        // LaunchServices/profile scanning is synchronous. Never let a team
        // update during sign-in block the active pairing/install pipeline.
        guard !engine.isRunning else { return }
        let removed = installedApps.refreshPersonalSignedApps(
            personalTeamID: certManager.personalTeamID)
        for app in removed {
            engine.log("\(app.name)は端末上に見つからないため、一覧から削除しました。")
        }
    }
}
