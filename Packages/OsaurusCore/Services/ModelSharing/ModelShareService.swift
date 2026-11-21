//
//  ModelShareService.swift
//  osaurus
//
//  Shares model files with other Osaurus Macs on the local network and
//  finds the ones they share. Owns the `ModelShareNode`, keeps what this Mac
//  publishes in step with installed models and the user's choices, and turns
//  nearby hosts' catalogs into offers the catalogs and downloaders use.
//

import Combine
import Foundation
import OsaurusSync

/// One model a nearby Mac shares.
struct NearbyOffer: Identifiable, Hashable, Sendable {
    let hostId: String
    let hostName: String
    let model: NearbyModel

    var id: String { "\(hostId)/\(model.id)" }
    var kind: ModelShareKind? { ModelShareKind(rawValue: model.kind) }
    var source: NearbySource { NearbySource(hostId: hostId, hostName: hostName, itemId: model.id) }
    var totalBytes: Int64 { model.files.reduce(0) { $0 + Int64($1.size) } }

    /// The id the kind's catalog uses (the part after `<kind>:`).
    var localId: String {
        guard let kind, model.id.hasPrefix("\(kind.rawValue):") else { return model.id }
        return String(model.id.dropFirst(kind.rawValue.count + 1))
    }

    /// Whether this offer is the catalog row `localId` of `kind`, or the
    /// same Hugging Face repo.
    func matches(kind: ModelShareKind, localId: String, repoId: String? = nil) -> Bool {
        guard self.kind == kind else { return false }
        if self.localId.caseInsensitiveCompare(localId) == .orderedSame { return true }
        guard let repoId, let offered = model.repoId else { return false }
        return offered.caseInsensitiveCompare(repoId) == .orderedSame
    }
}

@MainActor
final class ModelShareService: ObservableObject {
    static let shared = ModelShareService()

    enum Status: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var configuration: ModelSharingConfiguration
    @Published private(set) var status: Status = .off
    /// Nearby Macs whose catalogs have been read, sorted by name.
    @Published private(set) var hosts: [NearbyHost] = []
    /// Every model this Mac could share, while sharing is on.
    @Published private(set) var shareable: [ShareableModel] = []
    /// Shared models still being hashed before they're published.
    @Published private(set) var preparingIds: Set<String> = []
    /// Shared models nearby Macs can see now.
    @Published private(set) var publishedIds: Set<String> = []
    /// Installed models copied from a nearby Mac while Hugging Face couldn't
    /// be reached, by lowercased model id, with that Mac's name.
    @Published private(set) var uncheckedCopies: [String: String] = [:]

    /// The running node, for transfers. `nil` while sharing and finding are both off.
    private(set) var node: ModelShareNode?
    private var running: (share: Bool, browse: Bool)?
    private var lifecycle: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var started = false
    private let index = SharedModelIndex()

    private init() {
        configuration = ModelSharingConfigurationStore.load()
    }

