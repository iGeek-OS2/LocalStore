import Foundation
import OnDeviceCore
import Network
import AVFAudio
import CoreLocation

/// Drives the RPPairing host: requests Local Network, keeps the app alive while
/// the user approves the PIN in Settings, advertises the service over Bonjour,
/// and runs `si_pairing_run_host` off the main thread, logging into `Engine`.
@MainActor
final class PairingController {

    static let shared = PairingController()

    private let hostName = "LocalStore"
    private let hostModel = "Mac17,7"   // device sees a Mac-like pairing host
    private let bindAddress = "0.0.0.0"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive = KeepAlive()

    private var running = false

    /// Resolved when a `startAndWait` pairing finishes; nil for `start()`.
    private var pairContinuation: CheckedContinuation<String, Error>?

    private var engine: Engine { Engine.shared }

    private init() {}

    /// Errors surfaced by the awaitable pairing API.
    enum PairingError: LocalizedError {
        case busy
        case localNetworkDenied
        case zeroBytes
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .busy:
                return L("Pairing is already in progress.")
            case .localNetworkDenied:
                return L("Local Network permission is off. Enable it in Settings › LocalStore › Local Network, then try again.")
            case .zeroBytes:
                return L("Pairing produced an empty file. Make sure you approved the pairing request, then try again.")
            case let .failed(message):
                return message
            }
        }
    }

    /// Where the pairing file is written, and read back from; see `PrivateStore`.
    nonisolated static func pairingFilePath() -> String {
        PrivateStore.pairingFile.path
    }

    /// Start the host and resolve with the pairing-file path, or throw.
    func startAndWait() async throws -> String {
        if running { throw PairingError.busy }
        return try await withCheckedThrowingContinuation { cont in
            pairContinuation = cont
            start()
        }
    }

    /// Unblock the awaited path; the host thread ends when the FFI call returns.
    func softCancel() {
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<String, Error>) {
        guard let cont = pairContinuation else { return }
        pairContinuation = nil
        cont.resume(with: result)
    }

    func start() {
        guard !running else {
            engine.log("ペアリングはすでに進行中です。")
            return
        }
        running = true
        engine.pairingStatus = L("requesting Local Network…")
        engine.log("ペアリング：ローカルネットワークの許可を確認しています…")

        Task {
            guard await localNetwork.request() else {
                engine.log("ペアリング：ローカルネットワークが許可されていません。設定のLocalStoreから許可して、もう一度試してください。")
                engine.pairingStatus = L("Local Network denied")
                running = false
                resolve(.failure(PairingError.localNetworkDenied))
                return
            }
            engine.log("ペアリング：ローカルネットワークが許可されました。接続維持処理を開始します。")
            keepAlive.startAudio()
            engine.pairingStatus = L("waiting for device…")
            runHost()
        }
    }

    private func runHost() {
        let bind = bindAddress
        let name = hostName
        let model = hostModel
        let outPath = Self.pairingFilePath()
        // Retained for the C callbacks' ctx, and released after the run.
        let ctxAddress = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())

        engine.log("ペアリング処理を開始します（保存先：\(outPath)）。")

        DispatchQueue.global(qos: .userInitiated).async {
            let ctx = UnsafeMutableRawPointer(bitPattern: ctxAddress)!
            var result = SIPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            si_pairing_run_host(
                                bindC, 0, nameC, modelC, outC,
                                pairReadyCallback, pairPinCallback, ctx, &result)
                        }
                    }
                }
            }

            let outcome: PairOutcome
            if rc == 0 {
                outcome = .success(
                    name: cStr(result.device_name),
                    model: cStr(result.device_model),
                    udid: cStr(result.device_udid),
                    path: cStr(result.pairing_file_path))
            } else {
                let msg = cStr(result.error)
                outcome = .failure(msg.isEmpty ? "pairing failed (rc=\(rc))" : msg)
            }
            si_pairing_result_free(&result)
            Unmanaged<PairingController>.fromOpaque(ctx).release()

            DispatchQueue.main.async {
                self.finish(outcome)
            }
        }
    }

    private enum PairOutcome {
        case success(name: String, model: String, udid: String, path: String)
        case failure(String)
    }

    private func finish(_ outcome: PairOutcome) {
        stopAdvertising()
        keepAlive.stopAll()
        running = false
        engine.pairingPIN = nil

        switch outcome {
        case let .success(name, model, udid, path):
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            engine.log("ペアリング成功：\(name)（\(model)）、UDID：\(udid)")
            engine.log("ペアリング情報を\(path)へ保存しました（\(size)バイト）。")
            if size == 0 {
                engine.log("ペアリング情報が空のため、端末接続には使用できません。")
                engine.pairingStatus = L("failed: empty pairing file")
                resolve(.failure(PairingError.zeroBytes))
            } else {
                engine.pairingFilePath = path
                engine.pairingStatus = L("paired: %@ (%dB)", name, size)
                resolve(.success(path))
            }
        case let .failure(message):
            let localized = japaneseBackendError(message, fallback: "ペアリング処理に失敗しました。")
            engine.log("ペアリングに失敗しました：\(localized)")
            engine.pairingStatus = L("failed: %@", localized)
            resolve(.failure(PairingError.failed(localized)))
        }
    }

    // MARK: Bonjour advertising

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        engine.log("ペアリングサービスを公開しています（識別子：\(serviceID)、ポート：\(port)）。")
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        engine.pairingStatus = L("advertising — open Settings › Privacy & Security › Developer Mode")
    }

    fileprivate func presentPin(_ pin: String) {
        engine.log("ペアリング確認コード：\(pin)。設定のデベロッパモードからLocalStoreとのペアリングを確認してください。")
        engine.pairingStatus = L("enter PIN %@ in Settings", pin)
        // Shown as a card on the Install screen.
        engine.pairingPIN = pin
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

// MARK: - C callbacks

private let pairReadyCallback: SIPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx = ctx, let serviceID = serviceID else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys = keys, let vals = vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

private let pairPinCallback: SIPairPinCb = { pin, ctx in
    guard let ctx = ctx, let pin = pin else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        controller.presentPin(pinString)
    }
}

