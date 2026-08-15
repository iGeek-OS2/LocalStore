#if DEBUG
import SwiftUI

private let previewIPA = ImportedAppMetadata(
    name: "Dopamine",
    bundleID: "com.example.dopamine",
    version: "2.4.5",
    build: "15",
    minimumOS: "15.0",
    fileSizeBytes: 18_874_368,
    iconBase64: nil)

@MainActor
private struct AppsPreviewHost: View {
    @StateObject private var engine: Engine
    @StateObject private var certManager: CertManager
    @StateObject private var store: InstalledAppsStore
    @State private var selectedTab: AppTab = .installed
    @State private var settingsPath: [SettingsRoute] = []

    init(setupComplete: Bool, samples: Bool) {
        _engine = StateObject(wrappedValue: .preview(setupComplete: setupComplete))
        _certManager = StateObject(wrappedValue: .preview(verified: setupComplete))
        _store = StateObject(wrappedValue: .preview(withSamples: samples))
    }

    var body: some View {
        ContentView(selectedTab: $selectedTab, settingsPath: $settingsPath)
            .environmentObject(engine)
            .environmentObject(certManager)
            .environmentObject(store)
    }
}

@MainActor
private struct SettingsPreviewHost: View {
    @StateObject private var engine = Engine.preview(setupComplete: true)
    @StateObject private var certManager = CertManager.preview(verified: true)
    @State private var path: [SettingsRoute] = []

    var body: some View {
        SettingsView(path: $path)
            .environmentObject(engine)
            .environmentObject(certManager)
    }
}

@MainActor
private struct InstallPreviewHost: View {
    @StateObject private var engine: Engine
    @StateObject private var certManager = CertManager.preview(verified: true)
    @StateObject private var store = InstalledAppsStore.preview(withSamples: false)
    private let started: Bool

    init(started: Bool) {
        self.started = started
        let states: [Step: StepState]? = started ? [
            .network: .done,
            .pair: .done,
            .connect: .done,
            .signIn: .done,
            .download: .done,
            .sign: .active,
            .install: .pending,
        ] : nil
        _engine = StateObject(wrappedValue: .preview(
            setupComplete: true,
            importedApp: previewIPA,
            stepStates: states,
            installProgress: started ? 0.68 : 0))
    }

    var body: some View {
        InstallSheet(previewStarted: started)
            .environmentObject(engine)
            .environmentObject(certManager)
            .environmentObject(store)
    }
}

@MainActor
private struct ProgressAnimationPreviewHost: View {
    private struct Stage {
        let title: String
        let progress: Double
    }

    private let stages = [
        Stage(title: "VPNへ接続", progress: 0.04),
        Stage(title: "このiPhoneを確認", progress: 0.16),
        Stage(title: "Appleアカウントへサインイン", progress: 0.34),
        Stage(title: "IPAを準備", progress: 0.52),
        Stage(title: "アプリを署名", progress: 0.72),
        Stage(title: "アプリをインストール", progress: 0.91),
        Stage(title: "インストール済み", progress: 1.0),
    ]

    @State private var stageIndex = 0

    var body: some View {
        NavigationStack {
            List {
                Section("進行状況") {
                    InstallProgressPanel(progress: stages[stageIndex].progress,
                                         title: stages[stageIndex].title)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("インストール")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.35))
                guard !Task.isCancelled else { return }
                stageIndex = (stageIndex + 1) % stages.count
            }
        }
    }
}

#Preview("初回セットアップ") {
    AppsPreviewHost(setupComplete: false, samples: false)
}

#Preview("準備未完了・履歴あり") {
    AppsPreviewHost(setupComplete: false, samples: true)
}

#Preview("アプリ一覧・個人署名の空き") {
    AppsPreviewHost(setupComplete: true, samples: true)
}

#Preview("設定・確認済みアカウント") {
    SettingsPreviewHost()
}

#Preview("IPA確認") {
    InstallPreviewHost(started: false)
}

#Preview("インストール進行中") {
    InstallPreviewHost(started: true)
}

#Preview("進捗アニメーション") {
    ProgressAnimationPreviewHost()
}
#endif
