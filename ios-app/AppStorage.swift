import Foundation
import Security
import UIKit
import OnDeviceCore
import ObjectiveC.runtime

/// The single user-selected IPA retained between launches.
enum IPALibrary {
    struct Entry {
        let url: URL
        let size: Int
        let modified: Date?
    }

    static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var customDir: URL {
        // Preserve the existing on-device import across this product cleanup.
        documentsDir.appendingPathComponent("Custom", isDirectory: true)
    }

    static func customImport() -> Entry? {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: customDir.path)) ?? []
        return names.compactMap { name -> Entry? in
            guard name.lowercased().hasSuffix(".ipa") else { return nil }
            let url = customDir.appendingPathComponent(name)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return nil }
            return Entry(url: url,
                         size: (attributes[.size] as? Int) ?? 0,
                         modified: attributes[.modificationDate] as? Date)
        }
        .max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
    }

    enum ImportError: Error {
        case notAnIPA
    }

    /// Stage and validate a new file before replacing the previous import.
    static func replaceCustomImport(with source: URL) throws -> URL {
        let manager = FileManager.default
        let name = source.deletingPathExtension().lastPathComponent
        let staging = manager.temporaryDirectory
            .appendingPathComponent("ipa-import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(name).appendingPathExtension("ipa")
        try? manager.startDownloadingUbiquitousItem(at: source)
        var copyError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [],
                                       error: &coordinationError) { readableURL in
            do { try manager.copyItem(at: readableURL, to: staged) }
            catch { copyError = error }
        }
        if let copyError { throw copyError }
        if let coordinationError { throw coordinationError }
        guard looksLikeIPA(staged) else { throw ImportError.notAnIPA }

        try? manager.removeItem(at: customDir)
        try manager.createDirectory(at: customDir, withIntermediateDirectories: true)
        let destination = customDir.appendingPathComponent(name).appendingPathExtension("ipa")
        try manager.moveItem(at: staged, to: destination)
        return destination
    }

    /// Validate both the ZIP header and end-of-central-directory record.
    static func looksLikeIPA(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 2)) == Data([0x50, 0x4B]) else { return false }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size >= 22 else { return false }
        let tailLength = min(size, 65_557)
        guard (try? handle.seek(toOffset: UInt64(size - tailLength))) != nil,
              let tail = try? handle.readToEnd() else { return false }
        return tail.range(of: Data([0x50, 0x4B, 0x05, 0x06])) != nil
    }
}

struct ImportedAppMetadata: Codable, Equatable {
    let name: String
    let bundleID: String
    let version: String
    let build: String?
    let minimumOS: String?
    let fileSizeBytes: Int64?
    let iconBase64: String?

    enum CodingKeys: String, CodingKey {
        case name, version, build
        case bundleID = "bundle_id"
        case minimumOS = "minimum_os"
        case fileSizeBytes = "file_size_bytes"
        case iconBase64 = "icon_base64"
    }

    var iconPNG: Data? { iconBase64.flatMap { Data(base64Encoded: $0) } }
    var icon: UIImage? { iconPNG.flatMap(UIImage.init(data:)) }

    static func read(from path: String) throws -> Self {
        var json: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let result = path.withCString { si_ipa_metadata($0, &json, &error) }
        defer {
            if let json { si_string_free(json) }
            if let error { si_string_free(error) }
        }
        guard result == 0, let json else {
            let message = error.map { String(cString: $0) } ?? "IPA情報を取得できません。"
            throw EngineError.message(message)
        }
        return try JSONDecoder().decode(Self.self, from: Data(String(cString: json).utf8))
    }
}

enum CredentialStore {
    struct Credentials {
        let email: String
        let password: String
    }

    private static let service = "dev.ondevicesigner.app.apple-account"
    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service]
    }

    static func load() -> Credentials? {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let email = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return .init(email: email, password: password)
    }

    static func save(email: String, password: String) throws {
        let values: [String: Any] = [
            kSecAttrAccount as String: email,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let update = SecItemUpdate(baseQuery as CFDictionary, values as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw StoreError.status(update) }
        var item = baseQuery
        values.forEach { item[$0.key] = $0.value }
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw StoreError.status(add) }
    }

    static func clear() { SecItemDelete(baseQuery as CFDictionary) }

    enum StoreError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            guard case let .status(status) = self else { return nil }
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "キーチェーンエラー（\(status)）"
        }
    }
}

