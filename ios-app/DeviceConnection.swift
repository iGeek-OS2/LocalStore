import Foundation
import OnDeviceCore
import Darwin

/// Wraps idevice's C-FFI to reach the device over the loopback tunnel and talk
/// lockdown and installation_proxy across it, following StikDebug's path. The
/// adapter and handshake are created once and reused; every call blocks, so
/// none of this may run on the main thread.
final class DeviceConnection {

    // idevice opaque handles import as OpaquePointer.
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?

    var isConnected: Bool { adapter != nil && handshake != nil }

    struct FFIError: Error, CustomStringConvertible, LocalizedError {
        let code: Int32
        let subCode: Int32
        let message: String
        var description: String { "idevice FFI error code=\(code) sub=\(subCode): \(message)" }
        var isConnectionRefused: Bool {
            code == 16 && message.localizedCaseInsensitiveContains("connection refused")
        }
        var errorDescription: String? {
            if isConnectionRefused {
                return "このiPhoneのRemote Pairingサービスへ接続できませんでした（code=16：\(message)）。"
            }
            return description
        }
    }

    /// Turn a returned IdeviceFfiError* into a thrown error (null == success).
    private func check(_ err: UnsafeMutablePointer<IdeviceFfiError>?, _ fallback: String) throws {
        guard let err = err else { return }
        let code = err.pointee.code
        let sub = err.pointee.sub_code
        let msg = err.pointee.message.flatMap { String(validatingUTF8: $0) } ?? fallback
        idevice_error_free(err)
        throw FFIError(code: code, subCode: sub, message: msg.isEmpty ? fallback : msg)
    }

    private func fail(_ message: String) -> FFIError {
        FFIError(code: -1, subCode: 0, message: message)
    }

    // MARK: Connect / disconnect

    /// Establish the loopback tunnel and RSD handshake.
    func connect(deviceIP: String, remotePairingPort: UInt16,
                 pairingFilePath: String, hostname: String = "LocalStore") throws {
        var pf: OpaquePointer?
        try pairingFilePath.withCString { p in
            try check(rp_pairing_file_read(p, &pf), "failed to read pairing file at \(pairingFilePath)")
        }
        guard let pairingFile = pf else { throw fail("ペアリング情報を開けませんでした") }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = remotePairingPort.bigEndian
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw fail("invalid device IP: \(deviceIP)")
        }

