import Foundation
import OnDeviceCore

/// One iOS development certificate, decoded from `si_cert_list`'s JSON, where
/// Apple's optionals arrive flattened to "".
struct DevCert: Identifiable, Codable, Equatable {
    let name: String
    let serialNumber: String
    let machineName: String
    let machineId: String
    let certificateId: String
    let platform: String
    let status: String
    /// RFC3339 expiry (e.g. `2027-01-01T00:00:00Z`), or "" if Apple omitted it.
    let expiration: String

    enum CodingKeys: String, CodingKey {
        case name
        case serialNumber = "serial_number"
        case machineName = "machine_name"
        case machineId = "machine_id"
        case certificateId = "certificate_id"
        case platform
        case status
        case expiration
    }

    /// Stable identity: the serial revocation keys on, or the certificate id.
    var id: String { serialNumber.isEmpty ? certificateId : serialNumber }

    var displayName: String {
        guard !name.isEmpty else { return L("Unnamed certificate") }
        return name.replacingOccurrences(of: "Apple Development", with: "Apple開発用証明書")
    }

    var localizedStatus: String {
        switch status.lowercased() {
        case "active", "valid": return "有効"
        case "revoked": return "失効済み"
        case "expired": return "期限切れ"
        case "pending": return "処理中"
        default: return status
        }
    }

    /// The machine Apple tagged the certificate with, if any.
    var machineLabel: String? {
        machineName.isEmpty ? nil : machineName
    }

    /// `expiration` parsed to a `Date`, if present and well-formed.
    var expiresAt: Date? {
        guard !expiration.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: expiration)
            ?? ISO8601DateFormatter().date(from: expiration)
    }

    /// True once the expiry date is in the past.
    var isExpired: Bool {
        guard let date = expiresAt else { return false }
        return date < Date()
    }
}

/// Lists and revokes the Apple ID's development certificates, reusing the
/// engine's credentials and 2FA prompt. Purely a developer-portal API call, so
/// no device or tunnel is involved, and the blocking FFI runs off the main queue.
final class CertManager: ObservableObject {

    @Published private(set) var certs: [DevCert] = []
    @Published private(set) var isSignedIn = false
    @Published private(set) var teamSummary: String?
    /// Sign-in or list in progress.
    @Published private(set) var isWorking = false
    /// `id` of the certificate currently being revoked, if any.
    @Published private(set) var revokingID: String?
    @Published var lastError: String?
    /// True once a list has been fetched, so the empty state can tell them apart.
    @Published private(set) var hasLoaded = false
    @Published private(set) var verifiedAppleID: String?

    /// The ten-character identifier is used only to recognize other apps
    /// signed by this same free Personal Team in LaunchServices.
    var personalTeamID: String? {
        guard let summary = teamSummary,
              summary.localizedCaseInsensitiveContains("Personal Team")
                || summary.contains("個人チーム"),
              let match = summary.firstMatch(of: /\(([A-Z0-9]{10})\)\s*$/)
        else { return nil }
        return String(match.1)
    }

    private var session: OpaquePointer?            // CertSession*
    private let queue = DispatchQueue(label: "ondevicesigner.certs")

    private var engine: Engine { Engine.shared }

    init(restoreSavedSnapshot: Bool = true) {
        if restoreSavedSnapshot { restoreSnapshot() }
    }

