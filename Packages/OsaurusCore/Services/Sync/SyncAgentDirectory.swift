//
//  SyncAgentDirectory.swift
//  osaurus
//
//  Each Mac lists the agents it runs for the user's other devices in one
//  synced conversation of its own (tagged `ai.osaurus.kind=agent-directory`),
//  and reads the other Macs' lists to offer their agents in the chat sidebar.
//

import Combine
import Foundation
import OsaurusSync
import os

@MainActor
final class SyncAgentDirectory: ObservableObject {
    static let shared = SyncAgentDirectory()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.directory")
    private static let publishDebounce: Duration = .milliseconds(500)

    /// Another of the user's Macs and the agents it runs for this one.
    struct Host: Identifiable, Equatable, Sendable {
        let device: String
        let name: String
        let agents: [SyncHostedRunContract.DirectoryEntry]
        var id: String { device }
    }

    /// The other Macs offering agents, by name.
    @Published private(set) var hosts: [Host] = []

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var listSubscription: OsaurusSync.Subscription?
    private var publishTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: SyncService.devicesDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SyncAgentDirectory.shared.scheduleReload() }
            })
        observers.append(
            center.addObserver(forName: SyncService.didChangeConfigurationNotification, object: nil, queue: .main) {
                _ in
                MainActor.assumeIsolated { SyncAgentDirectory.shared.schedulePublish() }
            })
        AgentManager.shared.$agents
            .map { agents in agents.filter(SyncHostRunner.canHost).map(Self.entry(for:)) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncAgentDirectory.shared.schedulePublish() } }
            .store(in: &cancellables)
        observers += SyncService.shared.observeCore(
            attach: { core in
                let directory = SyncAgentDirectory.shared
                directory.subscribe(core)
                directory.schedulePublish()
                directory.scheduleReload()
            },
            detach: { SyncAgentDirectory.shared.detach() })
    }

    private func detach() {
        listSubscription?.cancel()
        listSubscription = nil
    }

    private func subscribe(_ core: SyncCore) {
        listSubscription?.cancel()
        listSubscription = core.subscribeConversations { changes in
            let relevant = changes.contains { change in
                if case .changed(let conversation) = change {
                    return conversation.tag(SyncConversationMapper.TagKey.kind) == SyncHostedRunContract.directoryKind
                }
                return true
            }
            guard relevant else { return }
            Task { @MainActor in SyncAgentDirectory.shared.scheduleReload() }
        }
    }

    // MARK: - Publishing

    /// What this Mac offers: the user's agents and its Default agent
    /// (marked, so other Macs, which have their own, skip it), or nothing
    /// when the setting is off.
    nonisolated static func entries(agents: [Agent], hosting: Bool) -> [SyncHostedRunContract.DirectoryEntry] {
        guard hosting else { return [] }
        return agents.filter(SyncHostRunner.canHost).map(entry(for:)).sorted { $0.id < $1.id }
    }

    nonisolated private static func entry(for agent: Agent) -> SyncHostedRunContract.DirectoryEntry {
        let description = agent.routingDescription
        let isDefault = agent.id == Agent.defaultId
        return SyncHostedRunContract.DirectoryEntry(
            id: agent.id.uuidString.lowercased(),
            address: agent.agentAddress?.lowercased(),
            name: isDefault ? agent.displayName : agent.name,
            description: description.isEmpty ? nil : description,
            avatar: agent.avatar,
            isDefault: isDefault ? true : nil
        )
    }

    func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { @MainActor in
            try? await Task.sleep(for: Self.publishDebounce)
            guard !Task.isCancelled else { return }
            let entries = Self.entries(
                agents: AgentManager.shared.agents,
                hosting: SyncConfigurationStore.load().hostAgentsForOtherDevices
            )
            await Task.detached(priority: .utility) {
                do {
                    try SyncConversationStore.shared.performWrite { core in
                        try Self.publish(entries, core: core, deviceName: SyncService.deviceName)
                    }
                } catch SyncConversationStoreError.notOpen {
                } catch {
                    Self.log.error("publish failed: \(error.syncLogDetail, privacy: .public)")
                }
            }.value
        }
    }

    /// Writes this device's directory when it differs from `agents`. A device
    /// that offers nothing and never did writes nothing.
    nonisolated static func publish(
        _ agents: [SyncHostedRunContract.DirectoryEntry],
        core: SyncCore,
        deviceName: String,
        presence: SyncHostedRunContract.Presence.State = .awake
    ) throws {
        let me = core.deviceKey()
        let existing = try ownDirectory(core: core)
        let directory = SyncHostedRunContract.Directory(
            device: me,
            agents: agents,
            updatedMs: SyncHostedRunContract.nowMs(),
            features: SyncDeviceFeedContract.features,
            build: buildString,
            presence: .init(
                state: presence,
                networkMode: networkModeName(SyncConfigurationStore.load().networkMode),
                updatedMs: SyncHostedRunContract.nowMs()
            )
        )
        if let existing,
            let current = SyncHostedRunContract.read(
                SyncHostedRunContract.Directory.self,
                SyncHostedRunContract.directoryNamespace,
                from: existing
            ),
            current.sameContent(as: directory)
        {
            return
        }
        guard existing != nil || !agents.isEmpty else { return }
        let scope: String
        if let existing {
            scope = existing.scope
        } else {
            scope = try core.createConversation(
                title: String(localized: "Agents on \(deviceName)", bundle: .module),
                replication: .synced
            )
            try core.setConversationTags(
                scope: scope,
                tags: [
                    Tag(key: SyncConversationMapper.TagKey.device, value: me),
                    Tag(key: SyncConversationMapper.TagKey.kind, value: SyncHostedRunContract.directoryKind),
                ].sorted { $0.key < $1.key }
            )
        }
        try core.setConversationAppData(
            scope: scope,
            namespace: SyncHostedRunContract.directoryNamespace,
            bytes: try SyncHostedRunContract.encode(directory)
        )
    }

    nonisolated private static func ownDirectory(core: SyncCore) throws -> Conversation? {
        let filter = ConversationFilter(
            tags: [
                Tag(key: SyncConversationMapper.TagKey.kind, value: SyncHostedRunContract.directoryKind),
                Tag(key: SyncConversationMapper.TagKey.device, value: core.deviceKey()),
            ],
            replication: .synced,
            limit: 1
        )
        return try core.conversationsFiltered(filter: filter).first
    }

    /// Rewrites this Mac's directory with a new presence and pushes it out,
    /// as the Mac goes to sleep or quits. Nothing is written when this Mac
    /// has no directory.
    nonisolated static func writePresence(_ state: SyncHostedRunContract.Presence.State, core: SyncCore) {
        do {
            guard let existing = try ownDirectory(core: core),
                var directory = SyncHostedRunContract.read(
                    SyncHostedRunContract.Directory.self,
                    SyncHostedRunContract.directoryNamespace,
                    from: existing
                )
            else { return }
            let now = SyncHostedRunContract.nowMs()
            directory.updatedMs = now
            directory.presence = .init(
                state: state,
                networkMode: networkModeName(SyncConfigurationStore.load().networkMode),
                updatedMs: now
            )
            try core.setConversationAppData(
                scope: existing.scope,
                namespace: SyncHostedRunContract.directoryNamespace,
                bytes: try SyncHostedRunContract.encode(directory)
            )
            core.syncNow()
        } catch {
            log.error("presence write failed: \(error.syncLogDetail, privacy: .public)")
        }
    }

    nonisolated static func networkModeName(_ mode: SyncConfiguration.NetworkMode) -> String {
        switch mode {
        case .localNetworkOnly: return "localNetworkOnly"
        case .anywhere: return "anywhere"
        }
    }

    nonisolated static var buildString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }

    // MARK: - Reading

    func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            reloadTask = nil
            guard let core = SyncService.shared.core else {
                if !hosts.isEmpty { hosts = [] }
                return
            }
            let devices = SyncService.shared.devices
            let found = await Task.detached(priority: .utility) {
                Self.hosts(core: core, devices: devices)
            }.value
            if found != hosts { hosts = found }
        }
    }

    /// The directories of the user's other, non-revoked devices that offer
    /// at least one agent besides their Default agent.
    nonisolated static func hosts(core: SyncCore, devices: [Device]) -> [Host] {
        let me = core.deviceKey()
        var names: [String: String] = [:]
        for device in devices where !device.revoked && !device.isSelf && device.id != me {
            names[device.id] = device.name
        }
        let filter = ConversationFilter(
            tags: [Tag(key: SyncConversationMapper.TagKey.kind, value: SyncHostedRunContract.directoryKind)]
        )
        var latest: [String: SyncHostedRunContract.Directory] = [:]
        for conversation in (try? core.conversationsFiltered(filter: filter)) ?? [] {
            guard let device = conversation.tag(SyncConversationMapper.TagKey.device), names[device] != nil,
                let directory = SyncHostedRunContract.read(
                    SyncHostedRunContract.Directory.self,
                    SyncHostedRunContract.directoryNamespace,
                    from: conversation
                ),
                directory.device == device
            else { continue }
            if let seen = latest[device], seen.updatedMs >= directory.updatedMs { continue }
            latest[device] = directory
        }
        return latest.compactMap { device, directory -> Host? in
            let agents = directory.agents.filter { $0.isDefault != true }
            guard !agents.isEmpty, let name = names[device] else { return nil }
            return Host(
                device: device,
                name: name,
                agents: agents.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The agent `agentId` as `device` lists it.
    func entry(device: String, agentId: UUID) -> SyncHostedRunContract.DirectoryEntry? {
        hosts.first { $0.device == device }?.agents.first { $0.id == agentId.uuidString.lowercased() }
    }

    func host(device: String) -> Host? {
        hosts.first { $0.device == device }
    }

    /// The other Mac that lists the agent with `address`, preferring a
    /// connected one, and the agent's id there.
    func hostedAgent(address: String, connected: Set<String> = []) -> (device: String, agentId: UUID)? {
        let address = address.lowercased()
        let matches = hosts.compactMap { host -> (device: String, agentId: UUID)? in
            guard let entry = host.agents.first(where: { $0.address == address }),
                let agentId = UUID(uuidString: entry.id)
            else { return nil }
            return (host.device, agentId)
        }
        return matches.first { connected.contains($0.device) } ?? matches.first
    }

    #if DEBUG
        func _setHostsForTesting(_ hosts: [Host]) {
            self.hosts = hosts
        }

        var _isAttachedForTesting: Bool { listSubscription != nil }

        func _resetForTesting() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            cancellables.removeAll()
            detach()
            publishTask?.cancel()
            publishTask = nil
            reloadTask?.cancel()
            reloadTask = nil
            hosts = []
            started = false
        }
    #endif
}
