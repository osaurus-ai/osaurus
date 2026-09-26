//
//  DistributedNodeDiscovery.swift
//  osaurus
//
//  Opt-in LAN advertisement and bounded discovery of other Osaurus Macs for
//  the Distributed Inference panel. The advertisement is a hint, not trust:
//  it is unauthenticated, carries no credentials, and its listener accepts no
//  data (every connection is cancelled; there is no control plane yet).
//
//  What makes it useful is the Thunderbolt domain UUID list. A peer whose
//  advertised domain UUID matches the host cabled to one of this Mac's
//  Thunderbolt ports is on the far end of that physical cable — the same
//  reciprocal-domain check used to validate hand-cabled TP pairs, done
//  natively instead of over SSH.
//

import Foundation
import Network
import os

/// Contents of the `_osaurus-dist._tcp` TXT record.
struct DistributedNodeAdvert: Equatable, Sendable {
    static let serviceType = "_osaurus-dist._tcp"
    static let protocolVersion = 1
    /// DNS-SD TXT entries are length-prefixed by one byte.
    static let maximumEntryBytes = 255

    var nodeID: String
    var host: String
    var appVersion: String
    /// This Mac's own Thunderbolt domain UUIDs (one per bus).
    var thunderboltDomains: [String]
    var rdma: String
    var memoryBytes: UInt64
    var modelID: String?
    /// Short identity fingerprint of the selected bundle on the advertising Mac.
    var modelFingerprint: String?

    func txtRecord() -> [String: String] {
        var record: [String: String] = [
            "v": String(Self.protocolVersion),
            "node": nodeID,
            "host": host,
            "app": appVersion,
            "tb": thunderboltDomains.joined(separator: ","),
            "rdma": rdma,
            "mem": String(memoryBytes),
        ]
        if let modelID { record["model"] = modelID }
        if let modelFingerprint { record["mfp"] = modelFingerprint }
        // Drop, never truncate, an oversize value: a cut-off model id or UUID
        // list would be a different, wrong claim.
        return record.filter { key, value in key.utf8.count + 1 + value.utf8.count <= Self.maximumEntryBytes }
    }

    /// nil for another protocol version or a record without a node id.
    static func parse(_ record: [String: String]) -> DistributedNodeAdvert? {
        guard record["v"] == String(protocolVersion), let node = record["node"], !node.isEmpty else { return nil }
        return DistributedNodeAdvert(
            nodeID: node,
            host: record["host"] ?? "Unknown Mac",
            appVersion: record["app"] ?? "unknown",
            thunderboltDomains: (record["tb"] ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty },
            rdma: record["rdma"] ?? "unknown",
            memoryBytes: record["mem"].flatMap(UInt64.init) ?? 0,
            modelID: record["model"],
            modelFingerprint: record["mfp"]
        )
    }
}

/// A peer seen during a scan, with the evidence this Mac can check itself.
struct DiscoveredNode: Identifiable, Equatable, Sendable {
    enum ModelMatch: Equatable, Sendable {
        case sameBundle
        case differentBundle
        /// Same model id, but one side has not reported a bundle fingerprint.
        case unverified
        case differentModel(String)
        case peerHasNoSelection
        case noLocalSelection
    }

    var id: String { advert.nodeID }
    let advert: DistributedNodeAdvert
    /// BSD interfaces the advertisement was received on (e.g. `en0`, `bridge0`).
    let interfaces: [String]
    /// This Mac's Thunderbolt ports whose cabled host is this peer.
    let cabledPorts: [ThunderboltPort]

    var isCableVerified: Bool { !cabledPorts.isEmpty }

    static func cabledPorts(for advert: DistributedNodeAdvert, ports: [ThunderboltPort]) -> [ThunderboltPort] {
        let domains = Set(advert.thunderboltDomains)
        return ports.filter { port in port.peers.contains { domains.contains($0.domainUUID) } }
    }

    func modelMatch(localModelID: String?, localFingerprint: String?) -> ModelMatch {
        guard let localModelID, !localModelID.isEmpty else { return .noLocalSelection }
        guard let peerModel = advert.modelID, !peerModel.isEmpty else { return .peerHasNoSelection }
        guard peerModel == localModelID else { return .differentModel(peerModel) }
        guard let localFingerprint, let peerFingerprint = advert.modelFingerprint else { return .unverified }
        return localFingerprint == peerFingerprint ? .sameBundle : .differentBundle
    }
}

enum DistributedDiscoveryError: Equatable, Sendable {
    /// Local Network privacy denied, or the service type is undeclared.
    case localNetworkDenied
    case failed(String)

    static func classify(_ error: NWError) -> DistributedDiscoveryError {
        if case .dns(let code) = error,
            code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
                || code == DNSServiceErrorType(kDNSServiceErr_NoAuth)
        {
            return .localNetworkDenied
        }
        return .failed(error.localizedDescription)
    }
}