struct InstalledAppRecord: Codable, Identifiable, Equatable {
    private static let personalSigningLifetime: TimeInterval = 7 * 24 * 60 * 60

    var id: String { bundleID }
    let bundleID: String
    var name: String
    var version: String
    var iconPNG: Data?
    var lastSeen: Date
    /// Exact expiry from embedded.mobileprovision when LaunchServices lets us
    /// read it. Legacy records fall back to lastSeen + seven days.
    var signingExpiresAt: Date? = nil
    var icon: UIImage? { iconPNG.flatMap(UIImage.init(data:)) }

    func remainingSigningDays(at date: Date) -> Int {
        let expiration = signingExpiresAt
            ?? lastSeen.addingTimeInterval(Self.personalSigningLifetime)
        let remaining = expiration.timeIntervalSince(date)
        guard remaining > 0 else { return 0 }
        return Int(ceil(remaining / (24 * 60 * 60)))
    }
}

private struct ProvisioningProfileInfo {
    let createdAt: Date?
    let expiresAt: Date?
    let teamIDs: Set<String>
    let isPersonal: Bool
}

private enum ProvisioningProfileReader {
    static func read(at appURL: URL) -> ProvisioningProfileInfo? {
        let url = appURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return read(data)
    }

    static func read(_ data: Data) -> ProvisioningProfileInfo? {
        guard let xmlStart = data.range(of: Data("<?xml".utf8))?.lowerBound,
              let xmlEnd = data.range(of: Data("</plist>".utf8),
                                      options: [], in: xmlStart..<data.endIndex)?.upperBound,
              let profile = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: xmlStart..<xmlEnd), options: [], format: nil
              ) as? [String: Any]
        else { return nil }

        let created = profile["CreationDate"] as? Date
        let expires = profile["ExpirationDate"] as? Date
        let entitlementValues = profile["Entitlements"] as? [String: Any]
        var teamIDs = Set((profile["TeamIdentifier"] as? [String]) ?? [])
        if let appIdentifier = entitlementValues?["application-identifier"] as? String,
           let prefix = appIdentifier.split(separator: ".").first {
            teamIDs.insert(String(prefix))
        }

        let lifetimeDays: Double? = {
            if let ttl = profile["TimeToLive"] as? NSNumber {
                return ttl.doubleValue
            }
            guard let created, let expires else { return nil }
            return expires.timeIntervalSince(created) / (24 * 60 * 60)
        }()
        let developmentProfile = entitlementValues?["get-task-allow"] as? Bool == true
        let localProvision = profile["LocalProvision"] as? Bool == true
        let enterprise = profile["ProvisionsAllDevices"] as? Bool == true
        let personal = !enterprise && (localProvision
            || (developmentProfile && (lifetimeDays.map { $0 <= 8 } ?? false)))
        return ProvisioningProfileInfo(createdAt: created, expiresAt: expires,
                                       teamIDs: teamIDs, isPersonal: personal)
    }
}

/// Whether this copy of LocalStore itself consumes one of iOS's three free
/// Personal Team app slots. Free Xcode provisioning marks the embedded profile
/// with `LocalProvision`; enterprise/ad-hoc distribution does not.
enum LocalStoreSignature {
    private static let profile: ProvisioningProfileInfo? = {
#if targetEnvironment(simulator)
        return nil
#else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return ProvisioningProfileReader.read(data)
#endif
    }()

    static var usesPersonalProvisioningSlot: Bool { profile?.isPersonal == true }
    static var personalTeamIDs: Set<String> {
        usesPersonalProvisioningSlot ? (profile?.teamIDs ?? []) : []
    }
}

private struct PersonalSignedAppScan {
    let records: [InstalledAppRecord]
    let installedBundleIDs: Set<String>
}

