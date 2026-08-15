import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ObjectiveC.runtime

struct ContentView: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var certManager: CertManager
    @EnvironmentObject private var store: InstalledAppsStore
    @Binding var selectedTab: AppTab
    @Binding var settingsPath: [SettingsRoute]

    @State private var showImporter = false
    @State private var showInstall = false
    @State private var importError: String?
    @State private var pendingRemoval: InstalledAppRecord?

    private static let importableTypes: [UTType] = [.data]

    private var accountReady: Bool {
        engine.hasSavedAccount && certManager.isVerified(email: engine.normalizedAppleID)
    }

    private var setupReady: Bool {
        engine.osSupported && accountReady && engine.pairingVerified && engine.vpnConnected
    }

    var body: some View {
        NavigationStack {
            List {
                if engine.initialSetupStateResolved && !setupReady {
                    setupSection
                }

                if !store.apps.isEmpty {
                    Section {
                        ForEach(store.apps) { app in
                            InstalledAppRow(
                                app: app,
                                isRemoving: engine.uninstallingBundleID == app.bundleID)
                            .contextMenu {
                                Button("削除", systemImage: "trash", role: .destructive) {
                                    pendingRemoval = app
                                }
                                .disabled(engine.uninstallingBundleID != nil)
                            }
                        }
                    } header: {
                        Text("インストール済みのアプリ")
                    } footer: {
                        PersonalSigningLimitFooter(apps: store.apps)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 12, for: .scrollContent)
            .navigationTitle("アプリ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("IPAを選択", systemImage: "plus") {
                        showImporter = true
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!engine.initialSetupStateResolved || !setupReady || engine.isImportingIPA)
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: Self.importableTypes) { result in
                guard case let .success(url) = result else { return }
                Task {
                    await engine.importCustomIPA(from: url)
                    if engine.importedApp != nil, engine.lastError == nil {
                        showInstall = true
                    } else {
                        importError = engine.lastError ?? "IPA情報を取得できません。"
                    }
                }
            }
            .sheet(isPresented: $showInstall) {
                InstallSheet()
            }
            .confirmationDialog(
                pendingRemoval.map { "\($0.name)を削除しますか？" } ?? "アプリを削除しますか？",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible) {
                    if let app = pendingRemoval {
                        Button("アプリを削除", role: .destructive) {
                            pendingRemoval = nil
                            Task { await engine.uninstall(app) }
                        }
                    }
                    Button("キャンセル", role: .cancel) { pendingRemoval = nil }
                } message: {
                    Text("iPhoneからアプリ本体とそのデータを削除します。")
                }
            .alert("IPAを読み込めませんでした",
                   isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } })) {
                Button("閉じる") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .alert("アプリを削除できませんでした",
                   isPresented: Binding(
                    get: { engine.uninstallError != nil },
                    set: { if !$0 { engine.uninstallError = nil } })) {
                Button("閉じる") { engine.uninstallError = nil }
            } message: {
                Text(engine.uninstallError ?? "")
            }
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        Section {
            setupButton(title: "Appleアカウントを確認",
                        detail: accountReady ? "確認済み" : "2ファクタ認証と証明書の確認",
                        complete: accountReady)
            SetupStepRow(title: "このiPhoneとペアリング",
                         detail: pairingStepDetail,
                         complete: engine.pairingVerified)
            if let pin = engine.pairingPIN {
                LabeledContent("確認コード") {
                    Text(pin)
                        .font(.title2.monospacedDigit().weight(.semibold))
                }
            }
            if let error = engine.setupPairingError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if engine.vpnConnected {
                SetupStepRow(title: "LocalDevVPNを接続",
                             detail: "接続済み",
                             complete: true)
            } else {
                HStack(spacing: 12) {
                    SetupStepRow(title: "LocalDevVPNを接続",
                                 detail: "入手してVPNを接続",
                                 complete: false)
                    Spacer(minLength: 4)
                    Link("入手", destination: Self.localDevVPNURL)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.primary, in: Capsule())
                        .buttonStyle(.plain)
                }
            }
            if !engine.osSupported {
                SetupStepRow(title: "対応するiOSが必要",
                             detail: "iOS \(Engine.minimumOSText)以降が必要です",
                             complete: false)
            }
        } header: {
            Text("初期設定")
        } footer: {
            Text("上から順に完了するとIPAを選択できます。")
        }
    }

    private static let localDevVPNURL = URL(string: "https://apps.apple.com/app/id6755608044")!

    private var pairingStepDetail: String {
        if engine.pairingVerified { return "完了" }
        if engine.needsFreshPairing { return "デベロッパーモードで許可" }
        return "VPN接続後に確認します"
    }

    private func setupButton(title: String, detail: String, complete: Bool) -> some View {
        Button {
            openSettings(.account)
        } label: {
            SetupStepRow(title: title, detail: detail, complete: complete)
        }
        .buttonStyle(.plain)
        .disabled(complete)
    }

    private func openSettings(_ route: SettingsRoute) {
        settingsPath = [route]
        selectedTab = .settings
    }
}

