//
//  SwarmManager.swift
//  osaurus
//
//  Main-actor owner of the Swarm master state the UI and pickers read:
//  paired nodes, pools, installs in progress, the pairing offer, leases this
//  master holds and recent activity. Mirrors the backend through its event
//  stream and pushes the pool × model catalog to the provider layer
//  (`RemoteProviderManager`) and to `SwarmModelService` for routing.
//

import Combine
import Foundation

@MainActor
final class SwarmManager: ObservableObject {
    static let shared = SwarmManager()

    enum PairingState: Equatable {
        case idle
        case starting
        case offering(SwarmPairingOffer)
        case paired(SwarmNodeSnapshot)
        case failed(String)
    }

    struct ActivityEntry: Identifiable, Equatable {
        enum Kind: Equatable {
            case leased, finished, failed, cancelled, waiting, retrying, revoked, info
        }

        let id = UUID()
        let date: Date
        let kind: Kind
        let title: String
        let detail: String?
    }

    struct HeldLease: Identifiable, Equatable {
        var lease: SwarmLease
        var nodeName: String
        var poolName: String
        var requestsServed: Int
        var inFlight: Bool
        var id: String { lease.id }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var backendKind: SwarmBackendKind?
    @Published private(set) var startError: String?
    @Published private(set) var nodes: [SwarmNodeSnapshot] = []
    @Published private(set) var pools: [SwarmPool] = []
    @Published private(set) var installs: [String: SwarmInstallProgress] = [:]
    @Published private(set) var pairing: PairingState = .idle
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var heldLeases: [String: HeldLease] = [:]
    @Published private(set) var waitingRequests: [String: String] = [:]
    /// Last decode speed seen per node.
    @Published private(set) var nodeTokensPerSecond: [SwarmNodeID: Double] = [:]
    /// macOS Local Network approval, probed while the library backend runs.
    @Published private(set) var localNetworkAccess: SwarmLocalNetworkAccess = .unknown

    private(set) var backend: (any SwarmMasterBackend)?
    let service: SwarmModelService
    private var eventTask: Task<Void, Never>?
    private let localNetworkProbe = SwarmLocalNetworkProbe()
    private static let activityLimit = 200

    private init() {
        service = SwarmModelService(report: { event in
            Task { @MainActor in SwarmManager.shared.handle(event) }
        })
    }

    // MARK: - Lifecycle

    /// Starts the backend this build has (library, or the simulator when
    /// requested). A no-op when Swarm isn't available.
    func startIfAvailable() async {
        guard !isRunning, let backend = SwarmFeature.makeBackend() else { return }
        await start(with: backend)
    }

    /// Test / simulator seam: run on an explicit backend.
    func start(with backend: any SwarmMasterBackend) async {
        await stop()
        self.backend = backend
        backendKind = backend.kind
        do {
            try await backend.start(
                masterName: Host.current().localizedName ?? "Osaurus",
                stateDirectory: SwarmFeature.stateDirectory()
            )
        } catch {
            startError = error.localizedDescription
            self.backend = nil
            backendKind = nil
            return
        }
        startError = nil
        isRunning = true
        // Real nodes need Local Network approval (mDNS + LAN dials). The
        // simulator never touches the network, so it is not probed.
        if case .library = backend.kind {
            localNetworkProbe.start { [weak self] access in self?.localNetworkAccess = access }
        }
        let events = backend.events()
        eventTask = Task { [weak self] in
            for await event in events {
                self?.apply(event)
            }
        }
        await reloadFromBackend()
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        localNetworkProbe.stop()
        localNetworkAccess = .unknown
        if let backend { await backend.shutdown() }
        backend = nil
        backendKind = nil
        isRunning = false
        nodes = []
        pools = []
        installs = [:]
        heldLeases = [:]
        waitingRequests = [:]
        pairing = .idle
        publishCatalog()
    }

    func reloadFromBackend() async {
        guard let backend else { return }
        nodes = await backend.nodes()
        pools = await backend.pools()
        publishCatalog()
    }

    private func apply(_ event: SwarmBackendEvent) {
        switch event {
        case .nodeUpdated(let node):
            if let index = nodes.firstIndex(where: { $0.id == node.id }) {
                nodes[index] = node
            } else {
                nodes.append(node)
            }
            publishCatalog()
        case .nodeRemoved(let id):
            nodes.removeAll { $0.id == id }
            installs = installs.filter { $0.value.nodeId != id }
            publishCatalog()
        case .pairingCompleted(let node):
            if case .offering = pairing { pairing = .paired(node) }
            log(.info, String(format: L("Paired %@"), node.name), node.hardware.gpu)
        case .pairingFailed(let reason):
            pairing = .failed(reason)
        case .installProgress(let progress):
            installs[progress.id] = progress
            switch progress.state {
            case .installed:
                log(.info, String(format: L("Installed %@"), progress.modelId), nodeName(progress.nodeId))
            case .failed(let reason):
                log(.failed, String(format: L("Install failed: %@"), progress.modelId), reason)
            default: break
            }
            if progress.state.isFinished {
                let key = progress.id
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    if self?.installs[key]?.state.isFinished == true { self?.installs.removeValue(forKey: key) }
                }
            }
        case .leaseRevoked(let leaseId, let reason):
            if let held = heldLeases.removeValue(forKey: leaseId) {
                log(.revoked, String(format: L("Lease lost on %@"), held.nodeName), reason)
            }
        case .poolsChanged:
            Task { [weak self] in
                guard let self, let backend = self.backend else { return }
                self.pools = await backend.pools()
                self.publishCatalog()
            }
        }
    }