private func cStr(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr = ptr else { return "" }
    return String(cString: ptr)
}

// MARK: - Device Remote Pairing service discovery

/// The device-side Remote Pairing listener is advertised through Bonjour and
/// its port is dynamic. LocalDevVPN rewrites only the address, so callers must
/// still use the port advertised by this iPhone rather than a fixed 49152.
struct RemotePairingEndpoint: Sendable, Equatable {
    let serviceName: String
    let port: UInt16
}

enum RemotePairingDiscoveryError: LocalizedError {
    case notFound
    case ambiguous([String])

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "このiPhoneのRemote Pairingサービスを検出できませんでした。Wi-FiとLocalDevVPNを確認してください。"
        case let .ambiguous(services):
            return "このiPhoneのRemote Pairingサービスを特定できませんでした（検出：\(services.joined(separator: "、"))）。"
        }
    }
}

/// Resolves `_remotepairing._tcp` and keeps only the service whose resolved
/// address belongs to this iPhone's Wi-Fi interface. This matters on networks
/// with more than one iPhone, where another device may still use port 49152.
final class RemotePairingServiceResolver: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = RemotePairingServiceResolver()

    private struct Candidate {
        let endpoint: RemotePairingEndpoint
        let addresses: Set<String>
    }

    private var browser: NetServiceBrowser?
    private var services: [ObjectIdentifier: NetService] = [:]
    private var candidates: [Candidate] = []
    private var ownWiFiAddresses: Set<String> = []
    private var continuation: CheckedContinuation<RemotePairingEndpoint, Error>?
    private var cached: (endpoint: RemotePairingEndpoint, date: Date)?

    @MainActor
    func resolve(force: Bool = false, timeout: TimeInterval = 3) async throws -> RemotePairingEndpoint {
        if !force, let cached, Date().timeIntervalSince(cached.date) < 10 {
            return cached.endpoint
        }
        if continuation != nil { finish(.failure(RemotePairingDiscoveryError.notFound)) }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            ownWiFiAddresses = Set(NetworkStatus.interfaces()
                .filter { $0.name == "en0" }
                .map(\.ipv4))
            candidates.removeAll(keepingCapacity: true)
            services.removeAll(keepingCapacity: true)

            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.completeAfterTimeout()
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        services[ObjectIdentifier(service)] = service
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0, sender.port <= Int(UInt16.max) else { return }
        let addresses = Set((sender.addresses ?? []).compactMap(Self.ipv4Address))
        let endpoint = RemotePairingEndpoint(serviceName: sender.name,
                                             port: UInt16(sender.port))
        candidates.removeAll { $0.endpoint.serviceName == endpoint.serviceName }
        candidates.append(Candidate(endpoint: endpoint, addresses: addresses))

        if !addresses.isDisjoint(with: ownWiFiAddresses) {
            finish(.success(endpoint))
        }
    }

    private func completeAfterTimeout() {
        guard continuation != nil else { return }
        if candidates.count == 1, let only = candidates.first {
            // Some iOS builds omit the address list even after resolution. A
            // single visible device is still unambiguous and safe to use.
            finish(.success(only.endpoint))
        } else if candidates.isEmpty {
            finish(.failure(RemotePairingDiscoveryError.notFound))
        } else {
            let descriptions = candidates.map {
                "\($0.endpoint.serviceName):\($0.endpoint.port)"
            }
            finish(.failure(RemotePairingDiscoveryError.ambiguous(descriptions)))
        }
    }

    private func finish(_ result: Result<RemotePairingEndpoint, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        browser?.stop()
        browser = nil
        for service in services.values {
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
        candidates.removeAll()
        if case let .success(endpoint) = result {
            cached = (endpoint, Date())
        }
        continuation.resume(with: result)
    }

    private static func ipv4Address(_ data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress,
                  rawBuffer.count >= MemoryLayout<sockaddr>.size else { return nil }
            let address = base.assumingMemoryBound(to: sockaddr.self)
            guard address.pointee.sa_family == sa_family_t(AF_INET),
                  rawBuffer.count >= MemoryLayout<sockaddr_in>.size else { return nil }
            let ipv4 = base.assumingMemoryBound(to: sockaddr_in.self)
            var value = ipv4.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
    }
}