// MARK: - Advertiser

/// Publishes this Mac while "Make This Mac Discoverable" is on. Persisted, and
/// resumed at launch; off by default.
@MainActor
final class DistributedNodeAdvertiser: ObservableObject {
    static let shared = DistributedNodeAdvertiser()
    static let enabledKey = "DistributedDiscoverable"
    static let nodeIDKey = "DistributedNodeID"
    nonisolated private static let logger = Logger(subsystem: "com.osaurus", category: "distributed")

    enum State: Equatable {
        case off
        /// Listening, but Bonjour has not confirmed the service is visible.
        case publishing
        /// Registered with mDNS or seen by this Mac's own browse.
        case advertising(port: UInt16)
        /// Never became visible. On macOS this is Local Network privacy:
        /// publishing is held silently until the user allows access.
        case notVisible
        case failed(DistributedDiscoveryError)

        var isAdvertising: Bool {
            if case .advertising = self { return true }
            return false
        }
    }

    /// How long to wait for our own advert before reporting it as not visible.
    static let visibilityDeadline: Duration = .seconds(15)

    @Published private(set) var state: State = .off
    @Published private(set) var advert: DistributedNodeAdvert?
    private var listener: NWListener?
    /// Browses for our own advert: macOS only asks for Local Network access
    /// when an app browses, so advertising alone could stay invisible forever
    /// without the user ever being asked.
    private var selfCheck: NWBrowser?
    private var visibilityTask: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// Stable per-install node id; never derived from hardware serials.
    var nodeID: String {
        if let existing = defaults.string(forKey: Self.nodeIDKey), !existing.isEmpty { return existing }
        let created = UUID().uuidString
        defaults.set(created, forKey: Self.nodeIDKey)
        return created
    }

    func setEnabled(_ enabled: Bool, advert: DistributedNodeAdvert?) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled, let advert { start(advert) } else if !enabled { stop() }
    }

    /// Launch hook: resumes a persisted opt-in. The advert (including the
    /// persisted model selection's identity) is gathered off the main actor.
    func startIfEnabled() {
        guard isEnabled, listener == nil else { return }
        state = .publishing
        let node = nodeID
        let modelID = defaults.string(forKey: DistributedPreviewService.selectedModelKey) ?? ""
        Task {
            let advert = await DistributedPreviewService.launchAdvert(nodeID: node, modelID: modelID)
            guard self.isEnabled, self.listener == nil else { return }
            self.start(advert)
        }
    }

    /// Republishes with new TXT (e.g. model selection changed) or starts.
    func update(_ advert: DistributedNodeAdvert) {
        guard isEnabled else { return }
        if let listener {
            self.advert = advert
            listener.service = Self.service(for: advert)
        } else {
            start(advert)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stopSelfCheck()
        state = .off
    }

    private func stopSelfCheck() {
        visibilityTask?.cancel()
        visibilityTask = nil
        selfCheck?.cancel()
        selfCheck = nil
    }

    private func confirmVisible(_ listener: NWListener) {
        guard self.listener === listener else { return }
        state = .advertising(port: listener.port?.rawValue ?? 0)
        stopSelfCheck()
    }

    private func startSelfCheck(for listener: NWListener, nodeID: String) {
        stopSelfCheck()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: DistributedNodeAdvert.serviceType, domain: "local."),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self, weak listener] results, _ in
            MainActor.assumeIsolated {
                guard let self, let listener else { return }
                if DistributedNodeScanner.adverts(in: results).contains(where: { $0.0.nodeID == nodeID }) {
                    self.confirmVisible(listener)
                }
            }
        }
        selfCheck = browser
        browser.start(queue: .main)
        visibilityTask = Task { [weak self, weak listener] in
            try? await Task.sleep(for: Self.visibilityDeadline)
            guard !Task.isCancelled, let self, let listener, self.listener === listener else { return }
            if !self.state.isAdvertising { self.state = .notVisible }
            self.stopSelfCheck()
        }
    }

    private func start(_ advert: DistributedNodeAdvert) {
        stop()
        self.advert = advert
        state = .publishing
        let listener: NWListener
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            listener = try NWListener(using: parameters)
        } catch {
            state = .failed(.failed(error.localizedDescription))
            return
        }
        listener.service = Self.service(for: advert)
        // No control plane exists yet; refuse every connection immediately.
        listener.newConnectionHandler = { connection in connection.cancel() }
        // Started on the main queue, so callbacks already run on the main actor.
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch newState {
                case .ready:
                    // Listening is not visibility; wait for registration or self-sighting.
                    if !self.state.isAdvertising { self.state = .publishing }
                case .failed(let error), .waiting(let error):
                    Self.logger.error("distributed advertiser: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed(DistributedDiscoveryError.classify(error))
                default: break
                }
            }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self, weak listener] change in
            MainActor.assumeIsolated {
                guard let self, let listener else { return }
                if case .add = change { self.confirmVisible(listener) }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
        startSelfCheck(for: listener, nodeID: advert.nodeID)
    }

    private static func service(for advert: DistributedNodeAdvert) -> NWListener.Service {
        NWListener.Service(
            name: String(advert.host.prefix(40)),
            type: DistributedNodeAdvert.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord(advert.txtRecord()).data
        )
    }
}

