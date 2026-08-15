import Foundation
import OnDeviceCore

/// One ordered step of the one-click install.
enum Step: Int, CaseIterable, Identifiable {
    case network, pair, connect, signIn, download, sign, install

    var id: Int { rawValue }

    func title() -> String {
        switch self {
        case .network:      return L("Connect the VPN")
        case .pair:         return L("Pair with this iPhone")
        case .connect:      return L("Open the device link")
        case .signIn:       return L("Sign in to Apple ID")
        case .download:     return L("Prepare the imported IPA")
        case .sign:         return L("Sign the app")
        case .install:      return L("Install the app")
        }
    }
}

enum StepState {
    case pending   // not started
    case active    // running
    case waiting   // running, but blocked on something the user must do
    case done      // finished OK
    case failed    // stopped here
}

/// A contextual instruction card shown to the user.
struct Guide: Equatable {
    var title: String
    var systemImage: String
    var steps: [String]
    var actionLabel: String?
    var actionURLString: String?

    var actionURL: URL? { actionURLString.flatMap(URL.init(string:)) }
}

/// A step failure carrying a user-facing message.
enum EngineError: LocalizedError {
    case message(String)
    /// Apple error 7460: a signing certificate already exists or is pending.
    case certExists
    /// Apple error 8220: the device UDID couldn't be registered with the team.
    case deviceRegistration(udid: String, raw: String)

    var errorDescription: String? {
        switch self {
        case let .message(m):
            return m
        case .certExists:
            return L("Apple won't issue a signing certificate for this Apple ID: it reports that one already exists, or that a request for one is still pending (error 7460). LocalStore couldn't reuse the certificate that's already there, so it stopped instead of replacing it. See the steps above.")
        case let .deviceRegistration(udid, raw):
            let tail = udid.isEmpty ? "" : L(" (UDID %@)", udid)
            return L("Couldn't register this iPhone%@ with your Apple ID's developer team, so Apple won't issue a provisioning profile. %@ — see the steps above.",
                     tail, raw)
        }
    }
}

/// All install logic. A singleton so the C log callback can reach it.
final class Engine: ObservableObject {

    static let shared = Engine()

    // MARK: Log console

    struct LogEntry: Identifiable {
        let id = UUID()
        let stamp: String
        let text: String
    }

    @Published private(set) var lines: [LogEntry] = []

    // MARK: Inputs

    @Published var appleID: String = ""
    @Published var applePassword: String = ""
    let anisetteURL = "https://ani.sidestore.io"
    // The loopback VPN's device-side IP; configurable in Advanced.
    @Published var deviceIP: String = "10.7.0.1"
    // MARK: Plain-text status readouts

    /// Loopback-tunnel state, polled by `startStatusMonitor`.
    @Published var vpnConnected: Bool = false
    /// Wi-Fi (`en0`) state, polled alongside the tunnel.
    @Published var wifiConnected: Bool = false
    @Published var vpnStatus: String = "不明"
    @Published var wifiStatus: String = "不明"

    /// Lowest iOS the install pipeline supports.
    static let minimumOSMajorVersion = 26
    /// The same number as text, for UI copy.
    static var minimumOSText: String { "\(minimumOSMajorVersion)" }