    // MARK: - Pairing

    /// The Add Node sheet that owns the current offer. A sheet's dismiss
    /// ends pairing only for its own session, so a new Add Node racing the
    /// previous sheet's dismiss keeps its offer.
    private var pairingSession: UUID?

    func beginPairing(session: UUID? = nil) async {
        guard let backend else { return }
        if let session { pairingSession = session }
        pairing = .starting
        do {
            let offer = try await backend.beginPairing()
            guard session == nil || pairingSession == session else { return }
            pairing = .offering(offer)
        } catch {
            pairing = .failed(error.localizedDescription)
        }
    }

    func endPairing(session: UUID? = nil) async {
        if let session, pairingSession != session { return }
        pairingSession = nil
        if case .offering = pairing, let backend { await backend.cancelPairing() }
        pairing = .idle
    }

    // MARK: - Nodes

    func removeNode(_ id: SwarmNodeID) async throws {
        guard let backend else { throw SwarmError.unavailable }
        let name = nodeName(id)
        try await backend.removeNode(id)
        log(.info, String(format: L("Removed %@"), name), nil)
    }

    func renameNode(_ id: SwarmNodeID, to name: String) async throws {
        guard let backend else { throw SwarmError.unavailable }
        try await backend.renameNode(id, name: name)
    }

    func node(_ id: SwarmNodeID) -> SwarmNodeSnapshot? {
        nodes.first { $0.id == id }
    }

    func nodeName(_ id: SwarmNodeID) -> String {
        node(id)?.name ?? id
    }

    // MARK: - Library

    /// Install from a Hugging Face link or `org/repo` on one node.
    func install(linkOrRepo text: String, on nodeId: SwarmNodeID) async throws {
        guard let backend else { throw SwarmError.unavailable }
        guard let repo = SwarmInstallSource.huggingFaceRepoId(from: text) else {
            throw SwarmError.invalidHuggingFaceLink(text)
        }
        let revision = SwarmInstallSource.huggingFaceRevision(from: text)
        try await backend.installModel(on: nodeId, source: .huggingFace(repoOrURL: text, revision: revision))
        log(.info, String(format: L("Installing %@"), repo), nodeName(nodeId))
    }

    /// Copy a model another swarm member already has.
    func install(peerModel modelId: String, on nodeId: SwarmNodeID) async throws {
        guard let backend else { throw SwarmError.unavailable }
        try await backend.installModel(on: nodeId, source: .peer(modelId: modelId, fromNode: nil))
        log(.info, String(format: L("Copying %@"), modelId), nodeName(nodeId))
    }

    func cancelInstall(_ progress: SwarmInstallProgress) async {
        await backend?.cancelInstall(on: progress.nodeId, modelId: progress.modelId)
    }

    func deleteModel(_ modelId: String, on nodeId: SwarmNodeID) async throws {
        guard let backend else { throw SwarmError.unavailable }
        try await backend.deleteModel(on: nodeId, modelId: modelId)
        log(.info, String(format: L("Deleted %@"), modelId), nodeName(nodeId))
    }

    func load(_ modelId: String, on nodeId: SwarmNodeID) async throws {
        guard let backend else { throw SwarmError.unavailable }
        try await backend.loadModel(on: nodeId, modelId: modelId)
    }

    func unload(_ modelId: String, on nodeId: SwarmNodeID) async throws {
        guard let backend else { throw SwarmError.unavailable }
        try await backend.unloadModel(on: nodeId, modelId: modelId)
    }

    func setPreheat(_ keepLoaded: Bool, model modelId: String, on nodeId: SwarmNodeID) async throws {
        guard let backend else { throw SwarmError.unavailable }
        try await backend.setPreheat(on: nodeId, modelId: modelId, keepLoaded: keepLoaded)
    }

    /// Pools that would lose this node if the model were deleted from it.
    func poolsAffected(byDeleting modelId: String, on nodeId: SwarmNodeID) -> [SwarmPool] {
        guard let node = node(nodeId) else { return [] }
        return pools.filter { pool in
            pool.nodeIds.contains(nodeId) && pool.modelIds.contains(modelId)
                && !pool.modelIds.contains { $0 != modelId && node.model($0) != nil }
        }
    }