    /// Brings sharing and finding up as configured. Idempotent; called at launch.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.publisher(for: .localModelsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleRescan()
                self?.refreshUncheckedCopies()
            }
            .store(in: &subscriptions)
        SpeechModelManager.shared.$downloadStates
            .map { states in Set(states.filter { $0.value == .completed }.keys) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRescan() }
            .store(in: &subscriptions)
        PrivacyFilterModelDownloader.shared.$state
            .map { $0 == .ready }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRescan() }
            .store(in: &subscriptions)
        RampartModelManager.shared.$state
            .map { $0 == .ready }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRescan() }
            .store(in: &subscriptions)
        refreshUncheckedCopies()
        apply()
    }

    private func refreshUncheckedCopies() {
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                var copies: [String: String] = [:]
                for model in ModelManager.localModelsSnapshotNonBlocking() where !model.isExternallyOwned {
                    if let host = NearbyCopyMarker.hostName(in: model.localDirectory) {
                        copies[model.id.lowercased()] = host
                    }
                }
                return copies
            }.value
            guard let self, found != self.uncheckedCopies else { return }
            self.uncheckedCopies = found
        }
    }

    // MARK: - Settings

    func setShareOnLocalNetwork(_ on: Bool) {
        update { $0.shareOnLocalNetwork = on }
    }

    func setUseNearbyMacs(_ on: Bool) {
        update { $0.useNearbyMacs = on }
    }

    /// Shares or stops sharing one model. Sharing a model turns sharing on.
    func setShared(_ id: String, _ shared: Bool) {
        update {
            if shared {
                $0.sharedItemIds.insert(id)
                $0.shareOnLocalNetwork = true
            } else {
                $0.sharedItemIds.remove(id)
            }
        }
    }

    /// True when nearby Macs can see `id` or will once it's prepared.
    func isShared(_ id: String) -> Bool {
        configuration.shareOnLocalNetwork && configuration.isShared(id)
    }

    private func update(_ change: (inout ModelSharingConfiguration) -> Void) {
        var next = configuration
        change(&next)
        guard next != configuration else { return }
        configuration = next
        ModelSharingConfigurationStore.save(next)
        apply()
    }

    // MARK: - Offers

    /// Models nearby Macs share of `kind`, by host name then model name.
    func offers(kind: ModelShareKind) -> [NearbyOffer] {
        guard configuration.useNearbyMacs else { return [] }
        return hosts.flatMap { host in
            host.models
                .filter { $0.kind == kind.rawValue && $0.format == kind.format }
                .map { NearbyOffer(hostId: host.id, hostName: host.name, model: $0) }
        }
    }

    func offers(kind: ModelShareKind, localId: String, repoId: String? = nil) -> [NearbyOffer] {
        offers(kind: kind).filter { $0.matches(kind: kind, localId: localId, repoId: repoId) }
    }

    /// Offers of a Hugging Face repo in `format`, whatever kind the host
    /// filed it under.
    func offers(repoId: String, format: String) -> [NearbyOffer] {
        ModelShareKind.allCases.filter { $0.format == format }.flatMap { kind in
            offers(kind: kind).filter { $0.model.repoId?.caseInsensitiveCompare(repoId) == .orderedSame }
        }
    }

    func hasOffers(kind: ModelShareKind) -> Bool { !offers(kind: kind).isEmpty }

    /// Asks every known host for its catalog now rather than at the next poll.
    func refreshHosts() {
        node?.refresh()
        hosts = node?.hosts() ?? []
    }

    // MARK: - Node lifecycle

    private func apply() {
        let share = configuration.shareOnLocalNetwork
        let browse = configuration.useNearbyMacs
        if share {
            scheduleRescan()
        } else {
            scanTask?.cancel()
            publishTask?.cancel()
            shareable = []
            preparingIds = []
            publishedIds = []
        }
        if let running, running.share == share, running.browse == browse, node != nil {
            schedulePublish()
            return
        }
        let previous = lifecycle
        lifecycle = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.restart(share: share, browse: browse)
        }
    }

    private func restart(share: Bool, browse: Bool) async {
        if let node {
            await node.stop()
            self.node = nil
            running = nil
            hosts = []
            publishedIds = []
        }
        guard share || browse else {
            status = .off
            return
        }
        status = .starting
        do {
            let node = try ModelShareNode()
            let name = await Task.detached { SyncService.deviceName }.value
            try await node.start(
                config: ModelShareConfig(deviceName: name, share: share, browse: browse, mdns: true, bindPort: 0),
                listener: HostsListener { [weak self] in
                    Task { @MainActor in self?.hosts = self?.node?.hosts() ?? [] }
                }
            )
            // Settings changed while the node came up: the next lifecycle step restarts it.
            guard configuration.shareOnLocalNetwork == share, configuration.useNearbyMacs == browse else {
                await node.stop()
                return
            }
            self.node = node
            running = (share, browse)
            status = .running
            schedulePublish()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Publishing

    private func scheduleRescan() {
        guard configuration.shareOnLocalNetwork else { return }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            let busy = self.busyShareIds()
            let models = await Task.detached(priority: .utility) { ShareableModelInventory.scan(busy: busy) }.value
            guard !Task.isCancelled else { return }
            if models != self.shareable { self.shareable = models }
            self.schedulePublish()
        }
    }

    /// Publishes the shared models already hashed, then hashes the rest one
    /// at a time, publishing each as it's ready.
    private func schedulePublish() {
        publishTask?.cancel()
        guard configuration.shareOnLocalNetwork, running?.share == true, let node else {
            preparingIds = []
            publishedIds = []
            return
        }
        let all = shareable
        let wanted = all.filter { configuration.isShared($0.id) }
        let index = index
        publishTask = Task { [weak self] in
            var published: [SharedModel] = []
            var pending: [ShareableModel] = []
            for model in wanted {
                if await index.isPrepared(model), let shared = try? await index.prepare(model) {
                    published.append(shared)
                } else {
                    pending.append(model)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.preparingIds = Set(pending.map(\.id))
            self.publish(published, on: node)
            for model in pending {
                do {
                    published.append(try await index.prepare(model))
                } catch is CancellationError {
                    return
                } catch {
                    print("[ModelShareService] Can't share \(model.id): \(error.localizedDescription)")
                }
                guard !Task.isCancelled else { return }
                self.preparingIds.remove(model.id)
                self.publish(published, on: node)
            }
            await index.save(keeping: all)
        }
    }

    private func publish(_ models: [SharedModel], on node: ModelShareNode) {
        do {
            try node.setSharedModels(models: models)
            publishedIds = Set(models.map(\.id))
        } catch {
            print("[ModelShareService] Failed to publish shared models: \(error)")
        }
    }

    /// Share ids of models still downloading, which aren't complete yet.
    private func busyShareIds() -> Set<String> {
        var busy = Set<String>()
        for (id, state) in ModelDownloadService.shared.downloadStates {
            switch state {
            case .downloading, .paused:
                for kind in [ModelShareKind.language, .embedding, .applescript] {
                    busy.insert(ShareableModel.id(kind: kind, localId: id))
                }
            default: break
            }
        }
        for (id, state) in ImageModelDownloadService.shared.states {
            if case .downloading = state { busy.insert(ShareableModel.id(kind: .image, localId: id)) }
        }
        for (id, state) in SpeechModelManager.shared.downloadStates {
            if case .downloading = state { busy.insert(ShareableModel.id(kind: .speech, localId: id)) }
        }
        switch PrivacyFilterModelDownloader.shared.state {
        case .ready, .idle, .failed: break
        default: busy.insert(ShareableModel.id(kind: .privacy, localId: PrivacyFilterModelBundle.version))
        }
        if case .downloading = RampartModelManager.shared.state {
            busy.insert(ShareableModel.id(kind: .privacy, localId: RampartModelManager.version))
        }
        return busy
    }
}

private final class HostsListener: ModelShareListener, @unchecked Sendable {
    private let changed: @Sendable () -> Void
    init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
    func hostsChanged() { changed() }
}