    /// False when this iPhone is older than `minimumOSMajorVersion`.
    var osSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: Engine.minimumOSMajorVersion,
                                   minorVersion: 0, patchVersion: 0))
    }

    /// This iPhone's iOS version, e.g. "18.5".
    var osVersionText: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
    @Published var pairingStatus: String = L("not paired")
    private var previewPairingReady: Bool?
    /// True while a non-empty pairing record exists and the iPhone has not
    /// explicitly rejected it. VPN availability is tracked separately: losing
    /// the tunnel must never turn a paired device into an unpaired one.
    @Published private(set) var pairingVerified = false
    /// The saved record can be reflected immediately; a live check runs quietly
    /// when the tunnel is available and only an explicit rejection invalidates it.
    @Published private(set) var initialSetupStateResolved = false
    /// The local record can remain after the iPhone revokes its trust. This is
    /// set only when a live pair-verify request is explicitly rejected.
    @Published private var pairingRecordRejected = false
    @Published private(set) var setupPairingInProgress = false
    @Published var setupPairingError: String?
    @Published var signInStatus: String = "未サインイン"

    // Path to the pairing file produced by RPPairing.
    @Published var pairingFilePath: String?

    // MARK: One-click orchestration state

    /// Per-step status, behind the checklist and progress bar.
    @Published var stepStates: [Step: StepState] = Dictionary(
        uniqueKeysWithValues: Step.allCases.map { ($0, .pending) })

    /// Install percentage (0…1) streamed from installation_proxy.
    @Published var installProgress: Double = 0

    /// The pairing PIN to display prominently, when one has been issued.
    @Published var pairingPIN: String?

    /// Short human summary of the connected device, e.g. "iPhone · iOS 17.5".
    @Published var deviceSummary: String?

    /// The connected iPhone's UDID and name, from the lockdown handshake.
    private(set) var deviceUDID: String?
    private(set) var deviceName: String?

    /// The current contextual instruction card (nil = none).
    @Published var guide: Guide?

    /// True when signing stopped on error 7460; offers revoke-and-retry.
    @Published var certConflict: Bool = false

    /// True while the one-click pipeline is running.
    @Published var isRunning: Bool = false

    /// Set when the pipeline stops on an error; cleared on a new run.
    @Published var lastError: String?

    /// Separate presentation state so dismissing the alert does not erase the
    /// selectable error details shown in the install screen.
    @Published var showInstallFailureAlert = false

    /// Set once the whole pipeline has completed successfully.
    @Published var finished: Bool = false

    private var pipelineTask: Task<Void, Never>?
    /// Poll that keeps `vpnConnected` live; NWPathMonitor never fires for a
    /// loopback tunnel, which carries no default route.
    private var statusTimer: Timer?
    private var pairingValidationInProgress = false
    private var pairingValidationTask: Task<Void, Never>?

    /// Name of the imported app that was installed.
    var installedSourceName: String {
        signedDisplayName ?? L("your app")
    }

    /// Home-screen name of the app that landed on the device.
    var installedAppName: String {
        signedDisplayName ?? L("your app")
    }

    /// Bundle identifier of the app that was just installed.
    var installedBundleID: String {
        (signedAppPlist()?["CFBundleIdentifier"] as? String)
            ?? importedApp?.bundleID
            ?? ""
    }

    /// Overall fraction across all steps (0…1).
    var overallProgress: Double {
        let total = Double(Step.allCases.count)
        let done = Double(Step.allCases.filter { stepStates[$0] == .done }.count)
        let frac = (stepStates[.install] == .active || stepStates[.install] == .waiting)
            ? installProgress : 0
        return min(1, (done + frac) / total)
    }

    /// Short status used by the compact install sheet.
    var currentStepTitle: String {
        if finished { return "インストール済み" }
        if let step = Step.allCases.first(where: {
            stepStates[$0] == .active || stepStates[$0] == .waiting
        }) {
            return step.title()
        }
        if let next = Step.allCases.first(where: { stepStates[$0] == .pending }) {
            return next.title()
        }
        return "準備中"
    }

    // Long-lived device link over the loopback tunnel, serialized on deviceQueue.
    let connection = DeviceConnection()
    private let deviceQueue = DispatchQueue(label: "ondevicesigner.device")
    @Published private(set) var remotePairingPort: UInt16?

    // Apple ID sign-in and signing (isideload), serialized on signQueue.
    private let signQueue = DispatchQueue(label: "ondevicesigner.sign")
    private var signSession: OpaquePointer?          // SignSession*
    @Published var downloadedIPAPath: String?
    @Published var signedAppPath: String?
    /// CFBundleDisplayName read off the signed bundle.
    @Published private(set) var signedDisplayName: String?
    /// Filename of the retained user import, if any.
    @Published private(set) var customIPAName: String?
    /// Metadata read directly from the imported IPA before signing.
    @Published private(set) var importedApp: ImportedAppMetadata?
    /// User-editable identity applied before profiles are requested and the app is signed.
    @Published var editedAppName = ""
    @Published var editedBundleID = ""
    /// True while a picked IPA is being copied in.
    @Published private(set) var isImportingIPA = false

    var importedIdentityError: String? {
        let name = editedAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = editedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "アプリ名を入力してください。" }
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let valid = parts.count >= 2 && parts.allSatisfy { part in
            guard let first = part.unicodeScalars.first,
                  let last = part.unicodeScalars.last,
                  CharacterSet.alphanumerics.contains(first),
                  CharacterSet.alphanumerics.contains(last)
            else { return false }
            return part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        return valid ? nil : "バンドルIDは com.example.app の形式で入力してください。"
    }

    // 2FA bridge: the FFI callback blocks on this semaphore until the UI answers.
    @Published var pendingTwoFactor = false
    private let twoFactorSem = DispatchSemaphore(value: 0)
    private var twoFactorResult: String?
    /// Set when the user cancels the 2FA prompt, so sign-in stops re-prompting.
    var twoFactorWasCancelled = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init(preview: Bool = false) {
        if preview {
            initialSetupStateResolved = true
            return
        }
        if let credentials = CredentialStore.load() {
            appleID = credentials.email
            applePassword = credentials.password
        }
        installLogging()
        log("LocalStoreを起動しました。")
        // Self-test of the Rust tracing -> FFI callback -> console path.
        ping()
        let savedPairingPath = PairingController.pairingFilePath()
        if fileExistsNonEmpty(savedPairingPath) {
            pairingFilePath = savedPairingPath
            pairingVerified = true
            pairingStatus = "ペアリング済み"
        } else {
            pairingVerified = false
            pairingStatus = "ペアリングされていません"
        }
        // Do not flash the setup screen while the live verification is queued.
        initialSetupStateResolved = true
        // Show the tunnel/Wi-Fi status on launch, then keep it live.
        checkVPNAndWifi()
        startStatusMonitor()
        // Reflect an IPA imported in an earlier run.
        customIPAName = IPALibrary.customImport()?.url.lastPathComponent
    }

    // MARK: - Logging

    private func installLogging() {
        let rc = si_log_init(siLogCallback, nil)
        if rc == 0 {
            log("端末通信の診断ログを開始しました。")
        } else {
            log("端末通信の診断ログはすでに開始されています（コード：\(rc)）。")
        }
    }

    /// Append a line from Swift. Safe to call from any thread.
    func log(_ message: String) {
        appendLine(message)
    }

    /// Append a line that originated in the Rust core's tracing output.
    func appendRustLine(_ message: String) {
        let lower = message.lowercased()
        let isFailure = lower.contains("error") || lower.contains("failed")
            || lower.contains("warn")
        let isProgress = lower.contains("info") || lower.contains("milestone")
        guard isFailure || isProgress else { return }

        if isFailure {
            let localized = japaneseBackendError(
                message, fallback: "内部処理でエラーが発生しました。")
            let detail = localized == message ? localized : "\(localized) | 詳細：\(message)"
            appendLine("[内部] " + detail)
        } else {
            appendLine("[内部] " + message)
        }
    }

    /// How many log lines to keep; the oldest are dropped first.
    private static let maxLogLines = 2000

    private func appendLine(_ message: String) {
        let stamp = dateFormatter.string(from: Date())
        let entry = LogEntry(stamp: stamp, text: message)
        if Thread.isMainThread {
            store(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.store(entry) }
        }
    }

    private func store(_ entry: LogEntry) {
        lines.append(entry)
        if lines.count > Self.maxLogLines {
            lines.removeFirst(lines.count - Self.maxLogLines)
        }
    }

    func clearLog() {
        lines.removeAll()
    }

    /// One big string for the “Copy logs” button.
    func logText() -> String {
        lines.map { "\($0.stamp)  \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Step / guide helpers

    private func setStep(_ step: Step, _ state: StepState) {
        setMain { self.stepStates[step] = state }
    }

    private func setGuide(_ guide: Guide?) {
        setMain { self.guide = guide }
    }

    private func resetRun() {
        setMain {
            for s in Step.allCases { self.stepStates[s] = .pending }
            self.installProgress = 0
            self.pairingPIN = nil
            self.guide = nil
            self.deviceSummary = nil
            self.deviceUDID = nil
            self.deviceName = nil
            self.lastError = nil
            self.showInstallFailureAlert = false
            self.finished = false
            self.certConflict = false
        }
    }

    /// Move whichever step is active or waiting into a terminal state.
    private func failActiveStep(to state: StepState) {
        setMain {
            for s in Step.allCases where self.stepStates[s] == .active || self.stepStates[s] == .waiting {
                self.stepStates[s] = state
            }
        }
    }

    // MARK: - One-click pipeline (the default flow)

    /// Run every install step in order, stopping at the first failure.
    @MainActor
    func runOneClick() {
        guard !isRunning else { return }
        // Nothing downstream works on an older iOS.
        guard osSupported else {
            reportPreflightFailure(
                "iOS \(osVersionText)には対応していません。端末内ペアリングにはiOS \(Engine.minimumOSText)以降が必要です。")
            return
        }
        guard !normalizedAppleID.isEmpty, !applePassword.isEmpty else {
            reportPreflightFailure("先にAppleアカウントのメールアドレスとパスワードを入力してください。")
            return
        }
        // A custom install needs its IPA before anything else runs.
        if IPALibrary.customImport() == nil {
            setGuide(Guides.customIPA)
            reportPreflightFailure("IPAが読み込まれていません。IPAを選択してから、もう一度インストールしてください。")
            return
        }
        // The install runs over the loopback tunnel, so require it up front.
        refreshNetworkStatus()
        guard !needsFreshPairing || wifiConnected else {
            setGuide(Guides.wifi)
            reportPreflightFailure("Wi-Fiが無効です。このiPhoneとのペアリングにはWi-Fiが必要です。接続してから、もう一度インストールしてください。")
            return
        }
        guard vpnConnected else {
            setGuide(Guides.vpn)
            reportPreflightFailure("ループバックVPNが接続されていません。VPNを接続してから、もう一度インストールしてください。")
            return
        }
        // A tunnel pointed at this iPhone's own address can never connect.
        if NetworkStatus.isOwnAddress(deviceIP) {
            setGuide(Guides.deviceIPMismatch)
            reportPreflightFailure("デバイスIPの\(deviceIP)は、このiPhone自身が使用しているアドレスです。設定の詳細から接続先IPを確認してください。既定値は10.7.0.1です。")
            return
        }
        resetRun()
        isRunning = true
        log("=== インストール開始 ===")

        pipelineTask = Task { @MainActor in
            do {
                try await ensureNetwork()
                try await pairAndConnect()
                try await signIn()
                try await download()
                try await signApp()
                try await install()
                finishSuccess()
            } catch is CancellationError {
                log("インストールを中止しました。")
                failActiveStep(to: .pending)
                setGuide(nil)
                showInstallFailureAlert = false
            } catch {
                markPairingRejectedIfNeeded(error)
                let msg = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                lastError = msg
                showInstallFailureAlert = true
                log("処理を停止しました：\(msg)")
                failActiveStep(to: .failed)
            }
            isRunning = false
            pairingPIN = nil
        }
    }

    @MainActor
    func retryOneClick() {
        showInstallFailureAlert = false
        lastError = nil
        runOneClick()
    }

    @MainActor
    func dismissInstallFailureAlert() {
        showInstallFailureAlert = false
    }

    @MainActor
    private func reportPreflightFailure(_ message: String) {
        lastError = message
        showInstallFailureAlert = true
        log(message)
    }

    // MARK: - Saved Apple Account

    var hasSavedAccount: Bool {
        !normalizedAppleID.isEmpty && !applePassword.isEmpty
    }

    @MainActor
    func saveAccount(email: String, password: String) throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            throw EngineError.message("メールアドレスとパスワードを入力してください。")
        }
        try CredentialStore.save(email: email, password: password)
        appleID = email
        applePassword = password
    }

    @MainActor
    func forgetAccount() {
        CredentialStore.clear()
        appleID = ""
        applePassword = ""
        if let signSession { si_sign_session_free(signSession) }
        signSession = nil
        signInStatus = "未サインイン"
    }

    /// Stop the pipeline at the next safe point.
    @MainActor
    func cancelOneClick() {
        pipelineTask?.cancel()
        PairingController.shared.softCancel()   // unblock a pending pairing wait
    }

    // MARK: Step 1 — network (waits for the loopback tunnel)

    /// True when this run must pair from scratch, the one step needing Wi-Fi.
    var needsFreshPairing: Bool {
        if let previewPairingReady { return !previewPairingReady }
        return pairingRecordRejected
            || !fileExistsNonEmpty(pairingFilePath ?? PairingController.pairingFilePath())
    }

    @MainActor
    func startSetupPairing() async {
        guard !setupPairingInProgress else { return }
        setupPairingInProgress = true
        setupPairingError = nil
        // Only remove a missing/rejected record. A temporary VPN failure is not
        // evidence that the existing pairing credentials are invalid.
        if needsFreshPairing {
            let stalePath = pairingFilePath ?? PairingController.pairingFilePath()
            try? FileManager.default.removeItem(atPath: stalePath)
            pairingFilePath = nil
        }
        do {
            let path = try await PairingController.shared.startAndWait()
            pairingFilePath = path
            pairingRecordRejected = false
            pairingVerified = true
            pairingStatus = "ペアリング済み"
        } catch is CancellationError {
            setupPairingError = "ペアリングを中止しました。"
        } catch {
            setupPairingError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
        setupPairingInProgress = false
    }

    @MainActor
    private func ensureNetwork() async throws {
        setStep(.network, .active)
        // The blocker last logged, so each one is announced once.
        var announced: String?
        while true {
            try Task.checkCancellation()
            let (vpn, wifi, detail) = NetworkStatus.summarize(deviceIP: deviceIP)
            publishNetwork(vpn: vpn, wifi: wifi,
                           vpnText: vpn ? "トンネル接続済み" : "トンネル未接続")
            // Only a run that pairs needs Wi-Fi; the tunnel is always required.
            let wifiSatisfied = wifi || !needsFreshPairing
            if wifiSatisfied && vpn {
                log("ネットワーク確認完了：\(detail)")
                setStep(.network, .done)
                setGuide(nil)
                return
            }
            setStep(.network, .waiting)
            if !wifiSatisfied {
                // Wi-Fi is the prerequisite for pairing, so surface it first.
                if announced != "wifi" {
                    log("Wi-Fiへの接続を待っています。このiPhoneとのペアリングにはWi-Fiが必要です。")
                    announced = "wifi"
                }
                setGuide(Guides.wifi)
            } else {
                if announced != "vpn" {
                    log("ループバックVPNを待っています。LocalDevVPN、ClashMiなどのVPNを接続してください。")
                    announced = "vpn"
                }
                setGuide(Guides.vpn)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    // MARK: Step 2+3 — pair, then connect

    @MainActor
    private func pairAndConnect() async throws {
        // A probe may have started just before the user tapped Install. Wait for
        // that single probe to publish its result before deciding whether the
        // saved record can be reused; otherwise it can delete the record between
        // this decision and the actual connection attempt.
        if let validation = pairingValidationTask {
            setStep(.pair, .active)
            log("進行中のペアリング確認を待っています。")
            await validation.value
        }

        let path = PairingController.pairingFilePath()
        let reused = fileExistsNonEmpty(path) && !pairingRecordRejected
        if reused {
            log("既存のペアリング情報を確認しています。")
            pairingFilePath = path
            setStep(.pair, .done)
        } else {
            try await pair()
        }

        do {
            try await connect()
        } catch {
            // Re-pair only when the device explicitly rejected its saved trust.
            // Socket/VPN/RSD failures must preserve valid pairing credentials
            // and surface the original connection error to the user.
            guard reused else { throw error }
            guard markPairingRejectedIfNeeded(error) else {
                log("ペアリング情報は保持しています。端末接続に失敗しました：\(short(error))")
                throw error
            }
            log("iPhoneが保存済みのペアリングを拒否しました。再度ペアリングします…")
            try await pair()
            try await connect()
        }
    }

    @MainActor
    private func pair() async throws {
        setStep(.pair, .waiting)
        setGuide(Guides.pairing)
        log("ペアリング：端末内ペアリングサービスを開始しています…")
        let path = try await PairingController.shared.startAndWait()
        pairingFilePath = path
        pairingRecordRejected = false
        pairingVerified = true
        pairingPIN = nil
        setStep(.pair, .done)
        setGuide(nil)
    }

    @MainActor
    private func connect() async throws {
        setStep(.connect, .active)
        setGuide(nil)
        let ip = deviceIP
        let path = pairingFilePath ?? PairingController.pairingFilePath()
        let endpoint = try await resolveRemotePairingEndpoint(force: true)
        let device = try await onDeviceQueue {
            try self.performConnect(ip: ip, port: endpoint.port, pairingPath: path)
        }
        deviceSummary = device.summary
        deviceUDID = device.udid
        deviceName = device.name
        pairingRecordRejected = false
        pairingVerified = true
        pairingStatus = L("connected")
        setStep(.connect, .done)
    }

    /// A connected device's summary line and identifiers.
    private struct ConnectedDevice {
        let summary: String
        let udid: String?
        let name: String?
    }

    private func performConnect(ip: String, port: UInt16,
                                pairingPath path: String) throws -> ConnectedDevice {
        // A missing or empty pairing file surfaces as a confusing Socket(ENOENT).
        let size = fileSize(path)
        guard FileManager.default.fileExists(atPath: path), size > 0 else {
            throw EngineError.message(L("Pairing didn't finish — no pairing file yet."))
        }
        log("ペアリング情報を確認しました（\(size)バイト）。Remote Pairingで\(ip):\(port)へ接続しています…")
        try connection.connect(deviceIP: ip, remotePairingPort: port,
                               pairingFilePath: path)
        log("トンネルとRSDの接続を確立しました。")
        log(try connection.rsdSummary())
        let info = try connection.deviceInfo()
        var dict: [String: String] = [:]
        if info.isEmpty {
            log("端末情報：取得できませんでした。")
        } else {
            log("端末情報：")
            for (key, value) in info {
                dict[key] = value
                log("  \(Self.localizedDeviceInfoKey(key))：\(value)")
            }
        }
        let name = dict["DeviceName"] ?? L("device")
        let summary: String
        if let version = dict["ProductVersion"] {
            summary = "\(name) · iOS \(version)"
        } else {
            summary = name
        }
        return ConnectedDevice(summary: summary,
                               udid: dict["UniqueDeviceID"],
                               name: dict["DeviceName"])
    }

    // MARK: Step 4 — Apple ID sign-in

    /// The Apple ID as sent to Apple; a stray space breaks the SRP proof.
    var normalizedAppleID: String {
        appleID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func signIn() async throws {
        if signSession != nil {
            log("このセッションではサインイン済みです。")
            setStep(.signIn, .done)
            return
        }
        guard !normalizedAppleID.isEmpty, !applePassword.isEmpty else {
            throw EngineError.message(L("Enter your Apple ID email + password."))
        }
        setStep(.signIn, .active)

        let id = normalizedAppleID, pw = applePassword, dir = storageDir
        twoFactorWasCancelled = false
        try Task.checkCancellation()
        signInStatus = "サインイン中…"
        do {
            let summary = try await onSignQueue {
                try self.performSignIn(id: id, pw: pw, ani: self.anisetteURL, dir: dir)
            }
            signInStatus = "サインイン済み（\(summary)）"
            setStep(.signIn, .done)
        } catch let error as EngineError {
            let message = error.errorDescription ?? "サインインに失敗しました"
            signInStatus = "サインイン失敗"
            if twoFactorWasCancelled {
                log("2ファクタ認証がキャンセルされたため、処理を中止します。")
                signInStatus = "未サインイン"
                throw EngineError.message(L("Two-factor verification was cancelled."))
            }
            if Self.isCredentialError(message) {
                log("Appleアカウントの認証情報が拒否されました：\(message)")
                throw EngineError.message(Self.credentialErrorMessage)
            }
            throw EngineError.message("Appleアカウントへのサインインに失敗しました：\(message)")
        }
    }

    /// One sign-in attempt against a specific anisette server.
    private func performSignIn(id: String, pw: String, ani: String, dir: String) throws -> String {
        log("Anisette \(Self.oneLine(ani))を使用してAppleアカウントへサインインしています…")
        var session: OpaquePointer?
        var summary: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let rc = si_apple_signin(id, pw, ani, "LocalStore", dir,
                                 twoFactorCallback, nil,
                                 &session, &summary, &error)
        if rc == 0 {
            if let old = self.signSession { si_sign_session_free(old) }
            self.signSession = session
            let s = japaneseTeamName(summary.map { String(cString: $0) } ?? "")
            summary.map { si_string_free($0) }
            log("サインインしました。\(s)")
            return s
        } else {
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
            error.map { si_string_free($0) }
            throw EngineError.message(japaneseBackendError(
                msg, fallback: "Appleアカウントへのサインインに失敗しました。"))
        }
    }

    /// Squeeze a value onto one line, since the console renders one per entry.
    static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// GrandSlam codes meaning the credentials themselves were rejected.
    private static let credentialErrorCodes = [
        "-20101",   // invalid username/password
        "-22406",   // "Enter the correct password for this Apple Account."
    ]

    /// What the user sees when Apple rejects the credentials.
    static var credentialErrorMessage: String {
        L("Incorrect Apple ID or password. Check your Apple Account email and password, then try again.")
    }

    /// Detect a credential failure, which no anisette server can fix.
    static func isCredentialError(_ raw: String) -> Bool {
        let m = raw.lowercased()
        if credentialErrorCodes.contains(where: m.contains) { return true }
        // Wording fallbacks, covering both "Apple ID" and "Apple Account".
        return m.contains("apple id or password")
            || m.contains("apple account or password")
            || m.contains("password was incorrect")
            || m.contains("incorrect apple id")
            || m.contains("correct password")
            || (m.contains("password") && m.contains("incorrect"))
    }

    private static func localizedDeviceInfoKey(_ key: String) -> String {
        switch key {
        case "DeviceName": return "端末名"
        case "ProductType": return "製品種別"
        case "ProductVersion": return "iOSバージョン"
        case "BuildVersion": return "ビルド番号"
        case "UniqueDeviceID": return "UDID"
        case "HardwareModel": return "ハードウェアモデル"
        case "CPUArchitecture": return "CPUアーキテクチャ"
        case "ModelNumber": return "モデル番号"
        default: return key
        }
    }

    // MARK: Step 5 — prepare the imported IPA

    @MainActor
    private func download() async throws {
        if let path = downloadedIPAPath, FileManager.default.fileExists(atPath: path) {
            log("読み込んだIPAは準備済みです。")
            setStep(.download, .done)
            return
        }
        setStep(.download, .active)
        guard let imported = IPALibrary.customImport() else {
            setGuide(Guides.customIPA)
            throw EngineError.message(L("No IPA imported yet. Tap “Import .ipa” and pick one."))
        }
        guard IPALibrary.looksLikeIPA(imported.url) else {
            throw EngineError.message(
                L("%@ isn't a valid IPA. Replace it and try again.",
                  imported.url.lastPathComponent))
        }
        downloadedIPAPath = imported.url.path
        log("\(imported.url.lastPathComponent)を準備しました。")
        setStep(.download, .done)
    }

    /// Copy a picked IPA in as the custom import, replacing any previous one.
    @MainActor
    func importCustomIPA(from url: URL) async {
        guard !isImportingIPA else { return }
        isImportingIPA = true
        defer { isImportingIPA = false }
        lastError = nil
        log("\(url.lastPathComponent)を読み込んでいます…")
        do {
            let dest = try await Self.copyImport(from: url)
            let metadata = try await Self.readMetadata(at: dest.path)
            resetRun()
            customIPAName = dest.lastPathComponent
            importedApp = metadata
            editedAppName = metadata.name
            editedBundleID = metadata.bundleID
            // A new file invalidates whatever the previous run resolved.
            downloadedIPAPath = nil
            signedAppPath = nil
            signedDisplayName = nil
            setGuide(nil)
            log("\(dest.lastPathComponent)を読み込みました（\(ByteCountFormatter.string(fromByteCount: Int64(fileSize(dest.path)), countStyle: .file))）。")
        } catch IPALibrary.ImportError.notAnIPA {
            // The picker accepts any file, so a wrong pick is caught here. The
            // check runs on a staged copy, leaving any previous import intact.
            refreshCustomIPA()
            lastError = L("%@ isn't an IPA. Pick the .ipa file itself — if it looks right, the download may have saved an error page instead, or stopped partway.",
                          url.lastPathComponent)
            log("読み込み：\(lastError ?? "")")
        } catch {
            // Re-read from disk for what the button should now say.
            refreshCustomIPA()
            lastError = L("Couldn't import %@: %@", url.lastPathComponent, error.localizedDescription)
            log("読み込み：\(lastError ?? "")")
        }
    }

    /// The blocking half of an import, on a background queue.
    private static func copyImport(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { cont.resume(returning: try IPALibrary.replaceCustomImport(with: url)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func readMetadata(at path: String) async throws -> ImportedAppMetadata {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try ImportedAppMetadata.read(from: path)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Re-read the custom import from disk.
    @MainActor
    func refreshCustomIPA() {
        customIPAName = IPALibrary.customImport()?.url.lastPathComponent
        importedApp = nil
    }

    // MARK: Step 6 — sign the IPA

    @MainActor
    private func signApp() async throws {
        guard let session = signSession else { throw EngineError.message(L("Not signed in.")) }
        guard let ipa = downloadedIPAPath else { throw EngineError.message(L("No IPA imported.")) }
        // The signer registers this UDID with the team first, or Apple refuses
        // the provisioning profile with error 8220.
        let udid = deviceUDID ?? ""
        let name = deviceName ?? ""
        let editedName = editedAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedID = editedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationError = importedIdentityError {
            throw EngineError.message(validationError)
        }
        if udid.isEmpty {
            log("端末のUDIDを取得できていません。先に端末接続を行ってください。取得できない場合、署名がエラー8220で失敗することがあります。")
        }
        setStep(.sign, .active)
        log("進捗71%付近：アプリを署名しています。IPAのサイズによっては、この処理に時間がかかります。")
        do {
            let path = try await onSignQueue {
                try self.performSign(session: session, ipa: ipa, udid: udid, deviceName: name,
                                     bundleID: editedID, displayName: editedName)
            }
            signedAppPath = path
            // The first point at which an imported IPA says what it is.
            signedDisplayName = signedAppName()
            setStep(.sign, .done)
        } catch {
            // User-fixable failures get an explanatory card. A certificate that
            // already exists offers revoke-and-retry, never revoked automatically.
            if case EngineError.certExists = error {
                setGuide(Guides.certExists)
                certConflict = true
            }
            if case let EngineError.deviceRegistration(udid, raw) = error {
                setGuide(Guides.deviceRegistration(udid: udid, raw: raw))
            }
            throw error
        }
    }

    private func performSign(session: OpaquePointer, ipa: String, udid: String, deviceName: String,
                             bundleID: String, displayName: String) throws -> String {
        log("\(displayName)（\(bundleID)）として\(ipa)を署名しています…")
        var signed: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let rc = si_sign_ipa(session, ipa, udid, deviceName, bundleID, displayName,
                             &signed, &error)
        if rc == 0 {
            let path = signed.map { String(cString: $0) } ?? ""
            signed.map { si_string_free($0) }
            log("署名済みアプリを作成しました：\(path)")
            return path
        } else {
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
            error.map { si_string_free($0) }
            let localized = japaneseBackendError(msg, fallback: "アプリの署名処理に失敗しました。")
            let detailed = localized == msg ? localized : "\(localized)\n\n詳細：\(msg)"
            log("署名に失敗しました：\(detailed)")
            if Self.isCertExistsError(msg) { throw EngineError.certExists }
            // Carry the UDID so the guide can show it for manual entry.
            if Self.isDeviceRegistrationError(msg) {
                throw EngineError.deviceRegistration(udid: udid, raw: msg)
            }
            throw EngineError.message(L("Signing failed: %@", detailed))
        }
    }

    /// Detect Apple error 7460 in a raw signing error, by code or wording.
    static func isCertExistsError(_ raw: String) -> Bool {
        let m = raw.lowercased()
        return m.contains("7460")
            || m.contains("maximum number of certificates")
            || (m.contains("certificate") && (m.contains("maximum") || m.contains("limit")))
    }

    /// Detect a failed device registration, or the 8220 it leads to.
    static func isDeviceRegistrationError(_ raw: String) -> Bool {
        let m = raw.lowercased()
        return m.contains("device registration failed")
            || m.contains("8220")
            || m.contains("no devices")
            || m.contains("has no devices")
    }

    /// Tell a device-limit rejection from other registration failures.
    static func isDeviceLimitError(_ raw: String) -> Bool {
        let m = raw.lowercased()
        return m.contains("maximum number of devices")
            || (m.contains("device") && (m.contains("maximum") || m.contains("too many")
                || (m.contains("limit") && !m.contains("no devices"))))
    }

    // MARK: Step 7 — install over AFC + installation_proxy

    @MainActor
    private func install() async throws {
        guard let bundle = signedAppPath else { throw EngineError.message(L("No signed bundle to install.")) }
        setStep(.install, .active)
        installProgress = 0
        let ip = deviceIP
        let path = pairingFilePath ?? PairingController.pairingFilePath()
        // remotepairingd may restart while Apple ID authentication/signing is
        // running and advertise a different port. Always resolve it again.
        let endpoint = try await resolveRemotePairingEndpoint(force: true)
        try await onDeviceQueue {
            // iOS tears down the tunnel while it sits idle through sign-in and
            // signing, and `isConnected` can't see that, so rebuild it here.
            self.log("インストール前に端末接続を更新しています…")
            try self.connection.connect(deviceIP: ip, remotePairingPort: endpoint.port,
                                        pairingFilePath: path)
            guard self.connection.isConnected else { throw EngineError.message(L("Device link dropped — reconnect.")) }
            self.log("署名済みアプリを端末へ転送してインストールしています…")
            try self.connection.installSignedApp(bundlePath: bundle)
            self.log("インストール要求が完了しました。")
        }
        installProgress = 1
        setStep(.install, .done)
    }

    // MARK: Success

    @MainActor
    private func finishSuccess() {
        finished = true
        setGuide(Guides.trust(appName: installedAppName))
        recordInstalledApp()
        log("\(installedSourceName)をインストールしました。残りは信頼の設定です。")
    }

    /// Persist the app immediately for the Installed screen. A later device
    /// refresh confirms the record and replaces the icon with SpringBoard's.
    @MainActor
    private func recordInstalledApp() {
        guard let plist = signedAppPlist(),
              let bundleID = plist["CFBundleIdentifier"] as? String
        else { return }
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundleID
        let version = (plist["CFBundleShortVersionString"] as? String) ?? ""
        InstalledAppsStore.shared.recordInstalled(bundleID: bundleID, name: name,
                                                   version: version,
                                                   iconPNG: signedAppIcon(plist: plist)
                                                    ?? importedApp?.iconPNG)
    }

    // MARK: - App removal

    @Published private(set) var uninstallingBundleID: String?
    @Published var uninstallError: String?

    @MainActor
    func uninstall(_ app: InstalledAppRecord) async {
        guard uninstallingBundleID == nil else { return }
        uninstallingBundleID = app.bundleID
        uninstallError = nil
        do {
            try await ensureDeviceConnection()
            try await onDeviceQueue { try self.connection.uninstall(bundleID: app.bundleID) }
            InstalledAppsStore.shared.removeRecord(bundleID: app.bundleID)
            log("\(app.name)（\(app.bundleID)）を削除しました。")
        } catch {
            uninstallError = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            log("アプリの削除に失敗しました：\(uninstallError ?? "")")
        }
        uninstallingBundleID = nil
    }

    private func signedAppIcon(plist: [String: Any]) -> Data? {
        guard let app = signedAppPath else { return nil }
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = plist[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String]
            else { continue }
            names.append(contentsOf: files)
        }
        if let files = plist["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        let directory = URL(fileURLWithPath: app)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                   includingPropertiesForKeys: nil)) ?? []
        let matches = files.filter { url in
            guard url.pathExtension.lowercased() == "png" else { return false }
            let stem = url.deletingPathExtension().lastPathComponent
            return names.contains { name in
                let base = (name as NSString).deletingPathExtension
                return stem == base || stem.hasPrefix(base + "@")
            }
        }
        let preferred = matches.sorted {
            let lhs = $0.lastPathComponent.contains("@3x") ? 3 : ($0.lastPathComponent.contains("@2x") ? 2 : 1)
            let rhs = $1.lastPathComponent.contains("@3x") ? 3 : ($1.lastPathComponent.contains("@2x") ? 2 : 1)
            return lhs > rhs
        }.first
        return preferred.flatMap { try? Data(contentsOf: $0) }
    }

    // MARK: - STEP 1: liveness

    func ping() {
        runInBackground("ping") {
            guard let raw = si_ping() else {
                self.log("通信確認から応答がありませんでした。")
                return
            }
            let msg = String(cString: raw)
            si_string_free(raw)
            self.log("通信確認：\(msg)")
        }
    }

    // MARK: - Advanced section: individual steps
    //
    // Wrappers around the same async core the one-click flow runs, logging
    // their own failures instead of raising a stopped step and guide.

    func checkVPNAndWifi() {
        let (vpn, wifi, detail) = NetworkStatus.summarize(deviceIP: deviceIP)
        publishNetwork(vpn: vpn, wifi: wifi,
                       vpnText: vpn ? "トンネル接続済み" : "トンネル未接続（ループバックVPNを接続してください）")
        validateSavedPairingIfNeeded(vpnAvailable: vpn)
        log("ネットワーク：\(detail)")
        let portText = remotePairingPort.map(String.init) ?? "自動検出"
        log("ループバックVPN：\(vpnStatus)、Wi-Fi：\(wifiStatus)、Remote Pairing接続先：\(deviceIP):\(portText)")
        if !vpn { log("\(deviceIP)のサブネットにトンネルがありません。LocalDevVPNやClashMiなどを接続してください。") }
    }

    /// Poll the interface list so the readouts track the tunnel while the app is
    /// open. Runs in `.common` mode so it keeps firing during scrolling.
    private func startStatusMonitor() {
        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshNetworkStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// One quiet re-scan of the tunnel and Wi-Fi state.
    func refreshNetworkStatus() {
        let (vpn, wifi, _) = NetworkStatus.summarize(deviceIP: deviceIP)
        let vpnJustConnected = vpn && !vpnConnected
        publishNetwork(vpn: vpn, wifi: wifi,
                       vpnText: vpn ? "トンネル接続済み" : "トンネル未接続（ループバックVPNを接続してください）")
        if vpnJustConnected {
            validateSavedPairingIfNeeded(vpnAvailable: true)
        }
    }

    /// Re-check pairing after returning from Settings, where the user may have
    /// paired or removed trust. Removing trust can restart remotepairingd and
    /// change its advertised port, so a foreground check must bypass the cache.
    func refreshPairingStatus() {
        let (vpn, wifi, _) = NetworkStatus.summarize(deviceIP: deviceIP)
        publishNetwork(vpn: vpn, wifi: wifi,
                       vpnText: vpn ? "トンネル接続済み" : "トンネル未接続（ループバックVPNを接続してください）")
        validateSavedPairingIfNeeded(vpnAvailable: vpn, forceServiceRefresh: true)
    }

    /// While the tunnel is available, quietly pair-verify the saved record. A
    /// transport failure leaves the paired state intact; only a definite trust
    /// rejection changes the UI to unpaired and removes the rejected record.
    private func validateSavedPairingIfNeeded(vpnAvailable: Bool,
                                              forceServiceRefresh: Bool = false) {
        guard vpnAvailable, !pairingRecordRejected else {
            initialSetupStateResolved = true
            return
        }

        let path = pairingFilePath ?? PairingController.pairingFilePath()
        guard fileExistsNonEmpty(path) else {
            pairingFilePath = nil
            pairingVerified = false
            pairingStatus = "ペアリングされていません"
            initialSetupStateResolved = true
            return
        }

        pairingFilePath = path

        guard !isRunning,
              !setupPairingInProgress,
              !pairingValidationInProgress
        else { return }

        pairingValidationInProgress = true
        let ip = deviceIP
        let validation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let endpoint = try await self.resolveRemotePairingEndpoint(
                    force: forceServiceRefresh)
                try await self.onDeviceQueue {
                    let probe = DeviceConnection()
                    defer { probe.disconnect() }
                    try probe.connect(deviceIP: ip, remotePairingPort: endpoint.port,
                                      pairingFilePath: path)
                }
                self.pairingRecordRejected = false
                self.pairingVerified = true
                self.pairingStatus = "ペアリング済み"
            } catch {
                _ = self.markPairingRejectedIfNeeded(error)
            }
            self.pairingValidationInProgress = false
            self.pairingValidationTask = nil
            self.initialSetupStateResolved = true
        }
        pairingValidationTask = validation
    }

    /// Transport failures mean only that the VPN or device link disappeared.
    /// Pair-verify rejection (or InvalidHostID) specifically means trust was
    /// revoked, so only those errors invalidate the setup state.
    @discardableResult
    private func markPairingRejectedIfNeeded(_ error: Error) -> Bool {
        guard let ffi = error as? DeviceConnection.FFIError else { return false }
        let message = ffi.message.lowercased()
        let remotePairingRejected = ffi.code == 103 && [3, 5, 6, 7].contains(ffi.subCode)
        let verifyResponseRejected = ffi.code == 13
            && (message.contains("pair-verify")
                || message.contains("verifymanualpairing")
                || message.contains("public key"))
        guard remotePairingRejected || verifyResponseRejected || ffi.code == 18 else {
            return false
        }
        guard !pairingRecordRejected else { return true }
        pairingRecordRejected = true
        pairingVerified = false
        pairingStatus = "ペアリングが解除されました"
        let stalePath = pairingFilePath ?? PairingController.pairingFilePath()
        try? FileManager.default.removeItem(atPath: stalePath)
        pairingFilePath = nil
        deviceSummary = nil
        deviceUDID = nil
        deviceName = nil
        connection.disconnect()
        log("このiPhoneからペアリングの信頼が解除されました。再度ペアリングしてください。")
        return true
    }

    /// Publish only what changed, so the poll doesn't redraw every view.
    private func publishNetwork(vpn: Bool, wifi: Bool, vpnText: String) {
        let wifiText = wifi ? "接続済み" : "未接続"
        if vpnConnected != vpn { vpnConnected = vpn }
        if wifiConnected != wifi { wifiConnected = wifi }
        if vpnStatus != vpnText { vpnStatus = vpnText }
        if wifiStatus != wifiText { wifiStatus = wifiText }
    }

    /// The signed app's home-screen name; an app carries only one of the two.
    private func signedAppName() -> String? {
        guard let plist = signedAppPlist() else { return nil }
        return (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
    }

    private func signedAppPlist() -> [String: Any]? {
        guard let app = signedAppPath else { return nil }
        let plistPath = (app as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    /// Bring up a fresh device link for an explicit device operation such as
    /// uninstall. The local install-history screen never calls this to display.
    @MainActor
    private func ensureDeviceConnection() async throws {
        refreshNetworkStatus()
        // No Wi-Fi check: this all runs over the loopback tunnel.
        guard vpnConnected else {
            throw EngineError.message(L("No loopback VPN is connected. Turn one on, then try again."))
        }
        let path = pairingFilePath ?? PairingController.pairingFilePath()
        guard fileExistsNonEmpty(path) else {
            throw EngineError.message(L("このiPhoneとのペアリングが完了していません。設定からペアリングしてください。"))
        }
        pairingFilePath = path
        let ip = deviceIP
        let endpoint = try await resolveRemotePairingEndpoint(force: true)
        let device: ConnectedDevice
        do {
            device = try await onDeviceQueue {
                try self.performConnect(ip: ip, port: endpoint.port, pairingPath: path)
            }
        } catch {
            markPairingRejectedIfNeeded(error)
            throw error
        }
        deviceSummary = device.summary
        deviceUDID = device.udid
        deviceName = device.name
        pairingRecordRejected = false
        pairingVerified = true
        pairingStatus = L("connected")
    }

    @MainActor
    private func resolveRemotePairingEndpoint(force: Bool) async throws -> RemotePairingEndpoint {
        let endpoint = try await RemotePairingServiceResolver.shared.resolve(force: force)
        remotePairingPort = endpoint.port
        log("このiPhoneのRemote Pairingサービスを検出しました：\(endpoint.serviceName):\(endpoint.port)")
        return endpoint
    }

    // MARK: 2FA bridge

    /// Called from a Rust worker thread; blocks until the UI submits/cancels.
    func provideTwoFactorCode(_ outBuf: UnsafeMutablePointer<CChar>, _ len: Int) -> Int32 {
        setMain {
            self.pendingTwoFactor = true
            self.log("2ファクタ認証が必要です。信頼済み端末に表示された確認コードを入力してください。")
        }
        twoFactorSem.wait()
        let code = twoFactorResult
        twoFactorResult = nil
        setMain { self.pendingTwoFactor = false }
        guard let code, !code.isEmpty, len > 1 else { return 0 }
        let bytes = Array(code.utf8.prefix(len - 1))
        outBuf.withMemoryRebound(to: UInt8.self, capacity: len) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        return 1
    }

    func submitTwoFactor(_ code: String) {
        twoFactorWasCancelled = false
        twoFactorResult = code
        twoFactorSem.signal()
    }

    func cancelTwoFactor() {
        twoFactorWasCancelled = true
        twoFactorResult = nil
        twoFactorSem.signal()
    }

    // MARK: - Storage

    /// isideload's storage, kept out of the file-sharing-visible Documents.
    private var storageDir: String {
        PrivateStore.isideload.path
    }

    // MARK: - Helpers

    private func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
    }

    private func fileExistsNonEmpty(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) && fileSize(path) > 0
    }

    private func short(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Bridge a blocking deviceQueue body to async.
    private func onDeviceQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            deviceQueue.async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Bridge a blocking signQueue body to async.
    private func onSignQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            signQueue.async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func runInBackground(_ label: String, _ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            work()
        }
    }

    /// Run a closure on the main queue (for @Published mutations off-thread).
    func setMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

#if DEBUG
    /// An isolated engine for Xcode Canvas. It performs no Keychain reads,
    /// network monitoring, Rust logging setup, pairing, or device connection.
    @MainActor
    static func preview(
        setupComplete: Bool,
        importedApp: ImportedAppMetadata? = nil,
        stepStates: [Step: StepState]? = nil,
        installProgress: Double = 0,
        error: String? = nil,
        finished: Bool = false
    ) -> Engine {
        let engine = Engine(preview: true)
        engine.previewPairingReady = setupComplete
        engine.pairingVerified = setupComplete
        engine.appleID = setupComplete ? "preview@example.com" : ""
        engine.applePassword = setupComplete ? "preview-only" : ""
        engine.wifiConnected = setupComplete
        engine.vpnConnected = setupComplete
        engine.wifiStatus = setupComplete ? "接続済み" : "未接続"
        engine.vpnStatus = setupComplete ? "トンネル接続済み" : "トンネル未接続"
        engine.pairingStatus = setupComplete ? "ペアリング済み" : "未完了"
        engine.importedApp = importedApp
        engine.editedAppName = importedApp?.name ?? ""
        engine.editedBundleID = importedApp?.bundleID ?? ""
        engine.customIPAName = importedApp.map { "\($0.name).ipa" }
        engine.downloadedIPAPath = importedApp == nil ? nil : "/preview/sample.ipa"
        engine.installProgress = installProgress
        engine.lastError = error
        engine.finished = finished
        engine.signedDisplayName = finished ? importedApp?.name : nil
        if let stepStates {
            engine.stepStates = stepStates
            engine.isRunning = stepStates.values.contains { $0 == .active || $0 == .waiting }
        }
        return engine
    }
#endif
}

// MARK: - Predefined instruction cards

/// Contextual instructions used by the install sheet.
enum Guides {
    /// Shown only for a run that has to pair, the one step needing Wi-Fi.
    static var wifi: Guide {
        Guide(
            title: L("Connect to Wi-Fi"),
            systemImage: "wifi",
            steps: [
                L("Open Settings › Wi-Fi and join a network."),
                L("Pairing this iPhone needs it: LocalStore advertises itself on the local network for Settings to find."),
                L("Then come back here — this continues automatically."),
            ],
            actionLabel: nil, actionURLString: nil)
    }

    /// Shown when no tunnel is up. Any VPN app on the device subnet works.
    static var vpn: Guide {
        Guide(
            title: L("Turn on a loopback VPN"),
            systemImage: "network",
            steps: [
                L("Open a VPN app that tunnels to this iPhone — LocalDevVPN, ClashMi, or another. Any of them works."),
                L("Tap Connect so the toggle turns on."),
                L("Keep Wi-Fi on, then come back here — this continues automatically."),
            ],
            actionLabel: L("Get LocalDevVPN"),
            actionURLString: "https://apps.apple.com/app/id6755608044")
    }

    /// Shown when Device IP holds an address this iPhone already has, usually
    /// the tunnel's own end copied off the VPN app's status line.
    static var deviceIPMismatch: Guide {
        Guide(
            title: L("Wrong device IP"),
            systemImage: "arrow.triangle.branch",
            steps: [
                L("The address in Settings › Advanced › Device IP is one this iPhone already holds, so there's nothing at the other end to connect to."),
                L("Set it back to 10.7.0.1, the default. In LocalDevVPN that's the value under Settings › Device IP — not the address on its main screen, which is the tunnel's own end."),
                L("If you changed LocalDevVPN's addresses, put its Device IP here, and make sure its Tunnel IP and subnet mask cover it."),
            ],
            actionLabel: nil, actionURLString: nil)
    }

    /// Shown when Custom .ipa is selected but nothing has been imported yet.
    static var customIPA: Guide {
        Guide(
            title: L("Import an .ipa first"),
            systemImage: "square.and.arrow.down.on.square",
            steps: [
                L("Tap “Import .ipa” above and pick the file — it can live anywhere the Files app can reach, including iCloud Drive or a USB drive."),
            ],
            actionLabel: nil, actionURLString: nil)
    }

    static var pairing: Guide {
        Guide(
            title: L("Pair this iPhone in Settings"),
            systemImage: "lock.iphone",
            steps: [
                L("Open the Settings app, then go to Privacy & Security › Developer Mode."),
                L("Tap “Pair with LocalStore”."),
                L("Enter your iPhone’s passcode if it asks for it."),
                L("Come back to LocalStore, read the code it shows you, then type that same code into the prompt in Settings."),
            ],
            actionLabel: nil, actionURLString: nil)
    }

    /// Shown when Apple refuses a certificate because one exists (error 7460).
    static var certExists: Guide {
        Guide(
            title: L("A signing certificate already exists"),
            systemImage: "exclamationmark.shield",
            steps: [
                L("Apple returned error 7460: this Apple ID already has an iOS development certificate, or a request for one is still pending."),
                L("LocalStore couldn't reuse it. That happens when the certificate was issued somewhere else — AltStore, SideStore, Sideloadly or Xcode on another device — so the private key it needs isn't on this iPhone."),
                L("Use “Revoke and retry” in the install screen to choose the certificate explicitly."),
                L("Revoking is permanent: every app already signed with that certificate stops launching, on every device."),
                L("Alternatively, save a different Apple Account in Settings, then try the install again."),
            ],
            actionLabel: nil, actionURLString: nil)
    }

    /// Shown when the UDID couldn't be registered with the developer team, with
    /// separate advice for a device-limit rejection.
    static func deviceRegistration(udid: String, raw: String) -> Guide {
        var steps: [String] = []
        if Engine.isDeviceLimitError(raw) {
            steps.append(L("Your Apple ID has hit its limit of registered devices. Free accounts can only register a handful of devices per year and can't remove old ones until the year resets."))
            steps.append(L("Easiest fix: save a different Apple Account in Settings, then try the install again."))
        } else {
            steps.append(L("LocalStore couldn't add this iPhone to your Apple ID's developer team automatically. Tapping Install again often works — Apple's developer service is sometimes briefly unavailable."))
        }
        if !udid.isEmpty {
            steps.append(L("If it keeps failing, add the device by hand. Its UDID is:"))
            steps.append(udid)
            steps.append(L("Paste that into the “Register a Device” form in the Apple Developer portal (this requires a paid Apple Developer account), then tap Install again."))
        }
        return Guide(
            title: L("Couldn't register this device"),
            systemImage: "iphone.badge.exclamationmark",
            steps: steps,
            actionLabel: udid.isEmpty ? nil : L("Open device list"),
            actionURLString: udid.isEmpty ? nil : "https://developer.apple.com/account/resources/devices/list")
    }

    static func trust(appName: String) -> Guide {
        Guide(
            title: L("Last step: trust %@", appName),
            systemImage: "checkmark.seal",
            steps: [
                L("Open Settings › General › VPN & Device Management."),
                L("Tap your Apple ID under “Developer App”, then tap Trust."),
                L("Open %@ from your Home Screen — you're done.", appName),
            ],
            actionLabel: nil, actionURLString: nil)
    }

}

// MARK: - C logging callback

/// Forwards Rust log lines to the engine on the main queue.
private let siLogCallback: SILogCallback = { _, msg in
    guard let msg = msg else { return }
    let text = String(cString: msg)
    DispatchQueue.main.async {
        Engine.shared.appendRustLine(text)
    }
}

/// Bridges isideload's 2FA request to the engine's blocking prompt.
private let twoFactorCallback: SITwoFactorCb = { _, outBuf, bufLen in
    guard let outBuf = outBuf else { return 0 }
    return Engine.shared.provideTwoFactorCode(outBuf, Int(bufLen))
}