private struct PersonalSigningLimitFooter: View {
    let apps: [InstalledAppRecord]

    private var localStoreUsesSlot: Bool {
        LocalStoreSignature.usesPersonalProvisioningSlot
    }

    private var remainingCount: Int {
        let used = apps.count + (localStoreUsesSlot ? 1 : 0)
        return max(0, 3 - used)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("個人署名の空き")
                Spacer()
                Text("\(remainingCount)/3")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            Text("LocalStore本体が個人署名の場合は、本体も1個として数えます。")
        }
    }
}

private struct SetupStepRow: View {
    let title: String
    let detail: String
    let complete: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(complete ? .primary : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(complete ? .green : .red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct InstalledAppRow: View {
    let app: InstalledAppRecord
    let isRemoving: Bool

    var body: some View {
        HStack(spacing: 16) {
            AppIconView(image: app.icon, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                Text([app.version, app.bundleID].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isRemoving {
                ProgressView()
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let days = app.remainingSigningDays(at: context.date)
                    if days > 0 {
                        Text("残り\(days)日")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("期限切れ")
                            .foregroundStyle(.red)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            }
        }
        .padding(.vertical, 6)
    }
}

private struct AppIconView: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size / 4)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

struct InstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var certManager: CertManager
    @State private var started = false
    @State private var showRevokeChooser = false
    @State private var openAppError = false
    @State private var detent: PresentationDetent = .medium
    @State private var showNameEditor = false
    @State private var showBundleIDEditor = false
    @State private var editedValue = ""
    @State private var showInstallLog = false

    init(previewStarted: Bool = false) {
        _started = State(initialValue: previewStarted)
        _detent = State(initialValue: previewStarted ? .large : .medium)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ImportedAppRow(metadata: engine.importedApp,
                                   name: engine.editedAppName,
                                   bundleID: engine.editedBundleID)
                        .contextMenu {
                            Button("アプリ名を変更", systemImage: "pencil") {
                                editedValue = engine.editedAppName
                                showNameEditor = true
                            }
                            .disabled(started)
                            Button("バンドルIDを変更", systemImage: "number") {
                                editedValue = engine.editedBundleID
                                showBundleIDEditor = true
                            }
                            .disabled(started)
                        }
                    if let error = engine.importedIdentityError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !started {
                    InstallMetadataSection(metadata: engine.importedApp)

                    Section {
                        Button {
                            withAnimation(.smooth(duration: 0.45)) {
                                started = true
                                detent = .large
                            }
                            engine.runOneClick()
                        } label: {
                            InstallActionButtonLabel(title: "インストール")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                        .controlSize(.large)
                        .disabled(engine.importedApp == nil || engine.importedIdentityError != nil)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section("進行状況") {
                        InstallProgressPanel(progress: engine.overallProgress,
                                             title: engine.currentStepTitle)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                    Section {
                        Button {
                            withAnimation(.smooth(duration: 0.25)) {
                                showInstallLog.toggle()
                            }
                        } label: {
                            HStack {
                                Label(showInstallLog ? "ログを隠す" : "ログを表示",
                                      systemImage: "terminal")
                                Spacer()
                                Image(systemName: showInstallLog ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        if showInstallLog {
                            InstallLogConsole(entries: engine.lines)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.black)
                                .transition(.opacity)
                        }
                    }

                    if engine.finished {
                        Section {
                            Button {
                                openAppError = !InstalledAppLauncher.open(
                                    bundleID: engine.installedBundleID)
                            } label: {
                                InstallActionButtonLabel(title: "アプリを開く")
                            }
                            .buttonStyle(.glassProminent)
                            .tint(.black)
                            .controlSize(.large)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let pin = engine.pairingPIN {
                        Section("ペアリングコード") {
                            Text(pin)
                                .font(.largeTitle.monospacedDigit().weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                    }

                    if let guide = engine.guide,
                       guide != Guides.pairing,
                       !engine.finished {
                        Section(guide.title) {
                            ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(index + 1).")
                                        .fontWeight(.semibold)
                                    Text(step)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }

                    if engine.certConflict, !engine.isRunning {
                        Section("証明書の競合") {
                            Text("既存の証明書を失効させると、その証明書で署名した他のアプリも開けなくなります。")
                                .foregroundStyle(.secondary)
                            Button("証明書を確認", role: .destructive) {
                                certManager.ensureLoaded { showRevokeChooser = true }
                            }
                            .disabled(certManager.isWorking)
                        }
                    }

                    if let error = engine.lastError, !engine.isRunning {
                        Section("インストールできませんでした") {
                            Text(error)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                            Button("再試行", systemImage: "arrow.clockwise") {
                                engine.retryOneClick()
                            }
                        }
                    }

                }
            }
            .animation(.smooth(duration: 0.4), value: engine.finished)
            .navigationTitle("インストール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(engine.isRunning ? "インストールを中止" : "閉じる",
                           systemImage: "xmark") {
                        if engine.isRunning {
                            engine.cancelOneClick()
                        }
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .confirmationDialog("失効させる証明書", isPresented: $showRevokeChooser,
                                titleVisibility: .visible) {
                ForEach(certManager.certs) { cert in
                    Button(cert.displayName, role: .destructive) {
                        certManager.revoke(cert) { engine.runOneClick() }
                    }
                }
                Button("キャンセル", role: .cancel) { }
            }
            .alert("アプリを開けませんでした", isPresented: $openAppError) {
                Button("閉じる", role: .cancel) { }
            } message: {
                Text("ホーム画面から\(engine.installedAppName)を開いてください。")
            }
            .alert("インストールに失敗しました",
                   isPresented: $engine.showInstallFailureAlert) {
                Button("再試行") { engine.retryOneClick() }
                Button("エラーをコピー") {
                    UIPasteboard.general.string = engine.lastError ?? ""
                    engine.dismissInstallFailureAlert()
                }
                Button("閉じる", role: .cancel) {
                    engine.dismissInstallFailureAlert()
                }
            } message: {
                Text(engine.lastError ?? "不明なエラーが発生しました。")
            }
            .alert("アプリ名を変更", isPresented: $showNameEditor) {
                TextField("アプリ名", text: $editedValue)
                Button("変更") {
                    engine.editedAppName = editedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .disabled(editedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("キャンセル", role: .cancel) { }
            }
            .alert("バンドルIDを変更", isPresented: $showBundleIDEditor) {
                TextField("バンドルID", text: $editedValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("変更") {
                    engine.editedBundleID = editedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .disabled(editedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("キャンセル", role: .cancel) { }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .interactiveDismissDisabled(engine.isRunning)
        .onChange(of: engine.showInstallFailureAlert) { _, presented in
            if presented { showInstallLog = true }
        }
    }
}

private struct InstallLogConsole: View {
    let entries: [Engine.LogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if entries.isEmpty {
                        Text("ログはまだありません。")
                            .foregroundStyle(.gray)
                    } else {
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.stamp)
                                    .foregroundStyle(.gray)
                                Text(entry.text)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(entry.id)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(12)
                .textSelection(.enabled)
            }
            .frame(height: 220)
            .background(Color.black)
            .onAppear { scrollToLatest(proxy) }
            .onChange(of: entries.count) { _, _ in scrollToLatest(proxy) }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let id = entries.last?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

struct InstallProgressPanel: View {
    let progress: Double
    let title: String

    private var normalizedProgress: Double {
        min(1, max(0, progress))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ZStack(alignment: .leading) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .offset(y: -2)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .clipped()

                AnimatedProgressNumber(progress: normalizedProgress)
                    .animation(.smooth(duration: 0.65, extraBounce: 0),
                               value: normalizedProgress)
            }

            AnimatedProgressBar(progress: normalizedProgress)
                .animation(.smooth(duration: 0.65, extraBounce: 0),
                           value: normalizedProgress)
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("進捗")
            .accessibilityValue("\(Int((normalizedProgress * 100).rounded()))パーセント")
        }
        .padding(.vertical, 6)
    }
}

private struct AnimatedProgressNumber: View, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Text("\(Int((progress * 100).rounded()))%")
            .font(.system(.title2, design: .rounded, weight: .bold))
            .monospacedDigit()
    }
}

private struct AnimatedProgressBar: View, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                Capsule(style: .continuous)
                    .fill(.primary)
                    .frame(width: geometry.size.width * progress)
            }
        }
    }
}

private struct InstallMetadataSection: View {
    let metadata: ImportedAppMetadata?

    var body: some View {
        Section {
            if let build = metadata?.build, !build.isEmpty {
                LabeledContent("ビルド番号", value: build)
            }
            if let minimumOS = metadata?.minimumOS, !minimumOS.isEmpty {
                LabeledContent("最低対応iOS", value: "iOS \(minimumOS)以降")
            }
            if let bytes = metadata?.fileSizeBytes, bytes > 0 {
                LabeledContent("ファイルサイズ",
                               value: ByteCountFormatter.string(fromByteCount: bytes,
                                                                countStyle: .file))
            }
        } header: {
            Text("詳細")
        }
    }
}

private struct InstallActionButtonLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ImportedAppRow: View {
    let metadata: ImportedAppMetadata?
    let name: String
    let bundleID: String

    var body: some View {
        HStack(spacing: 16) {
            AppIconView(image: metadata?.icon, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(bundleID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let version = metadata?.version, !version.isEmpty {
                    Text("バージョン \(version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private enum InstalledAppLauncher {
    static func open(bundleID: String) -> Bool {
        guard !bundleID.isEmpty,
              let workspaceClass: AnyClass = NSClassFromString("LSApplicationWorkspace"),
              let defaultMethod = class_getClassMethod(
                workspaceClass, NSSelectorFromString("defaultWorkspace"))
        else { return false }

        typealias DefaultWorkspace = @convention(c) (AnyClass, Selector) -> AnyObject?
        let getWorkspace = unsafeBitCast(method_getImplementation(defaultMethod),
                                         to: DefaultWorkspace.self)
        guard let workspace = getWorkspace(
            workspaceClass, NSSelectorFromString("defaultWorkspace"))
        else { return false }

        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        guard let method = class_getInstanceMethod(workspaceClass, selector) else { return false }
        typealias OpenApplication = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let open = unsafeBitCast(method_getImplementation(method), to: OpenApplication.self)
        return open(workspace, selector, bundleID as NSString)
    }
}