        // remotepairingd can begin listening slightly after the packet tunnel
        // becomes visible. Retry only ECONNREFUSED; trust/protocol errors must
        // be returned immediately so the caller can classify them correctly.
        for attempt in 0..<4 {
            var newAdapter: OpaquePointer?
            var newHandshake: OpaquePointer?
            let err = withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    hostname.withCString { host in
                        // A nil pin_callback pair-verifies with the existing file.
                        tunnel_create_rppairing(
                            sa, socklen_t(MemoryLayout<sockaddr_in>.stride),
                            host, pairingFile, nil, nil,
                            &newAdapter, &newHandshake)
                    }
                }
            }

            do {
                try check(err, "tunnel_create_rppairing failed (device \(deviceIP):\(remotePairingPort))")
                guard newAdapter != nil, newHandshake != nil else {
                    throw fail("有効な端末トンネルを作成できませんでした")
                }
                disconnect()
                adapter = newAdapter
                handshake = newHandshake
                return
            } catch {
                if let newHandshake { rsd_handshake_free(newHandshake) }
                if let newAdapter { adapter_free(newAdapter) }
                guard let ffi = error as? FFIError,
                      ffi.isConnectionRefused,
                      attempt < 3 else { throw error }
                Thread.sleep(forTimeInterval: [0.25, 0.5, 1.0][attempt])
            }
        }
    }

    func disconnect() {
        if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
        if let adapter { adapter_free(adapter); self.adapter = nil }
    }

    // MARK: RSD handshake summary

    /// Basic info straight off the RSD handshake (no extra service connection).
    func rsdSummary() throws -> String {
        guard let handshake else { throw fail("端末に接続されていません") }
        var uuid: UnsafeMutablePointer<CChar>?
        try check(rsd_get_uuid(handshake, &uuid), "端末識別情報の取得に失敗しました")
        let uuidStr = uuid.flatMap { String(validatingUTF8: $0) } ?? "?"
        if let uuid { idevice_string_free(uuid) }

        var proto: UInt = 0
        try check(rsd_get_protocol_version(handshake, &proto), "通信プロトコル情報の取得に失敗しました")
        return "RSD識別子：\(uuidStr)、プロトコル：\(proto)"
    }

    // MARK: Device info (lockdown over RSD)

    /// ProductVersion / ProductType / UDID etc. via lockdownd over the tunnel.
    func deviceInfo() throws -> [(String, String)] {
        guard let adapter, let handshake else { throw fail("端末に接続されていません") }
        var client: OpaquePointer?
        try check(lockdownd_connect_rsd(adapter, handshake, &client), "端末情報サービスへの接続に失敗しました")
        guard let client else { throw fail("端末情報サービスを開始できませんでした") }
        defer { lockdownd_client_free(client) }

        var plistObj: plist_t?
        try check(lockdownd_get_value(client, nil, nil, &plistObj), "端末情報の読み込みに失敗しました")
        guard let plistObj else { return [] }
        defer { plist_free(plistObj) }

        let keys = [
            "DeviceName", "ProductType", "ProductVersion", "BuildVersion",
            "UniqueDeviceID", "HardwareModel", "CPUArchitecture", "ModelNumber",
        ]
        return keys.compactMap { key in
            plistString(plistObj, key).map { (key, $0) }
        }
    }

    // MARK: Install (AFC upload to /PublicStaging + installation_proxy)

    /// Upload a signed `.app` bundle to /PublicStaging and install it over RSD.
    func installSignedApp(bundlePath: String) throws {
        guard let adapter, let handshake else { throw fail("端末に接続されていません") }

        var afc: OpaquePointer?
        try check(afc_client_connect_rsd(adapter, handshake, &afc), "ファイル転送サービスへの接続に失敗しました")
        guard let afc else { throw fail("ファイル転送サービスを開始できませんでした") }
        defer { afc_client_free(afc) }

        let name = (bundlePath as NSString).lastPathComponent
        let remoteRoot = "/PublicStaging/\(name)"
        try uploadDirectory(afc, localDir: bundlePath, remoteDir: remoteRoot)

        var ip: OpaquePointer?
        try check(installation_proxy_connect_rsd(adapter, handshake, &ip),
                  "インストールサービスへの接続に失敗しました")
        guard let ip else { throw fail("インストールサービスを開始できませんでした") }
        defer { installation_proxy_client_free(ip) }

        guard let options = developerInstallOptions() else {
            throw fail("インストール設定を作成できませんでした")
        }
        defer { plist_free(options) }

        try remoteRoot.withCString { p in
            try check(installation_proxy_install_with_callback(ip, p, options, installProgressCb, nil),
                      "アプリのインストールに失敗しました")
        }
    }

    /// Remove one app by Bundle ID. The caller decides which installs are
    /// eligible; the device service itself has no concept of our local history.
    func uninstall(bundleID: String) throws {
        guard let adapter, let handshake else { throw fail("端末に接続されていません") }
        var client: OpaquePointer?
        try check(installation_proxy_connect_rsd(adapter, handshake, &client),
                  "インストールサービスへの接続に失敗しました")
        guard let client else { throw fail("インストールサービスを開始できませんでした") }
        defer { installation_proxy_client_free(client) }
        try check(bundleID.withCString { installation_proxy_uninstall(client, $0, nil) },
                  "アプリの削除に失敗しました")
    }

    /// installation_proxy options for a developer-signed bundle. Without
    /// `PackageType: Developer`, installd never reads the embedded profile and
    /// rejects the upload with 0xe8008015 at VerifyingApplication.
    private func developerInstallOptions() -> plist_t? {
        guard let options: plist_t = plist_new_dict() else { return nil }
        // The dict takes ownership of the value node, so freeing it is enough.
        plist_dict_set_item(options, "PackageType", plist_new_string("Developer"))
        return options
    }

    /// Recursively upload a local directory tree to AFC.
    private func uploadDirectory(_ afc: OpaquePointer, localDir: String, remoteDir: String) throws {
        _ = remoteDir.withCString { afc_make_directory(afc, $0) }  // ok if exists
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: localDir)
        for entry in entries {
            let localPath = (localDir as NSString).appendingPathComponent(entry)
            let remotePath = "\(remoteDir)/\(entry)"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: localPath, isDirectory: &isDir)
            if isDir.boolValue {
                try uploadDirectory(afc, localDir: localPath, remoteDir: remotePath)
            } else {
                try uploadFile(afc, localPath: localPath, remotePath: remotePath)
            }
        }
    }

    private func uploadFile(_ afc: OpaquePointer, localPath: String, remotePath: String) throws {
        // Mapped, not read: a tens-of-megabytes binary on the heap risks a jetsam.
        let data = try Data(contentsOf: URL(fileURLWithPath: localPath), options: .mappedIfSafe)
        var file: OpaquePointer?
        try check(remotePath.withCString { afc_file_open(afc, $0, AfcWrOnly, &file) },
                  "afc_file_open \(remotePath) failed")
        guard let file else { throw fail("転送先ファイルを開けませんでした") }
        defer { afc_file_close(file) }

        // Write in chunks so large files don't balloon memory in one FFI call.
        let chunk = 1 << 20
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = min(chunk, data.count - offset)
                try check(afc_file_write(file, base + offset, n), "ファイルの転送に失敗しました")
                offset += n
            }
        }
    }


    // MARK: plist helpers

    private func plistString(_ dict: plist_t?, _ key: String) -> String? {
        guard let item = key.withCString({ plist_dict_get_item(dict, $0) }) else { return nil }
        var out: UnsafeMutablePointer<CChar>?
        plist_get_string_val(item, &out)
        guard let out else { return nil }
        defer { plist_mem_free(out) }
        let s = String(validatingUTF8: out) ?? ""
        return s.isEmpty ? nil : s
    }
}

/// installation_proxy progress callback, driving the bar and the log.
private let installProgressCb: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { progress, _ in
    DispatchQueue.main.async {
        // installd repeats a percentage across phases; only act when it moves.
        let fraction = Double(progress) / 100.0
        guard Engine.shared.installProgress != fraction else { return }
        Engine.shared.installProgress = fraction
        Engine.shared.log("インストール進捗：\(progress)%")
    }
}
