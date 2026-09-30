import Foundation
import SystemConfiguration

/// Everything this Mac can report about itself for distributed setup, captured
/// off the main actor from fixed read-only commands. Missing evidence stays
/// nil/unknown; nothing here implies a rank or tensor-parallel readiness.
struct DistributedLocalSnapshot: Equatable, Sendable {
    var host: String
    var appVersion: String
    var memoryBytes: UInt64
    var rdma: RDMAState
    var rdmaDevices: [RDMADevice]
    /// nil when `system_profiler` could not be read (distinct from zero ports).
    var thunderboltPorts: [ThunderboltPort]?
    var links: [ThunderboltLinkSummary]
    var hardwarePorts: [String: String]
    var bridgeAddresses: [String]
    var capturedAt: Date

    var cabledMacs: [ThunderboltLinkSummary] { links.filter { $0.cabledMac != nil } }

    static func capture() -> DistributedLocalSnapshot {
        let rdmaResult = DiagnosticCommand.run("/usr/bin/rdma_ctl", ["status"])
        let rdma: RDMAState =
            rdmaResult.missing
            ? .unsupported
            : RDMAState.parse(
                rdmaCtlStatus: rdmaResult.exitStatus == 0
                    ? rdmaResult.output.flatMap { String(data: $0, encoding: .utf8) } : nil
            )
        var devices = DiagnosticCommand.text("/usr/bin/ibv_devices", []).map(RDMADeviceList.parse(ibvDevices:)) ?? []
        if !devices.isEmpty, let info = DiagnosticCommand.text("/usr/bin/ibv_devinfo", []) {
            devices = RDMADeviceList.merge(ibvDevinfo: info, into: devices)
        }
        let ports = DiagnosticCommand.run(
            "/usr/sbin/system_profiler",
            ["-json", "-detailLevel", "mini", "SPThunderboltDataType"],
            timeout: 15
        )
        .output.flatMap(ThunderboltTopology.parse)
        let hardware =
            DiagnosticCommand.text("/usr/sbin/networksetup", ["-listallhardwareports"])
            .map(HardwarePortMap.parse) ?? [:]
        let addresses = InterfaceAddresses.read()
        let bridge = hardware["Thunderbolt Bridge"]
        return DistributedLocalSnapshot(
            host: (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            rdma: rdma,
            rdmaDevices: devices,
            thunderboltPorts: ports,
            links: ThunderboltLinkSummary.build(
                ports: ports ?? [],
                hardwarePorts: hardware,
                rdmaDevices: devices,
                addresses: addresses
            ),
            hardwarePorts: hardware,
            bridgeAddresses: bridge.flatMap { addresses[$0] } ?? [],
            capturedAt: Date()
        )
    }

    func advert(nodeID: String, modelID: String?, modelFingerprint: String?) -> DistributedNodeAdvert {
        let rdmaText: String
        switch rdma {
        case .enabled: rdmaText = "enabled"
        case .disabled: rdmaText = "disabled"
        case .unsupported: rdmaText = "unsupported"
        case .unknown: rdmaText = "unknown"
        }
        return DistributedNodeAdvert(
            nodeID: nodeID,
            host: host,
            appVersion: appVersion,
            thunderboltDomains: (thunderboltPorts ?? []).compactMap(\.ownDomainUUID),
            rdma: rdmaText,
            memoryBytes: memoryBytes,
            modelID: modelID,
            modelFingerprint: modelFingerprint
        )
    }
}

/// A model bundle this Mac can resolve from its own Osaurus model catalog.
struct DistributedLocalModel: Identifiable, Equatable, Sendable {
    let id: String
    let directory: URL
    /// e.g. "LM Studio" for an imported bundle; nil for the Osaurus models folder.
    let source: String?
}

enum DistributedModelIdentityState: Equatable, Sendable {
    case none
    case computing(String)
    case ready(String, DistributedModelIdentity)
    /// The selected id is not in this Mac's catalog (deleted, unmounted, renamed).
    case unavailable(String)
    case failed(String, String)
}

/// Drives the Distributed Inference settings preview. Read-only: it never
/// starts a rank, loads weights, changes networking or touches cache entries.
@MainActor
final class DistributedPreviewService: ObservableObject {
    static let selectedModelKey = "DistributedPreviewSelectedModel"