// MARK: - Scanner

/// One bounded scan. Results from a stopped scan never publish: every callback
/// checks that its browser is still the current one.
@MainActor
final class DistributedNodeScanner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case cancelled
        case failed(DistributedDiscoveryError)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var nodes: [DiscoveredNode] = []
    /// This Mac's own advert appeared in the scan (proves Local Network access).
    @Published private(set) var sawOwnAdvert = false

    private var browser: NWBrowser?
    private var deadline: Task<Void, Never>?
    private var ports: [ThunderboltPort] = []
    private var ownNodeID = ""

    func start(duration: Duration = .seconds(8), ownNodeID: String, ports: [ThunderboltPort]) {
        cancel(markCancelled: false)
        self.ports = ports
        self.ownNodeID = ownNodeID
        nodes = []
        sawOwnAdvert = false
        phase = .scanning
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: DistributedNodeAdvert.serviceType, domain: "local."),
            using: parameters
        )
        // Started on the main queue, so callbacks already run on the main actor.
        // A callback from a cancelled or replaced browser is ignored.
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .failed(let error), .waiting(let error):
                    self.finish(.failed(DistributedDiscoveryError.classify(error)))
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                let adverts = Self.adverts(in: results)
                if adverts.contains(where: { $0.0.nodeID == self.ownNodeID }) { self.sawOwnAdvert = true }
                self.nodes = Self.nodes(from: adverts, ownNodeID: self.ownNodeID, ports: self.ports)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
        deadline = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.finish(.finished)
        }
    }

    func cancel() { cancel(markCancelled: true) }

    /// Re-evaluates cable matches after a Thunderbolt refresh.
    func updatePorts(_ ports: [ThunderboltPort]) {
        self.ports = ports
        nodes = nodes.map {
            DiscoveredNode(
                advert: $0.advert,
                interfaces: $0.interfaces,
                cabledPorts: DiscoveredNode.cabledPorts(for: $0.advert, ports: ports)
            )
        }
    }

    private func cancel(markCancelled: Bool) {
        let wasScanning = phase == .scanning
        deadline?.cancel()
        deadline = nil
        browser?.cancel()
        browser = nil
        if markCancelled, wasScanning { phase = .cancelled }
    }

    private func finish(_ phase: Phase) {
        guard self.phase == .scanning else { return }
        deadline?.cancel()
        deadline = nil
        browser?.cancel()
        browser = nil
        self.phase = phase
    }

    /// Bonjour results → parsed adverts with every interface each was seen on.
    nonisolated static func adverts(in results: Set<NWBrowser.Result>) -> [(DistributedNodeAdvert, [String])] {
        results.compactMap { result in
            guard case .bonjour(let txt) = result.metadata,
                let advert = DistributedNodeAdvert.parse(txt.dictionary)
            else { return nil }
            var interfaces = result.interfaces.map(\.name)
            if case .service(_, _, _, let interface?) = result.endpoint { interfaces.append(interface.name) }
            return (advert, interfaces)
        }
    }

    /// Merges adverts per node id (a Mac seen on Wi-Fi and Thunderbolt Bridge
    /// is one node), drops this Mac, and checks each against the cabled ports.
    nonisolated static func nodes(
        from adverts: [(DistributedNodeAdvert, [String])],
        ownNodeID: String,
        ports: [ThunderboltPort]
    ) -> [DiscoveredNode] {
        var byNode: [String: (DistributedNodeAdvert, Set<String>)] = [:]
        for (advert, interfaces) in adverts where advert.nodeID != ownNodeID {
            byNode[advert.nodeID] = (advert, (byNode[advert.nodeID]?.1 ?? []).union(interfaces))
        }
        return byNode.values
            .map {
                DiscoveredNode(
                    advert: $0.0,
                    interfaces: $0.1.sorted(),
                    cabledPorts: DiscoveredNode.cabledPorts(for: $0.0, ports: ports)
                )
            }
            .sorted { ($0.isCableVerified ? 0 : 1, $0.advert.host) < ($1.isCableVerified ? 0 : 1, $1.advert.host) }
    }
}