    func isVerified(email: String) -> Bool {
        guard hasLoaded, let verifiedAppleID else { return false }
        return verifiedAppleID.caseInsensitiveCompare(
            email.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    deinit {
        if let session { si_cert_session_free(session) }
    }

    // MARK: - Public actions

    /// Sign in if needed and reload the list; `then` runs only if it arrived.
    @MainActor
    func loadCerts(then: (() -> Void)? = nil) {
        guard !isWorking, revokingID == nil else { return }
        let id = engine.normalizedAppleID, pw = engine.applePassword
        guard !id.isEmpty, !pw.isEmpty else {
            lastError = L("Enter your Apple ID email and password first.")
            return
        }
        isWorking = true
        lastError = nil
        engine.log("=== 証明書を読み込み中 ===")
        Task { @MainActor in
            do {
                if session == nil { try await signIn(id: id, pw: pw) }
                let list = try await onQueue { try self.performList() }
                certs = list
                hasLoaded = true
                verifiedAppleID = id
                saveSnapshot()
                engine.log("iOS開発用証明書を\(list.count)件取得しました。")
                isWorking = false
                then?()
                return
            } catch is CancellationError {
                // not cancellable today, but keep parity with Engine
            } catch {
                lastError = short(error)
                engine.log("証明書：\(lastError ?? "取得に失敗しました")")
            }
            isWorking = false
        }
    }

    /// Revoke one certificate and refresh the list. `onSuccess` — which resumes
    /// a stopped install — runs only once Apple has accepted the revocation.
    @MainActor
    func revoke(_ cert: DevCert, onSuccess: (() -> Void)? = nil) {
        guard session != nil, revokingID == nil, !isWorking else { return }
        let serial = cert.serialNumber
        guard !serial.isEmpty else {
            lastError = L("This certificate has no serial number, so it can't be revoked.")
            return
        }
        revokingID = cert.id
        lastError = nil
        engine.log("証明書：\(cert.displayName)（\(serial)）を失効しています…")
        Task { @MainActor in
            var revoked = false
            do {
                try await onQueue { try self.performRevoke(serial: serial) }
                revoked = true
                engine.log("証明書：\(cert.displayName)を失効しました。")
                let list = try await onQueue { try self.performList() }
                certs = list
                saveSnapshot()
            } catch {
                lastError = short(error)
                engine.log("証明書の失効に失敗しました：\(lastError ?? "")")
            }
            revokingID = nil
            // The refresh can fail on its own; the revoke is what's awaited.
            if revoked { onSuccess?() }
        }
    }

    /// Load the list if that hasn't happened yet, then run `then` — for the
    /// Install screen, which must name a certificate before revoking it.
    @MainActor
    func ensureLoaded(then: @escaping () -> Void) {
        guard !isWorking, revokingID == nil else { return }
        if hasLoaded, session != nil {
            then()
            return
        }
        loadCerts(then: then)
    }

    /// Forget the session and clear the list, to switch Apple ID.
    @MainActor
    func signOut() {
        if let session { si_cert_session_free(session) }
        session = nil
        isSignedIn = false
        teamSummary = nil
        certs = []
        hasLoaded = false
        verifiedAppleID = nil
        lastError = nil
        clearSnapshot()
        engine.log("証明書：サインアウトしました。")
    }

    private struct Snapshot: Codable {
        let appleID: String
        let teamSummary: String?
        let certs: [DevCert]
    }

    private func saveSnapshot() {
        guard let verifiedAppleID,
              let data = try? JSONEncoder().encode(
                Snapshot(appleID: verifiedAppleID,
                         teamSummary: teamSummary,
                         certs: certs)) else { return }
        UserDefaults.standard.set(data, forKey: Self.snapshotKey)
    }

    private func restoreSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        verifiedAppleID = snapshot.appleID
        teamSummary = snapshot.teamSummary
        certs = snapshot.certs
        hasLoaded = true
    }

    private func clearSnapshot() {
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
    }

    private static let snapshotKey = "verified-apple-account-certificate-snapshot"

#if DEBUG
    @MainActor
    static func preview(verified: Bool) -> CertManager {
        let manager = CertManager(restoreSavedSnapshot: false)
        guard verified else { return manager }
        manager.verifiedAppleID = "preview@example.com"
        manager.teamSummary = "プレビュー用個人チーム"
        manager.hasLoaded = true
        manager.isSignedIn = true
        manager.certs = [
            DevCert(name: "Apple開発用証明書：プレビュー",
                    serialNumber: "PREVIEW123456",
                    machineName: "LocalStore",
                    machineId: "preview-machine",
                    certificateId: "preview-certificate",
                    platform: "ios",
                    status: "有効",
                    expiration: "2027-08-13T00:00:00Z")
        ]
        return manager
    }
#endif

    // MARK: - Sign-in

    @MainActor
    private func signIn(id: String, pw: String) async throws {
        let dir = storageDir
        engine.twoFactorWasCancelled = false
        do {
            let summary = try await onQueue {
                try self.performSignIn(id: id, pw: pw, ani: self.engine.anisetteURL, dir: dir)
            }
            teamSummary = summary
            isSignedIn = true
            engine.log("証明書：サインインしました（\(summary)）。")
        } catch let error as EngineError {
            let message = error.errorDescription ?? "サインインに失敗しました"
            if engine.twoFactorWasCancelled {
                engine.log("2ファクタ認証がキャンセルされたため、処理を中止します。")
                throw EngineError.message(L("Two-factor verification was cancelled."))
            }
            if Engine.isCredentialError(message) {
                engine.log("Appleアカウントの認証情報が拒否されました：\(message)")
                throw EngineError.message(Engine.credentialErrorMessage)
            }
            throw EngineError.message("Appleアカウントへのサインインに失敗しました：\(message)")
        }
    }

    /// One sign-in attempt against a specific anisette server.
    private func performSignIn(id: String, pw: String, ani: String, dir: String) throws -> String {
        var newSession: OpaquePointer?
        var summary: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let rc = si_cert_signin(id, pw, ani, "LocalStore", dir,
                                certTwoFactorCallback, nil,
                                &newSession, &summary, &error)
        if rc == 0 {
            if let old = self.session { si_cert_session_free(old) }
            self.session = newSession
            let s = japaneseTeamName(summary.map { String(cString: $0) } ?? "")
            summary.map { si_string_free($0) }
            return s
        } else {
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
            error.map { si_string_free($0) }
            throw EngineError.message(japaneseBackendError(
                msg, fallback: "Appleアカウントへのサインインに失敗しました。"))
        }
    }

    // MARK: - List / revoke FFI

    private func performList() throws -> [DevCert] {
        guard let session = self.session else { throw EngineError.message("サインインしていません。") }
        var json: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let rc = si_cert_list(session, &json, &error)
        if rc == 0 {
            let s = json.map { String(cString: $0) } ?? "[]"
            json.map { si_string_free($0) }
            do {
                return try JSONDecoder().decode([DevCert].self, from: Data(s.utf8))
            } catch {
                throw EngineError.message("証明書一覧を読み取れませんでした：\(error)")
            }
        } else {
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
            error.map { si_string_free($0) }
            throw EngineError.message(japaneseBackendError(
                msg, fallback: "証明書一覧の取得に失敗しました。"))
        }
    }

    private func performRevoke(serial: String) throws {
        guard let session = self.session else { throw EngineError.message("サインインしていません。") }
        var error: UnsafeMutablePointer<CChar>?
        let rc = si_cert_revoke(session, serial, &error)
        if rc != 0 {
            let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
            error.map { si_string_free($0) }
            throw EngineError.message(japaneseBackendError(
                msg, fallback: "証明書の失効に失敗しました。"))
        }
    }

    // MARK: - Helpers

    /// The install flow's storage, so provisioning isn't re-bootstrapped.
    private var storageDir: String {
        PrivateStore.isideload.path
    }

    private func short(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Bridge a blocking FFI body on the cert queue to async.
    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}

// MARK: - C 2FA callback

/// Bridges a 2FA request during cert sign-in to the engine's shared prompt.
private let certTwoFactorCallback: SITwoFactorCb = { _, outBuf, bufLen in
    guard let outBuf = outBuf else { return 0 }
    return Engine.shared.provideTwoFactorCode(outBuf, Int(bufLen))
}