    @Published private(set) var local: DistributedLocalSnapshot?
    @Published private(set) var cache: CacheVolumeReport?
    @Published private(set) var models: [DistributedLocalModel] = []
    @Published private(set) var modelsLoaded = false
    @Published private(set) var identity: DistributedModelIdentityState = .none
    @Published private(set) var refreshing = false
    /// Model or cache reads have taken long enough that macOS is probably
    /// holding them behind a privacy prompt (e.g. removable-volume access).
    @Published private(set) var slowDiskReads = false
    static let slowReadDelay: Duration = .seconds(5)
    @Published var selectedModelID: String {
        didSet {
            guard selectedModelID != oldValue else { return }
            defaults.set(selectedModelID, forKey: Self.selectedModelKey)
            computeIdentity()
        }
    }

    let scanner = DistributedNodeScanner()
    let advertiser: DistributedNodeAdvertiser
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var identityTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private var slowReadTask: Task<Void, Never>?
    /// Bumped on every refresh/stop so late detached results cannot publish.
    private var refreshGeneration = 0
    private var identityGeneration = 0
    private var modelsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, advertiser: DistributedNodeAdvertiser = .shared) {
        self.defaults = defaults
        self.advertiser = advertiser
        self.selectedModelID = defaults.string(forKey: Self.selectedModelKey) ?? ""
    }