/// Reads the live device app registry through LaunchServices. App Store,
/// enterprise and system apps are excluded: an app must carry a seven-day
/// local provisioning profile or match the currently verified Personal Team.
private enum PersonalSignedAppsScanner {
    static func scan(knownPersonalTeamIDs: Set<String>,
                     existing: [String: InstalledAppRecord]) -> PersonalSignedAppScan? {
#if targetEnvironment(simulator)
        return nil
#else
        guard let workspaceClass: AnyClass = NSClassFromString("LSApplicationWorkspace"),
              let defaultMethod = class_getClassMethod(
                workspaceClass, NSSelectorFromString("defaultWorkspace"))
        else { return nil }

        typealias DefaultWorkspace = @convention(c) (AnyClass, Selector) -> AnyObject?
        let getWorkspace = unsafeBitCast(method_getImplementation(defaultMethod),
                                         to: DefaultWorkspace.self)
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let workspace = getWorkspace(workspaceClass, defaultSelector) else { return nil }

        guard let applications = object(workspace, selector: "allApplications") as? [AnyObject]
        else { return nil }

        let ownBundleID = Bundle.main.bundleIdentifier
        let acceptedTeams = knownPersonalTeamIDs.union(LocalStoreSignature.personalTeamIDs)
        var installedBundleIDs = Set<String>()
        var records: [InstalledAppRecord] = []

        for proxy in applications {
            guard string(proxy, selector: "applicationType") == "User",
                  let bundleID = string(proxy, selector: "bundleIdentifier"),
                  !bundleID.isEmpty else { continue }
            installedBundleIDs.insert(bundleID)
            guard bundleID != ownBundleID else { continue }

            let appURL = object(proxy, selector: "bundleURL") as? URL
            let profile = appURL.flatMap(ProvisioningProfileReader.read(at:))
            let proxyTeamID = teamID(from: proxy)
            let profileMatches = profile?.isPersonal == true
            let teamMatches = proxyTeamID.map(acceptedTeams.contains) == true
            guard profileMatches || teamMatches else { continue }

            let old = existing[bundleID]
            let name = string(proxy, selector: "localizedName")
                ?? string(proxy, selector: "itemName")
                ?? old?.name
                ?? bundleID
            let version = string(proxy, selector: "shortVersionString")
                ?? string(proxy, selector: "bundleVersion")
                ?? old?.version
                ?? ""
            let iconPNG = old?.iconPNG ?? icon(bundleID: bundleID)?.pngData()
            let discoveredAt = profile?.createdAt
                ?? date(proxy, selectors: ["installDate", "registrationDate", "bundleModTime"])
                ?? old?.lastSeen
                ?? Date()
            records.append(.init(bundleID: bundleID, name: name, version: version,
                                 iconPNG: iconPNG, lastSeen: discoveredAt,
                                 signingExpiresAt: profile?.expiresAt ?? old?.signingExpiresAt))
        }

        records.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return PersonalSignedAppScan(records: records,
                                     installedBundleIDs: installedBundleIDs)
#endif
    }

#if !targetEnvironment(simulator)
    private static func object(_ target: AnyObject, selector name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let cls: AnyClass = object_getClass(target),
              let method = class_getInstanceMethod(cls, selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(target, selector)
    }

    private static func string(_ target: AnyObject, selector: String) -> String? {
        object(target, selector: selector) as? String
    }

    private static func date(_ target: AnyObject, selectors: [String]) -> Date? {
        selectors.lazy.compactMap { object(target, selector: $0) as? Date }.first
    }

    private static func teamID(from proxy: AnyObject) -> String? {
        if let direct = string(proxy, selector: "teamID"), !direct.isEmpty { return direct }
        guard let entitlements = object(proxy, selector: "entitlements") as? [String: Any],
              let identifier = entitlements["application-identifier"] as? String,
              let prefix = identifier.split(separator: ".").first else { return nil }
        return String(prefix)
    }

    private static func icon(bundleID: String) -> UIImage? {
        let selector = NSSelectorFromString(
            "_applicationIconImageForBundleIdentifier:format:scale:")
        guard let method = class_getClassMethod(UIImage.self, selector) else { return nil }
        typealias IconGetter = @convention(c) (
            AnyClass, Selector, NSString, Int32, CGFloat
        ) -> UIImage?
        let getter = unsafeBitCast(method_getImplementation(method), to: IconGetter.self)
        let scale = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.scale }
            .first ?? 3
        return getter(UIImage.self, selector, bundleID as NSString, 10,
                      scale)
    }
#endif
}