@MainActor
private final class LocalNetworkAuthorization {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Bool, Never>?
    private let probeType = "_ondevicesigner._tcp"

    func request(timeout: TimeInterval = 60) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let listener = try? NWListener(using: parameters)
            listener?.service = .init(name: "LocalStore", type: probeType)
            listener?.newConnectionHandler = { $0.cancel() }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed = state { MainActor.assumeIsolated { self?.finish(false) } }
            }
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: parameters)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state { MainActor.assumeIsolated { self?.finish(false) } }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty { MainActor.assumeIsolated { self?.finish(true) } }
            }
            self.browser = browser
            listener?.start(queue: .main)
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(false) }
            }
        }
    }

    private func finish(_ authorized: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: authorized)
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
    }
}

@MainActor
private final class KeepAlive: NSObject, CLLocationManagerDelegate {
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioRunning = false
    private var locationRunning = false

    private lazy var location: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        return manager
    }()

    func startAudio() {
        guard !audioRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let format = audioEngine.outputNode.inputFormat(forBus: 0)
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
            let frames = AVAudioFrameCount(format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            try audioEngine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            audioRunning = true
        } catch {
            audioRunning = false
        }
    }

    func stopAudio() {
        guard audioRunning else { return }
        player.stop()
        audioEngine.stop()
        audioEngine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        audioRunning = false
    }

    func startLocation() {
        guard !locationRunning else { return }
        locationRunning = true
        location.requestAlwaysAuthorization()
        if CLLocationManager.locationServicesEnabled() {
            location.allowsBackgroundLocationUpdates = true
            location.startUpdatingLocation()
        }
    }

    func stopLocation() {
        guard locationRunning else { return }
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        locationRunning = false
    }

    func stopAll() {
        stopAudio()
        stopLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            MainActor.assumeIsolated {
                guard locationRunning else { return }
                manager.allowsBackgroundLocationUpdates = true
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