    /// Every model installed anywhere in the swarm (for pool editing and
    /// peer installs), in first-seen order.
    var allInstalledModelIds: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for node in nodes {
            for model in node.models where seen.insert(model.modelId).inserted {
                out.append(model.modelId)
            }
        }
        return out
    }

    // MARK: - Pools

    func createPool(_ draft: SwarmPoolDraft) async throws {
        guard let backend else { throw SwarmError.unavailable }
        let pool = try await backend.createPool(draft)
        pools = await backend.pools()
        publishCatalog()
        log(.info, String(format: L("Created pool %@"), pool.name), nil)
    }

    func updatePool(_ id: SwarmPoolID, _ draft: SwarmPoolDraft) async throws {
        guard let backend else { throw SwarmError.unavailable }
        _ = try await backend.updatePool(id, draft)
        pools = await backend.pools()
        publishCatalog()
    }

    func deletePool(_ id: SwarmPoolID) async throws {
        guard let backend else { throw SwarmError.unavailable }
        let name = pools.first { $0.id == id }?.name ?? id
        try await backend.deletePool(id)
        pools = await backend.pools()
        publishCatalog()
        log(.info, String(format: L("Deleted pool %@"), name), nil)
    }

    /// Nodes that can serve every model of a pool draft (have them installed).
    func eligibleNodes(forModels modelIds: [String]) -> [SwarmNodeSnapshot] {
        nodes.filter { node in modelIds.allSatisfy { node.model($0) != nil } }
    }

    // MARK: - Leases

    /// Release every lease this master holds for a caller (chat session or
    /// agent run ended). Leases otherwise end at expiry while idle.
    func releaseAllLeases() async {
        guard let backend else { return }
        for id in heldLeases.keys {
            await backend.releaseLease(id)
        }
        heldLeases.removeAll()
    }

    func releaseLease(_ id: String) async {
        await backend?.releaseLease(id)
        heldLeases.removeValue(forKey: id)
    }

    // MARK: - Catalog

    /// One entry per pool × model, whether or not a node is free right now:
    /// a pool with no available node stays selectable and queues.
    var catalog: [SwarmCatalogEntry] {
        SwarmCatalogEntry.entries(pools: pools, nodes: nodes)
    }

    private func publishCatalog() {
        let entries = isRunning ? catalog : []
        service.update(
            backend: isRunning ? backend : nil,
            catalog: entries,
            nodeNames: Dictionary(nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        )
        RemoteProviderManager.shared.setSwarmCatalog(entries, service: isRunning ? service : nil)
    }

    // MARK: - Activity

    private func handle(_ event: SwarmActivityEvent) {
        switch event {
        case .waiting(let requestId, let pool, let model):
            waitingRequests[requestId] = pool
            log(.waiting, String(format: L("Waiting for a node in %@"), pool), model)
        case .leased(let requestId, let lease, let nodeName):
            waitingRequests.removeValue(forKey: requestId)
            let poolName = pools.first { $0.id == lease.poolId }?.name ?? lease.poolId
            if var held = heldLeases[lease.id] {
                held.lease = lease
                held.inFlight = true
                heldLeases[lease.id] = held
            } else {
                heldLeases[lease.id] = HeldLease(
                    lease: lease,
                    nodeName: nodeName,
                    poolName: poolName,
                    requestsServed: 0,
                    inFlight: true
                )
                log(
                    .leased,
                    String(format: L("Leased %@ from %@"), nodeName, poolName),
                    SwarmModelIdentity.shortModelName(lease.modelId) + (lease.warm ? " · " + L("warm") : "")
                )
            }
        case .finished(_, let lease, let nodeName, let tokens, let tps, let finishReason):
            if var held = heldLeases[lease.id] {
                held.requestsServed += 1
                held.inFlight = false
                heldLeases[lease.id] = held
            }
            if tps > 0 { nodeTokensPerSecond[lease.nodeId] = tps }
            log(
                .finished,
                String(
                    format: L("%@ answered: %d tokens at %.1f tok/s"),
                    nodeName,
                    tokens,
                    tps
                ),
                [SwarmModelIdentity.shortModelName(lease.modelId), finishReason].compactMap { $0 }.joined(
                    separator: " · "
                )
            )
        case .failed(let requestId, let pool, let model, let nodeName, let error):
            waitingRequests.removeValue(forKey: requestId)
            log(
                .failed,
                String(format: L("Request failed in %@"), pool),
                ([nodeName, model, error].compactMap { $0 }).joined(separator: " · ")
            )
        case .cancelled(let requestId, let lease, let nodeName):
            waitingRequests.removeValue(forKey: requestId)
            if let lease, var held = heldLeases[lease.id] {
                held.inFlight = false
                heldLeases[lease.id] = held
            }
            log(.cancelled, L("Request stopped"), nodeName)
        case .retrying(_, let fromNode, let reason):
            log(.retrying, String(format: L("Retrying on another node (left %@)"), fromNode), reason)
        }
        pruneExpiredLeases()
    }

    private func pruneExpiredLeases() {
        let now = Date()
        heldLeases = heldLeases.filter { $0.value.inFlight || $0.value.lease.expiresAt > now }
    }

    private func log(_ kind: ActivityEntry.Kind, _ title: String, _ detail: String?) {
        activity.insert(ActivityEntry(date: Date(), kind: kind, title: title, detail: detail), at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
    }

    #if DEBUG
        func _testReset() async {
            await stop()
            activity = []
            nodeTokensPerSecond = [:]
        }
    #endif
}