@MainActor
final class InstalledAppsStore: ObservableObject {
    static let shared = InstalledAppsStore()
    @Published private(set) var apps: [InstalledAppRecord] = []

    private init(loadFromDisk: Bool = true) {
        let obsoleteCache = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RetainedIPAs", isDirectory: true)
        try? FileManager.default.removeItem(at: obsoleteCache)
        apps = loadFromDisk ? Self.read() : []
    }

    func recordInstalled(bundleID: String, name: String, version: String, iconPNG: Data?) {
        let record = InstalledAppRecord(bundleID: bundleID, name: name, version: version,
                                        iconPNG: iconPNG, lastSeen: Date())
        if let index = apps.firstIndex(where: { $0.bundleID == bundleID }) {
            apps[index] = record
        } else {
            apps.append(record)
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }

    func removeRecord(bundleID: String) {
        apps.removeAll { $0.bundleID == bundleID }
        save()
    }

    /// Merge every live Personal Team app into the list, including apps added
    /// by Xcode, AltStore or another installer. A successful scan is also
    /// authoritative for Home Screen deletions.
    @discardableResult
    func refreshPersonalSignedApps(personalTeamID: String?) -> [InstalledAppRecord] {
        var teamIDs = Set<String>()
        if let personalTeamID, !personalTeamID.isEmpty { teamIDs.insert(personalTeamID) }
        let existing = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })
        guard let scan = PersonalSignedAppsScanner.scan(
            knownPersonalTeamIDs: teamIDs, existing: existing) else { return [] }

        let removed = apps.filter { !scan.installedBundleIDs.contains($0.bundleID) }
        let scannedIDs = Set(scan.records.map(\.bundleID))
        let legacyInstalled = apps.filter {
            scan.installedBundleIDs.contains($0.bundleID) && !scannedIDs.contains($0.bundleID)
        }
        apps = (scan.records + legacyInstalled).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        save()
        return removed
    }

#if DEBUG
    static func preview(withSamples: Bool) -> InstalledAppsStore {
        let store = InstalledAppsStore(loadFromDisk: false)
        if withSamples {
            store.apps = [
                .init(bundleID: "com.example.dopamine", name: "Dopamine", version: "2.4.5",
                      iconPNG: nil, lastSeen: Date()),
                .init(bundleID: "com.example.utility", name: "ユーティリティ", version: "1.2.0",
                      iconPNG: nil, lastSeen: Date().addingTimeInterval(-3600)),
            ]
        }
        return store
    }
#endif

    private func save() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    private static func read() -> [InstalledAppRecord] {
        guard let data = try? Data(contentsOf: storeURL),
              let records = try? JSONDecoder().decode([InstalledAppRecord].self, from: data)
        else { return [] }
        return records
    }

    private static var storeURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ondevicesigner-install-history.json")
    }
}

/// Private pairing and signing state. Legacy locations are migrated without consuming a new pairing or
/// development-certificate slot.
enum PrivateStore {
    static var pairingFile: URL {
        resolve(private: directory.appendingPathComponent("rp_pairing_file.plist"),
                legacy: IPALibrary.documentsDir.appendingPathComponent("rp_pairing_file.plist"))
    }

    static var isideload: URL {
        let url = resolve(private: directory.appendingPathComponent("isideload", isDirectory: true),
                          legacy: IPALibrary.documentsDir.appendingPathComponent("isideload", isDirectory: true))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func resolve(private url: URL, legacy: URL) -> URL {
        _ = migrated
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { return url }
        if manager.fileExists(atPath: legacy.path) { return legacy }
        return url
    }

    private static let migrated: Void = {
        let manager = FileManager.default
        let support = directory
        for name in ["rp_pairing_file.plist", "isideload"] {
            let source = IPALibrary.documentsDir.appendingPathComponent(name)
            let destination = support.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path),
                  !manager.fileExists(atPath: destination.path) else { continue }
            do {
                try manager.copyItem(at: source, to: destination)
                try manager.removeItem(at: source)
            } catch {
                try? manager.removeItem(at: destination)
            }
        }
    }()
}
