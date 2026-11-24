//
//  SwarmSettingsView.swift
//  osaurus
//
//  Settings → Providers → Osaurus Swarm: the master side of Swarm. Nodes
//  (pair your own Macs, see their hardware, status and models, manage each
//  node's library), Pools (named groups of nodes that serve the same models,
//  with lease duration, max queue wait and context length) and Activity
//  (leases this Mac holds, queued requests, per-node token/s, recent
//  errors). Pool models appear in every model picker under Osaurus Swarm.
//

import AppKit
import SwiftUI

enum SwarmSettingsTab: String, CaseIterable, AnimatedTabItem {
    case nodes = "Nodes"
    case pools = "Pools"
    case activity = "Activity"

    var title: String {
        switch self {
        case .nodes: return L("Nodes")
        case .pools: return L("Pools")
        case .activity: return L("Activity")
        }
    }
}

struct SwarmSettingsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var swarm = SwarmManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    @State private var tab: SwarmSettingsTab = .nodes
    @State private var showsAddNode = false
    /// The Add Node sheet's pairing session: its dismiss withdraws only its
    /// own offer, never one a newer Add Node already made.
    @State private var pairingSession: UUID?
    @State private var managedNode: ManagedNode?
    @State private var editingPool: PoolEditorRequest?
    @State private var actionError: String?

    struct ManagedNode: Identifiable {
        let id: SwarmNodeID
    }

    struct PoolEditorRequest: Identifiable {
        let id = UUID()
        let pool: SwarmPool?
    }

    var body: some View {
        SettingsPage {
            header
        } content: {
            if !swarm.isRunning {
                unavailableNotice
            } else {
                if let actionError {
                    SettingsCallout(
                        icon: "exclamationmark.triangle.fill",
                        title: "Swarm Action Failed",
                        message: actionError,
                        verbatimMessage: true,
                        tone: .error
                    ) {
                        SettingsButton(.tertiary, "Dismiss") { self.actionError = nil }
                    }
                }
                switch tab {
                case .nodes: nodesContent
                case .pools: poolsContent
                case .activity: activityContent
                }
            }
        }
        .onAppear { applySubTabRequest(managementState.swarmSubTabRequest) }
        .onChange(of: managementState.swarmSubTabRequest) { _, request in applySubTabRequest(request) }
        .sheet(
            isPresented: $showsAddNode,
            onDismiss: {
                let session = pairingSession
                Task { await swarm.endPairing(session: session) }
            }
        ) {
            SwarmAddNodeSheet(onClose: { showsAddNode = false })
        }
        .sheet(item: $managedNode) { node in
            SwarmNodeSheet(nodeId: node.id, onClose: { managedNode = nil })
        }
        .sheet(item: $editingPool) { request in
            SwarmPoolEditorSheet(pool: request.pool, onClose: { editingPool = nil })
        }
    }

    /// The pairing offer is made here and withdrawn on the sheet's dismiss,
    /// not from the sheet's own appear/disappear: a sheet's content can be
    /// laid out (and disappear) more than once while it is shown.
    private func addNode() {
        let session = UUID()
        pairingSession = session
        showsAddNode = true
        Task { await swarm.beginPairing(session: session) }
    }

    private func applySubTabRequest(_ request: String?) {
        guard let request else { return }
        if let target = SwarmSettingsTab(rawValue: request) { tab = target }
        managementState.swarmSubTabRequest = nil
    }

    // MARK: - Header

    private var header: some View {
        SettingsPageHeader(
            title: "Osaurus Swarm",
            subtitle: "Run models on your own Macs. Pools of nodes appear in every model picker.",
            titleAccessory: swarm.backendKind == .simulator ? AnyView(simulatorChip) : nil,
            primary: {
                switch tab {
                case .nodes, .activity:
                    SettingsButton(.primary, "Add Node", icon: "plus") { addNode() }
                        .disabled(!swarm.isRunning)
                        .settingsLandingAnchor("providers.swarm.addNode")
                case .pools:
                    SettingsButton(.primary, "New Pool", icon: "plus") { editingPool = PoolEditorRequest(pool: nil) }
                        .disabled(!swarm.isRunning || swarm.nodes.isEmpty)
                        .settingsLandingAnchor("providers.swarm.newPool")
                }
            },
            toolbar: {
                SettingsTabsRow(
                    selection: $tab,
                    counts: [.nodes: swarm.nodes.count, .pools: swarm.pools.count]
                )
            }
        )
    }

    private var simulatorChip: some View {
        StatusChip(
            L("Simulator"),
            tone: .warning,
            icon: "testtube.2",
            help: L("Simulated in-process nodes (OSAURUS_SWARM_SIMULATOR=1). No real device is paired.")
        )
    }

    private var unavailableNotice: some View {
        SettingsCallout(
            icon: "circle.hexagongrid",
            title: "Osaurus Swarm Isn't Available",
            message: swarm.startError
                ?? L("This build of Osaurus doesn't include the Swarm library, so nodes can't be paired here."),
            verbatimMessage: true,
            tone: .info
        )
    }

    // MARK: - Nodes

    @ViewBuilder
    private var nodesContent: some View {
        if swarm.localNetworkAccess == .denied {
            SettingsCallout(
                icon: "network.slash",
                title: "Allow Local Network to Find Nodes",
                message:
                    "Osaurus needs Local Network access to discover and reach your Swarm nodes. Turn on Osaurus in Privacy & Security → Local Network, then come back.",
                tone: .warning
            ) {
                SettingsButton(.primary, "Open Privacy Settings") {
                    NSWorkspace.shared.open(SwarmLocalNetworkProbe.settingsURL)
                }
            }
        }
        if swarm.nodes.isEmpty {
            SettingsSection(title: "Nodes", anchorId: "providers.swarm.nodes") {
                SettingsEmptyState(
                    inline: "desktopcomputer",
                    title: "No Nodes Yet",
                    hint: "Install Osaurus Swarm on another Mac, then click Add Node and enter the code it shows.",
                    action: .init(title: L("Add Node"), icon: "plus", handler: { addNode() })
                )
            }
        } else {
            SettingsSection(
                title: "Nodes",
                subtitle:
                    "Paired devices that run models for this Osaurus. They never get your chats, agents, memory or keys.",
                anchorId: "providers.swarm.nodes"
            ) {
                SettingsGroup {
                    ForEach(swarm.nodes) { node in
                        nodeRow(node)
                    }
                }
            }
            .settingsLandingAnchor("providers.swarm.installModel")
            .settingsLandingAnchor("providers.swarm.preheat")
            .settingsLandingAnchor("providers.swarm.library")
            .settingsLandingAnchor("providers.swarm.deleteModel")
            .settingsLandingAnchor("providers.swarm.removeNode")
            installsSection
        }
    }

    private func nodeRow(_ node: SwarmNodeSnapshot) -> some View {
        SettingsRow(
            title: node.name,
            verbatimTitle: true,
            leading: {
                SettingsIconTile(icon: node.hardware.backend == .metal ? "desktopcomputer" : "pc")
            },
            description: {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: SwarmFormat.hardwareLine(node))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                    Text(verbatim: SwarmFormat.modelsLine(node))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                    if let detail = node.availability.detail {
                        Text(verbatim: detail)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
            },
            trailing: {
                HStack(spacing: theme.space.s8) {
                    StatusChip(node.availability.label, tone: SwarmFormat.tone(node.availability), showsDot: true)
                    SettingsButton(.secondary, "Manage", size: .compact) { managedNode = ManagedNode(id: node.id) }
                }
            }
        )
    }

    @ViewBuilder
    private var installsSection: some View {
        let active = swarm.installs.values.sorted { $0.id < $1.id }
        if !active.isEmpty {
            SettingsSection(title: "Installing") {
                SettingsGroup {
                    ForEach(active) { progress in
                        SwarmInstallRow(progress: progress)
                    }
                }
            }
        }
    }

    // MARK: - Pools

    @ViewBuilder
    private var poolsContent: some View {
        if swarm.pools.isEmpty {
            SettingsSection(title: "Pools", anchorId: "providers.swarm.pools") {
                SettingsEmptyState(
                    inline: "square.stack.3d.up",
                    title: "No Pools Yet",
                    hint: swarm.nodes.isEmpty
                        ? "Pair a node and install a model on it first."
                        : "A pool groups nodes that serve the same model. Its models appear in every model picker under Osaurus Swarm.",
                    action: swarm.nodes.isEmpty
                        ? nil
                        : .init(
                            title: L("New Pool"),
                            icon: "plus",
                            handler: { editingPool = PoolEditorRequest(pool: nil) }
                        )
                )
            }
        } else {
            SettingsSection(
                title: "Pools",
                subtitle: "Callers lease one node of a pool at a time. Each pool × model appears in the model pickers.",
                anchorId: "providers.swarm.pools"
            ) {
                SettingsGroup {
                    ForEach(swarm.pools) { pool in
                        poolRow(pool)
                    }
                }
            }
            .settingsLandingAnchor("providers.swarm.leaseDuration")
            .settingsLandingAnchor("providers.swarm.maxQueueWait")
            .settingsLandingAnchor("providers.swarm.contextLength")
            .settingsLandingAnchor("providers.swarm.poolName")
        }
    }

    private func poolRow(_ pool: SwarmPool) -> some View {
        let entries = swarm.catalog.filter { $0.pool.id == pool.id }
        return SettingsRow(
            title: pool.name,
            verbatimTitle: true,
            leading: { SettingsIconTile(icon: "square.stack.3d.up.fill") },
            description: {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: pool.modelIds.map(SwarmModelIdentity.shortModelName).joined(separator: ", "))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                    Text(verbatim: SwarmFormat.poolLine(pool, entries: entries))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            },
            trailing: {
                HStack(spacing: theme.space.s8) {
                    let available = entries.map(\.availableNodes).max() ?? 0
                    StatusChip(
                        available == 0 ? L("No nodes available") : String(format: L("%d available"), available),
                        tone: available == 0 ? .warning : .success,
                        showsDot: true
                    )
                    SettingsButton(.secondary, "Edit", size: .compact) { editingPool = PoolEditorRequest(pool: pool) }
                    SettingsOverflowMenu(help: "Pool actions", size: .compact) {
                        Button(role: .destructive) {
                            Task {
                                do { try await swarm.deletePool(pool.id) } catch {
                                    actionError = error.localizedDescription
                                }
                            }
                        } label: {
                            Label(L("Delete Pool"), systemImage: "trash")
                        }
                    }
                }
            }
        )
    }

    // MARK: - Activity

    @ViewBuilder
    private var activityContent: some View {
        SettingsSection(
            title: "Active Leases",
            subtitle: "A lease holds one node for a caller and renews while it keeps sending requests.",
            anchorId: "providers.swarm.activity"
        ) {
            let leases = swarm.heldLeases.values.sorted { $0.lease.expiresAt < $1.lease.expiresAt }
            if leases.isEmpty && swarm.waitingRequests.isEmpty {
                SettingsEmptyState(
                    inline: "clock",
                    title: "No Active Leases",
                    hint: "Send a message with a Swarm model to lease a node."
                )
            } else {
                SettingsGroup {
                    ForEach(leases) { held in
                        SettingsRow(
                            title: "\(held.nodeName) · \(held.poolName)",
                            description: SwarmFormat.leaseLine(held),
                            verbatimTitle: true,
                            verbatimDescription: true
                        ) {
                            HStack(spacing: theme.space.s8) {
                                StatusChip(
                                    held.inFlight ? L("Generating") : L("Idle"),
                                    tone: held.inFlight ? .accent : .neutral,
                                    showsDot: true,
                                    pulses: held.inFlight
                                )
                                SettingsButton(.tertiary, "Release", size: .compact) {
                                    Task { await swarm.releaseLease(held.id) }
                                }
                            }
                        }
                    }
                    if !swarm.waitingRequests.isEmpty {
                        SettingsRow(
                            title: "Waiting for a Swarm node",
                            description: Set(swarm.waitingRequests.values).sorted().joined(separator: ", "),
                            verbatimDescription: true
                        ) {
                            CountBadge(swarm.waitingRequests.count, prominence: .neutral)
                        }
                    }
                }
            }
        }
        if !swarm.nodeTokensPerSecond.isEmpty {
            SettingsSection(title: "Node Speed") {
                SettingsGroup {
                    ForEach(swarm.nodes.filter { swarm.nodeTokensPerSecond[$0.id] != nil }) { node in
                        SettingsRow(
                            title: node.name,
                            description: "Last request",
                            verbatimTitle: true
                        ) {
                            Text(verbatim: String(format: "%.1f tok/s", swarm.nodeTokensPerSecond[node.id] ?? 0))
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.primary)
                        }
                    }
                }
            }
        }
        SettingsSection(title: "Recent Activity") {
            if swarm.activity.isEmpty {
                SettingsEmptyState(inline: "list.bullet.rectangle", title: "Nothing Yet")
            } else {
                SettingsGroup {
                    ForEach(swarm.activity.prefix(50)) { entry in
                        SettingsRow(
                            title: entry.title,
                            description: [SwarmFormat.time(entry.date), entry.detail].compactMap { $0 }.joined(
                                separator: " · "
                            ),
                            verbatimTitle: true,
                            verbatimDescription: true,
                            leading: {
                                Image(systemName: SwarmFormat.icon(entry.kind))
                                    .glyphSize(.medium)
                                    .foregroundColor(SwarmFormat.color(entry.kind, theme: theme))
                            }
                        ) {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Install row

struct SwarmInstallRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var swarm = SwarmManager.shared
    let progress: SwarmInstallProgress

    var body: some View {
        SettingsRow(
            title: SwarmModelIdentity.shortModelName(progress.modelId),
            verbatimTitle: true,
            description: {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    Text(verbatim: "\(swarm.nodeName(progress.nodeId)) · \(SwarmFormat.installStateLine(progress))")
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                    SettingsProgressBar(value: progress.fraction)
                }
            },
            trailing: {
                if !progress.state.isFinished {
                    SettingsButton(.tertiary, "Cancel", size: .compact) {
                        Task { await swarm.cancelInstall(progress) }
                    }
                }
            }
        )
    }
}

// MARK: - Formatting

enum SwarmFormat {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    /// Memory in use against the owner's cap and the device total.
    static func memoryLine(_ node: SwarmNodeSnapshot) -> String {
        String(
            format: L("%@ in use · cap %@ of %@"),
            bytes(node.telemetry.memoryInUseBytes),
            bytes(node.hardware.memoryCapBytes),
            bytes(node.hardware.memoryTotalBytes)
        )
    }

    static func hardwareLine(_ node: SwarmNodeSnapshot) -> String {
        var parts = [
            node.hardware.gpu,
            "\(node.hardware.backend.displayName)",
            String(
                format: L("%@ in use · cap %@ of %@"),
                bytes(node.telemetry.memoryInUseBytes),
                bytes(node.hardware.memoryCapBytes),
                bytes(node.hardware.memoryTotalBytes)
            ),
            String(format: L("%@ disk free"), bytes(node.telemetry.diskFreeBytes)),
        ]
        if let path = node.path {
            var text = path.displayName
            if let rtt = node.rttMs { text += String(format: " · %.1f ms", rtt) }
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }

    static func modelsLine(_ node: SwarmNodeSnapshot) -> String {
        guard !node.models.isEmpty else { return L("No models installed") }
        return node.models.map { model in
            let name = SwarmModelIdentity.shortModelName(model.modelId)
            switch model.loadState {
            case .warm: return name + " (" + L("loaded") + ")"
            case .loading: return name + " (" + L("loading") + ")"
            case .cold: return name
            }
        }.joined(separator: ", ")
    }

    static func poolLine(_ pool: SwarmPool, entries: [SwarmCatalogEntry]) -> String {
        var parts = [
            pool.nodeIds.count == 1 ? L("1 node") : String(format: L("%d nodes"), pool.nodeIds.count),
            String(format: L("lease %@"), duration(pool.leaseSeconds)),
            String(format: L("max queue wait %@"), duration(pool.maxQueueWaitSeconds)),
        ]
        if let context = pool.contextLength { parts.append(String(format: L("context %d"), context)) }
        return parts.joined(separator: " · ")
    }

    static func leaseLine(_ held: SwarmManager.HeldLease) -> String {
        let remaining = max(0, Int(held.lease.expiresAt.timeIntervalSinceNow))
        return [
            SwarmModelIdentity.shortModelName(held.lease.modelId),
            held.inFlight ? L("renews while active") : String(format: L("%@ left"), duration(remaining)),
            held.requestsServed == 1 ? L("1 request") : String(format: L("%d requests"), held.requestsServed),
            held.lease.warm ? L("warm") : L("cold start"),
        ].joined(separator: " · ")
    }

    static func installStateLine(_ progress: SwarmInstallProgress) -> String {
        switch progress.state {
        case .queued: return L("Queued")
        case .downloading:
            if let total = progress.bytesTotal {
                return String(format: L("Downloading %@ of %@"), bytes(progress.bytesDone), bytes(total))
            }
            return L("Downloading")
        case .verifying: return L("Verifying")
        case .installed: return L("Installed")
        case .failed(let reason): return String(format: L("Failed: %@"), reason)
        case .cancelled: return L("Cancelled")
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return String(format: L("%d s"), seconds) }
        if seconds % 60 == 0 { return String(format: L("%d min"), seconds / 60) }
        return String(format: L("%d min %d s"), seconds / 60, seconds % 60)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func tone(_ availability: SwarmNodeAvailability) -> StatusChip.Tone {
        switch availability {
        case .available: return .success
        case .busy: return .accent
        case .paused: return .warning
        case .offline: return .neutral
        case .unreachableNoDirectPath, .updateRequired: return .error
        }
    }

    static func icon(_ kind: SwarmManager.ActivityEntry.Kind) -> String {
        switch kind {
        case .leased: return "lock.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        case .waiting: return "hourglass"
        case .retrying: return "arrow.triangle.2.circlepath"
        case .revoked: return "bolt.horizontal.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    static func color(_ kind: SwarmManager.ActivityEntry.Kind, theme: any ThemeProtocol) -> Color {
        switch kind {
        case .finished: return theme.status[.success].foreground
        case .failed, .revoked: return theme.status[.error].foreground
        case .waiting, .retrying, .cancelled: return theme.status[.warning].foreground
        case .leased, .info: return theme.text.secondary
        }
    }
}