    func start() {
        if modelsObserver == nil {
            modelsObserver = NotificationCenter.default.addObserver(
                forName: .localModelsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshing = true
        let settings = ServerRuntimeSettingsStore.snapshot().cache
        let directory = ModelRuntime.diskCacheDirectoryForDisplay(for: settings)
        let enabled = ModelRuntime.cacheDiskDirectoryOverride(for: settings) != nil
        refreshTask = Task {
            async let snapshot = Task.detached(priority: .utility) { DistributedLocalSnapshot.capture() }.value
            async let volume = Task.detached(priority: .utility) {
                CacheVolumeInspector.inspect(configured: directory, reuseEnabled: enabled, cacheSettings: settings)
            }.value
            let (local, cache) = await (snapshot, volume)
            guard !Task.isCancelled, generation == self.refreshGeneration else { return }
            self.local = local
            self.cache = cache
            self.refreshing = false
            if self.modelsLoaded { self.slowDiskReads = false }
            self.scanner.updatePorts(local.thunderboltPorts ?? [])
            self.publishAdvert()
        }
        loadModels(generation: generation)
        slowReadTask?.cancel()
        slowDiskReads = false
        slowReadTask = Task {
            try? await Task.sleep(for: Self.slowReadDelay)
            guard !Task.isCancelled, generation == self.refreshGeneration else { return }
            self.slowDiskReads = !self.modelsLoaded || self.cache == nil
        }
    }

    /// Waits for the launch-time model scan to finish before listing models.
    /// `discoverLocalModelsOffMain()` alone returns an empty list when its
    /// UI wait expires first, which the panel would report as "no models".
    private func loadModels(generation: Int) {
        modelsTask?.cancel()
        modelsTask = Task {
            await ModelManager.awaitLocalModelsCacheReadyForDispatch()
            let catalog = await ModelManager.discoverLocalModelsOffMain()
            guard !Task.isCancelled, generation == self.refreshGeneration else { return }
            self.models = Self.localModels(catalog)
            self.modelsLoaded = true
            if self.cache != nil { self.slowDiskReads = false }
            self.computeIdentity()
        }
    }

    /// Stops publication of in-flight work; bounded probes finish on their own.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        identityTask?.cancel()
        identityTask = nil
        modelsTask?.cancel()
        modelsTask = nil
        slowReadTask?.cancel()
        slowReadTask = nil
        refreshGeneration += 1
        identityGeneration += 1
        refreshing = false
        scanner.cancel()
        if let modelsObserver { NotificationCenter.default.removeObserver(modelsObserver) }
        modelsObserver = nil
    }

    func scan() {
        scanner.start(ownNodeID: advertiser.nodeID, ports: local?.thunderboltPorts ?? [])
        refresh()
    }

    func setDiscoverable(_ enabled: Bool) {
        advertiser.setEnabled(enabled, advert: currentAdvert())
    }

    var readyIdentity: DistributedModelIdentity? {
        if case .ready(let id, let identity) = identity, id == selectedModelID { return identity }
        return nil
    }

    /// The advert published at launch, before the panel has been opened.
    nonisolated static func launchAdvert(nodeID: String, modelID: String) async -> DistributedNodeAdvert {
        let snapshot = await Task.detached(priority: .utility) { DistributedLocalSnapshot.capture() }.value
        guard !modelID.isEmpty else { return snapshot.advert(nodeID: nodeID, modelID: nil, modelFingerprint: nil) }
        let model = localModels(await ModelManager.discoverLocalModelsOffMain()).first { $0.id == modelID }
        let fingerprint = await Task.detached(priority: .utility) {
            model.flatMap { try? DistributedModelIdentity.compute(bundle: $0.directory).shortFingerprint }
        }.value
        return snapshot.advert(nodeID: nodeID, modelID: modelID, modelFingerprint: fingerprint)
    }

    nonisolated static func localModels(_ catalog: [MLXModel]) -> [DistributedLocalModel] {
        var seen = Set<String>()
        return catalog.compactMap { model -> DistributedLocalModel? in
            guard seen.insert(model.id.lowercased()).inserted else { return nil }
            return DistributedLocalModel(id: model.id, directory: model.localDirectory, source: model.externalSource)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func currentAdvert() -> DistributedNodeAdvert? {
        guard let local else { return nil }
        let identity = readyIdentity
        return local.advert(
            nodeID: advertiser.nodeID,
            modelID: selectedModelID.isEmpty ? nil : selectedModelID,
            modelFingerprint: identity?.shortFingerprint
        )
    }

    private func computeIdentity() {
        identityTask?.cancel()
        identityGeneration += 1
        let generation = identityGeneration
        let id = selectedModelID
        guard !id.isEmpty else {
            identity = .none
            publishAdvert()
            return
        }
        guard modelsLoaded else { return }
        guard let model = models.first(where: { $0.id == id }) else {
            identity = .unavailable(id)
            publishAdvert()
            return
        }
        // Recompute on every refresh (a replaced shard must change the
        // fingerprint), but keep showing the previous result for the same
        // bundle meanwhile instead of flashing a spinner.
        var showingSameBundle = false
        if case .ready(let readyID, let ready) = identity {
            showingSameBundle = readyID == id && ready.bundlePath == model.directory.path
        }
        if !showingSameBundle { identity = .computing(id) }
        let directory = model.directory
        identityTask = Task {
            let result = await Task.detached(priority: .utility) {
                Result { try DistributedModelIdentity.compute(bundle: directory) }
            }.value
            guard !Task.isCancelled, generation == self.identityGeneration else { return }
            switch result {
            case .success(let computed): self.identity = .ready(id, computed)
            case .failure(let error): self.identity = .failed(id, Self.describe(error))
            }
            self.publishAdvert()
        }
    }

    private func publishAdvert() {
        guard advertiser.isEnabled, let advert = currentAdvert() else { return }
        advertiser.update(advert)
    }

    private static func describe(_ error: Error) -> String {
        switch error as? DistributedModelIdentity.Failure {
        case .missingConfig?: return L("config.json is missing from this bundle.")
        case .unreadableConfig?: return L("config.json could not be read.")
        case nil: return error.localizedDescription
        }
    }
}
