//
//  DistributedInferenceSettingsView.swift
//  osaurus
//
//  Settings → Distributed Inference. A setup preview for multi-Mac tensor
//  parallel inference: live local diagnostics (Thunderbolt cabling, RDMA,
//  SSD cache volume, model identity) and opt-in discovery of other Osaurus
//  Macs. It never starts ranks, loads weights, changes networking or touches
//  cache entries, and says so on screen.
//

import AppKit
import MLXLMCommon
import SwiftUI

struct DistributedInferenceSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var highlight = SettingsHighlightCoordinator.shared
    @StateObject private var service = DistributedPreviewService()
    @State private var showSetup = false
    /// Search landing target, kept briefly so the scroll can be repeated as
    /// sections finish loading and push the target further down.
    @State private var landingTarget: String?
    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeaderWithActions(
                title: L("Distributed Inference"),
                subtitle: L("Run one model across Macs connected with Thunderbolt 5.")
            ) {
                HeaderSecondaryButton(L("Refresh Status"), icon: "arrow.clockwise") { service.refresh() }
                    .disabled(service.refreshing)
                    .settingsLandingAnchor("distributed.refresh")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        DistributedOverviewCard(service: service)
                        thisMac
                        links
                        DistributedNodesSection(
                            service: service,
                            scanner: service.scanner,
                            advertiser: service.advertiser
                        )
                        DistributedModelSection(service: service)
                        cache
                        DistributedSetupSection(
                            service: service,
                            scanner: service.scanner,
                            advertiser: service.advertiser,
                            showSetup: $showSetup
                        )
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: highlight.pending) { _, id in land(id, proxy: proxy) }
                .onAppear { land(highlight.pending, proxy: proxy) }
                .onChange(of: service.local) { _, _ in relanding(proxy) }
                .onChange(of: service.cache) { _, _ in relanding(proxy) }
                .onChange(of: service.modelsLoaded) { _, _ in relanding(proxy) }
                .onChange(of: service.identity) { _, _ in relanding(proxy) }
            }
        }
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear { service.start() }
        .onDisappear { service.stop() }
        .sheet(isPresented: $showSetup) { DistributedSetupSheet(isPresented: $showSetup) }
    }

    private func land(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, id.hasPrefix("distributed.") else { return }
        landingTarget = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if landingTarget == id { landingTarget = nil }
        }
    }

    private func relanding(_ proxy: ScrollViewProxy) {
        guard let landingTarget else { return }
        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(landingTarget, anchor: .center) }
    }

    // MARK: This Mac

    private var thisMac: some View {
        SettingsSection(title: "This Mac", icon: "desktopcomputer", anchorId: "distributed.thisMac") {
            if let local = service.local {
                DistributedRow(L("Name"), local.host)
                DistributedRow(L("Osaurus"), local.appVersion)
                DistributedRow(
                    L("Unified memory"),
                    ByteCountFormatter.string(fromByteCount: Int64(clamping: local.memoryBytes), countStyle: .memory)
                )
                DistributedRow(
                    L("RDMA over Thunderbolt"),
                    DistributedText.rdma(local.rdma),
                    tone: DistributedText.rdmaTone(local.rdma)
                )
                DistributedRow(
                    L("RDMA devices"),
                    local.rdmaDevices.isEmpty
                        ? L("None reported")
                        : local.rdmaDevices.map { "\($0.name) \($0.portState.map { "· \($0)" } ?? "")" }.joined(
                            separator: "\n"
                        ),
                    tone: local.rdmaDevices.contains(where: \.isActive) ? .good : .neutral
                )
                DistributedRow(L("Rank"), L("Not assigned — no distributed session is running"))
            } else {
                DistributedLoadingRow(L("Reading this Mac…"))
            }
        }
    }

    // MARK: Thunderbolt links

    private var links: some View {
        SettingsSection(title: "Thunderbolt Links", icon: "bolt.horizontal", anchorId: "distributed.links") {
            if let local = service.local {
                if local.thunderboltPorts == nil {
                    DistributedNote(L("Thunderbolt information could not be read. Refresh to try again."), tone: .bad)
                } else if local.links.isEmpty {
                    DistributedNote(L("This Mac reports no Thunderbolt ports."), tone: .warn)
                } else {
                    ForEach(local.links) { link in DistributedLinkRow(link: link) }
                    if local.cabledMacs.isEmpty {
                        DistributedNote(
                            L(
                                "No Mac is cabled directly to a Thunderbolt port. Connect the Macs with a Thunderbolt 5 cable; docks and hubs do not count."
                            ),
                            tone: .warn
                        )
                    }
                }
                DisclosureGroup {
                    DistributedInterfaceDetails(local: local)
                } label: {
                    Text("Local Interface Diagnostics", bundle: .module).font(.system(size: 12, weight: .medium))
                }
                .settingsLandingAnchor("distributed.interfaces")
            } else {
                DistributedLoadingRow(L("Reading Thunderbolt ports…"))
            }
        }
    }

    // MARK: SSD cache

    private var cache: some View {
        SettingsSection(title: "SSD Cache", icon: "externaldrive", anchorId: "distributed.cache") {
            if let report = service.cache {
                DistributedNote(DistributedText.cacheState(report), tone: DistributedText.cacheTone(report))
                DistributedRow(
                    L("Reuse"),
                    report.reuseEnabled ? L("Enabled in Server settings") : L("Disabled in Server settings"),
                    tone: DistributedText.reuseTone(report)
                )
                if let disk = report.disk {
                    DistributedRow(
                        L("Volume"),
                        [disk.volumeName, report.mountPoint.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
                    )
                    DistributedRow(L("Physical storage"), DistributedText.device(disk))
                    DistributedRow(
                        L("Storage type"),
                        DistributedText.medium(disk),
                        tone: disk.medium == .solidState && !disk.isNetwork ? .good : .warn
                    )
                } else if let mount = report.mountPoint {
                    DistributedRow(L("Volume"), mount)
                }
                if report.mountPoint != nil {
                    DistributedRow(L("Free space"), DistributedText.cacheBytes(report.freeBytes, of: report.totalBytes))
                    DistributedRow(L("Cache quota"), DistributedText.quota(report.quota))
                    DistributedRow(
                        L("Used by this cache"),
                        report.usedBytes.map { DiskCacheUsage.format(bytes: Int(clamping: $0)) }
                            ?? L("Unknown — cache index unreadable")
                    )
                }
                DistributedPath(report.configuredPath)
                if report.resolvedPath != report.configuredPath {
                    DistributedRow(L("Resolves to"), report.resolvedPath)
                }
                Text(
                    "Each Mac keeps its own cache on its own SSD, configured in that Mac’s Server settings. Per-rank cache usage appears once distributed sessions run.",
                    bundle: .module
                )
                .font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        SettingsHighlightCoordinator.shared.request("settings.server.diskCacheDirectory")
                        ManagementStateManager.shared.serverSectionRequest = "cache"
                        ManagementStateManager.shared.selectedTab = .server
                    } label: {
                        Text("Configure SSD Cache", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .settingsLandingAnchor("distributed.configureCache")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report.resolvedPath)])
                    } label: {
                        Text("Show Cache in Finder", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!report.directoryExists)
                    .help(report.directoryExists ? report.resolvedPath : L("The cache folder does not exist yet."))
                    .settingsLandingAnchor("distributed.revealCache")
                }
            } else {
                DistributedLoadingRow(L("Reading cache location…"))
                if service.slowDiskReads {
                    DistributedNote(
                        L(
                            "Still reading the cache location. If macOS is asking whether Osaurus may access files on this drive, choose Allow."
                        ),
                        tone: .warn
                    )
                }
            }
        }
    }
}

// MARK: - Overview

private struct DistributedOverviewCard: View {
    @ObservedObject var service: DistributedPreviewService
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 26)).foregroundStyle(theme.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your Mac cluster", bundle: .module).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("Preview", bundle: .module).textCase(.uppercase).font(.system(size: 10, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.accentColor)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(theme.accentColor.opacity(0.12), in: Capsule())
                        .accessibilityLabel(L("Preview feature"))
                }
                Text(
                    "Setup checks on this page are live. Running a model across Macs is still being built: no ranks start and no weights load from this page.",
                    bundle: .module
                )
                .font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    stat("cable.connector", cabledText)
                    stat("bolt.horizontal.fill", rdmaText)
                    stat("number", L("0 ranks running"))
                }
                .padding(.top, 2)
            }
        }
        .padding(18)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
    }

    private var cabledText: String {
        guard let local = service.local else { return L("Checking cables…") }
        let count = local.cabledMacs.count
        return count == 1 ? L("1 Mac cabled") : String(format: L("%lld Macs cabled"), count)
    }

    private var rdmaText: String {
        guard let local = service.local else { return L("Checking RDMA…") }
        return DistributedText.rdma(local.rdma)
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 11)).foregroundStyle(theme.secondaryText).lineLimit(1)
    }
}

// MARK: - Nodes

private struct DistributedNodesSection: View {
    @ObservedObject var service: DistributedPreviewService
    @ObservedObject var scanner: DistributedNodeScanner
    @ObservedObject var advertiser: DistributedNodeAdvertiser
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSection(
            title: "Nodes & Ranks",
            icon: "rectangle.connected.to.line.below",
            anchorId: "distributed.nodes"
        ) {
            SettingsToggle(
                title: "Make This Mac Discoverable",
                description:
                    "Lets other Osaurus Macs on your network find this Mac. Shares its name, Osaurus version, memory, RDMA state, Thunderbolt IDs and selected model. Accepts no connections.",
                anchorId: "distributed.discoverable",
                isOn: Binding(get: { advertiser.isEnabled }, set: { service.setDiscoverable($0) })
            )
            DistributedRow(L("This Mac"), advertiserText, tone: advertiserTone)
            HStack(spacing: 10) {
                Button {
                    if scanner.phase == .scanning { scanner.cancel() } else { service.scan() }
                } label: {
                    Text(scanner.phase == .scanning ? "Cancel Scan" : "Check for TB5 Nodes", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle(isPrimary: scanner.phase != .scanning))
                .settingsLandingAnchor("distributed.scan")
                if scanner.phase == .scanning {
                    ProgressView().controlSize(.small).accessibilityLabel(L("Scanning for Macs"))
                }
            }
            DistributedNote(scanMessage, tone: scanTone)
            ForEach(scanner.nodes) { node in
                SettingsDivider()
                DistributedNodeRow(node: node, service: service)
            }
        }
    }

    private var advertiserText: String {
        switch advertiser.state {
        case .off: return L("Not discoverable")
        case .publishing: return L("Publishing… If macOS asks to find devices on local networks, choose Allow.")
        case .advertising: return L("Discoverable — seen on your local network")
        case .notVisible:
            return L(
                "Not visible on the network. Allow Local Network access for Osaurus, then turn this off and on again."
            )
        case .failed(.localNetworkDenied): return L("Blocked — allow Local Network access for Osaurus")
        case .failed(.failed(let message)): return String(format: L("Could not advertise: %@"), message)
        }
    }

    private var advertiserTone: DistributedTone {
        switch advertiser.state {
        case .advertising: return .good
        case .failed, .notVisible: return .bad
        default: return .neutral
        }
    }

    private var scanMessage: String {
        switch scanner.phase {
        case .idle:
            return L(
                "Finds Osaurus Macs that have Make This Mac Discoverable turned on, then checks which one is on the other end of your Thunderbolt cable."
            )
        case .scanning:
            return L("Looking for Osaurus Macs for 8 seconds…")
        case .cancelled:
            return L("Scan cancelled.")
        case .finished where scanner.nodes.isEmpty && advertiser.isEnabled && !scanner.sawOwnAdvert:
            return L(
                "This Mac could not see its own advertisement, so macOS is probably blocking Local Network access. Allow Osaurus in System Settings → Privacy & Security → Local Network, then check again."
            )
        case .finished where scanner.nodes.isEmpty:
            return L(
                "No Osaurus Macs found. Turn on Make This Mac Discoverable on the other Mac (and here, which also confirms Local Network access), then check again."
            )
        case .finished:
            return L(
                "Only a Mac with a verified cable can carry tensor traffic. Found Macs are not authenticated and are not assigned ranks yet."
            )
        case .failed(.localNetworkDenied):
            return L(
                "macOS blocked the scan. Allow Local Network access for Osaurus in System Settings → Privacy & Security → Local Network."
            )
        case .failed(.failed(let message)):
            return String(format: L("Scan failed: %@"), message)
        }
    }

    private var scanTone: DistributedTone {
        switch scanner.phase {
        case .failed: return .bad
        case .finished where scanner.nodes.isEmpty && advertiser.isEnabled && !scanner.sawOwnAdvert: return .bad
        case .finished where scanner.nodes.isEmpty: return .warn
        default: return .neutral
        }
    }
}

private struct DistributedNodeRow: View {
    let node: DiscoveredNode
    @ObservedObject var service: DistributedPreviewService
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(node.advert.host).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.primaryText)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                DistributedPill(
                    node.isCableVerified ? L("Cable verified") : L("No cable match"),
                    tone: node.isCableVerified ? .good : .warn
                )
            }
            DistributedRow(L("Osaurus"), node.advert.appVersion)
            DistributedRow(
                L("Unified memory"),
                ByteCountFormatter.string(fromByteCount: Int64(clamping: node.advert.memoryBytes), countStyle: .memory)
            )
            DistributedRow(L("RDMA"), node.advert.rdma.capitalized, tone: node.advert.rdma == "enabled" ? .good : .warn)
            DistributedRow(
                L("Found on"),
                DistributedText.interfaces(node.interfaces, ports: service.local?.hardwarePorts ?? [:])
            )
            DistributedRow(
                L("Thunderbolt"),
                node.isCableVerified
                    ? node.cabledPorts.map { $0.hardwarePortName ?? $0.busName }.joined(separator: ", ")
                    : L("Not cabled to this Mac — cannot carry tensor traffic"),
                tone: node.isCableVerified ? .good : .warn
            )
            DistributedRow(
                L("Model"),
                DistributedText.modelMatch(
                    node.modelMatch(
                        localModelID: service.selectedModelID.isEmpty ? nil : service.selectedModelID,
                        localFingerprint: service.readyIdentity?.shortFingerprint
                    )
                )
            )
            DistributedRow(L("Rank"), L("Not assigned · peer not authenticated"))
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Model

private struct DistributedModelSection: View {
    @ObservedObject var service: DistributedPreviewService
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSection(title: "Model & Placement", icon: "cube.box", anchorId: "distributed.modelSection") {
            HStack(spacing: 12) {
                Text("Distributed Model", bundle: .module).font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                    .frame(width: 140, alignment: .leading)
                Picker(selection: $service.selectedModelID) {
                    Text("Select a model on this Mac…", bundle: .module).tag("")
                    ForEach(service.models) { model in
                        Text(model.source.map { "\(model.id) (\($0))" } ?? model.id).tag(model.id)
                    }
                    if !service.selectedModelID.isEmpty,
                        !service.models.contains(where: { $0.id == service.selectedModelID })
                    {
                        // Before the scan finishes the saved choice is unknown, not missing.
                        Text(
                            service.modelsLoaded
                                ? String(format: L("%@ — not on this Mac"), service.selectedModelID)
                                : service.selectedModelID
                        )
                        .tag(service.selectedModelID)
                    }
                } label: {
                    Text("Distributed Model", bundle: .module)
                }
                .labelsHidden()
                .accessibilityLabel(L("Distributed Model"))
                .settingsLandingAnchor("distributed.model")
            }
            if !service.modelsLoaded {
                DistributedLoadingRow(L("Looking for models on this Mac…"))
                if service.slowDiskReads {
                    DistributedNote(
                        L(
                            "Still reading the models folder. If macOS is asking whether Osaurus may access files on this drive, choose Allow."
                        ),
                        tone: .warn
                    )
                }
            } else if service.models.isEmpty {
                DistributedNote(
                    L("No models were found in this Mac’s Osaurus model folder or imported locations."),
                    tone: .warn
                )
            }
            DistributedRow(L("Models folder"), DirectoryPickerService.effectiveModelsDirectory().path)
            identity
            Text(
                "Every Mac must have this model in its own Osaurus model folder. Folders may differ between Macs; each Mac checks its own copy. Nothing is downloaded or converted automatically.",
                bundle: .module
            )
            .font(.system(size: 11)).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            Label(
                L("Start is unavailable in this preview: rank execution and sharding are not built yet."),
                systemImage: "info.circle"
            )
            .font(.system(size: 11)).foregroundStyle(theme.warningColor)
        }
    }

    @ViewBuilder private var identity: some View {
        switch service.identity {
        case .none:
            EmptyView()
        case .computing:
            DistributedLoadingRow(L("Checking this Mac’s copy of the model…"))
        case .unavailable:
            DistributedNote(
                L(
                    "This model is not in this Mac’s catalog. It may have been deleted, renamed, or be on a disconnected drive."
                ),
                tone: .bad
            )
        case .failed(_, let message):
            DistributedNote(String(format: L("This Mac’s copy cannot be used: %@"), message), tone: .bad)
        case .ready(_, let identity):
            DistributedRow(L("On this Mac"), identity.bundlePath)
            DistributedRow(L("Architecture"), DistributedText.architecture(identity.architecture))
            DistributedRow(L("Quantization"), DistributedText.quantization(identity.architecture))
            DistributedRow(
                L("Weights"),
                String(format: L("%lld shards · %@"), identity.shardCount, DistributedText.bytes(identity.weightBytes)),
                tone: identity.isComplete ? .good : .bad
            )
            if !identity.missingShards.isEmpty {
                DistributedRow(L("Missing shards"), identity.missingShards.joined(separator: ", "), tone: .bad)
            }
            if !identity.unreadableShards.isEmpty {
                DistributedRow(L("Unreadable shards"), identity.unreadableShards.joined(separator: ", "), tone: .bad)
            }
            DistributedRow(L("Bundle identity"), identity.shortFingerprint)
                .help(
                    L(
                        "Hash of config, generation defaults, tokenizer, chat template, quantization metadata, shard index and every shard's tensor header. Tensor bytes are not hashed."
                    )
                )
            ForEach([2, 4], id: \.self) { world in
                DistributedRow(
                    String(format: L("Head split · %lld Macs"), world),
                    DistributedText.divisibility(
                        TensorParallelDivisibility.check(identity.architecture, worldSize: world)
                    )
                )
            }
            DistributedRow(
                L("Per-Mac weights"),
                String(
                    format: L("About %@ on each of 2 Macs (estimate; excludes cache and activations)"),
                    DistributedText.bytes(identity.weightBytes / 2)
                )
            )
        }
    }
}

// MARK: - Setup

private struct DistributedSetupSection: View {
    @ObservedObject var service: DistributedPreviewService
    @ObservedObject var scanner: DistributedNodeScanner
    @ObservedObject var advertiser: DistributedNodeAdvertiser
    @Binding var showSetup: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSection(title: "Setup & Permissions", icon: "checklist", anchorId: "distributed.setup") {
            check(L("Thunderbolt cable to another Mac"), cable)
            check(L("RDMA over Thunderbolt"), rdma)
            check(L("Local Network access"), localNetwork)
            check(L("Osaurus on the other Macs"), peers)
            check(L("SSD cache location"), cacheCheck)
            Text(
                "Osaurus never enables RDMA, changes network settings, installs software or restarts your Mac for you. Use these buttons to open the right place, then refresh.",
                bundle: .module
            )
            .font(.system(size: 11)).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    showSetup = true
                } label: {
                    Text("Setup Guide", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle(isPrimary: true))
                .settingsLandingAnchor("distributed.guide")
                Button {
                    DistributedSystemLinks.open(DistributedSystemLinks.localNetwork)
                } label: {
                    Text("Open Privacy & Security", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                .settingsLandingAnchor("distributed.localNetwork")
                Button {
                    DistributedSystemLinks.open(DistributedSystemLinks.systemSettings)
                } label: {
                    Text("Open System Settings", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                .settingsLandingAnchor("distributed.systemSettings")
            }
            // macOS 27 has no public deep link to the Local Network pane (the
            // Privacy_LocalNetwork anchor lands on Privacy & Security), so say
            // where to go next rather than promise a pane we cannot open.
            Text("In Privacy & Security, choose Local Network and turn on Osaurus.", bundle: .module)
                .font(.system(size: 11)).foregroundStyle(theme.secondaryText)
            if let date = service.local?.capturedAt {
                Text(
                    String(
                        format: L("Last checked %@ · Refresh after changing system or storage settings."),
                        date.formatted(date: .omitted, time: .standard)
                    )
                )
                .font(.system(size: 10)).foregroundStyle(theme.tertiaryText)
            }
        }
    }

    private var cable: (String, DistributedTone) {
        guard let local = service.local else { return (L("Checking…"), .neutral) }
        let cabled = local.cabledMacs
        guard let first = cabled.first?.cabledMac else { return (L("No Mac cabled"), .bad) }
        let speed = cabled.first?.port.linkGbps.map { " · \($0) Gb/s" } ?? ""
        return (first.name + (first.model.map { " (\($0))" } ?? "") + speed, .good)
    }

    private var rdma: (String, DistributedTone) {
        guard let local = service.local else { return (L("Checking…"), .neutral) }
        switch local.rdma {
        case .enabled: return (L("Enabled"), .good)
        case .disabled: return (L("Disabled — enable it in macOS, then restart"), .bad)
        case .unsupported: return (L("Not available on this macOS version"), .bad)
        case .unknown(let text): return (String(format: L("Unknown (%@)"), text), .warn)
        }
    }

    private var localNetwork: (String, DistributedTone) {
        DistributedText.localNetwork(
            scan: scanner.phase,
            advertiser: advertiser.state,
            discoverable: advertiser.isEnabled,
            sawOwnAdvert: scanner.sawOwnAdvert,
            foundPeers: !scanner.nodes.isEmpty
        )
    }

    private var peers: (String, DistributedTone) {
        let verified = scanner.nodes.filter(\.isCableVerified).count
        if verified > 0 { return (String(format: L("%lld with a verified cable"), verified), .good) }
        if !scanner.nodes.isEmpty { return (L("Found, but none on your Thunderbolt cable"), .warn) }
        return (
            scanner.phase == .finished ? L("None found") : L("Not checked yet — run a scan"),
            scanner.phase == .finished ? .warn : .neutral
        )
    }

    private var cacheCheck: (String, DistributedTone) {
        guard let report = service.cache else { return (L("Checking…"), .neutral) }
        return (DistributedText.cacheState(report), DistributedText.cacheTone(report))
    }

    private func check(_ title: String, _ value: (String, DistributedTone)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: value.1.symbol).foregroundStyle(value.1.color(theme)).frame(width: 16)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.primaryText)
                .frame(width: 200, alignment: .leading)
            Text(value.0).font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.0)
    }
}

private struct DistributedSetupSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        let theme = themeManager.currentTheme
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect your Macs", bundle: .module).font(.system(size: 20, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                step(1, L("Install and open Osaurus on every Mac."))
                step(
                    2,
                    L("Connect the Macs directly with a Thunderbolt 5 cable. Docks and hubs cannot carry RDMA traffic.")
                )
                step(
                    3,
                    L(
                        "Enable RDMA over Thunderbolt on every Mac using Apple’s instructions for your macOS version, then restart when macOS asks."
                    )
                )
                step(
                    4,
                    L("Turn on Make This Mac Discoverable on every Mac and allow Local Network access when macOS asks.")
                )
                step(
                    5,
                    L(
                        "Put each Mac’s SSD cache on a connected SSD, and make sure every Mac has the same model in its own models folder."
                    )
                )
            }
            Text(
                "This preview does not install software, change networking, restart your Mac or start inference.",
                bundle: .module
            )
            .font(.system(size: 12)).foregroundStyle(theme.warningColor).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    DistributedSystemLinks.open(DistributedSystemLinks.appleRDMAGuide)
                } label: {
                    Text("Apple RDMA Instructions", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Text("Done", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(theme.primaryBackground)
        .foregroundStyle(theme.primaryText)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.system(size: 12, weight: .bold)).frame(width: 20, height: 20)
                .background(themeManager.currentTheme.accentColor.opacity(0.15), in: Circle())
            Text(text).font(.system(size: 13)).foregroundStyle(themeManager.currentTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Links and interface details

private struct DistributedLinkRow: View {
    let link: ThunderboltLinkSummary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(
                    systemName: link.cabledMac != nil || !link.port.devices.isEmpty
                        ? "cable.connector" : "cable.connector.slash"
                )
                .foregroundStyle(link.cabledMac != nil ? theme.successColor : theme.tertiaryText)
                .accessibilityHidden(true)
                Text(
                    [link.port.hardwarePortName ?? link.port.busName, link.interface].compactMap { $0 }.joined(
                        separator: " · "
                    )
                )
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primaryText)
                Spacer()
                Text(DistributedText.linkSpeed(link.port)).font(.system(size: 11)).foregroundStyle(theme.secondaryText)
            }
            Text(DistributedText.linkDetail(link)).font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(10)
        .background(theme.inputBackground, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [link.port.hardwarePortName ?? link.port.busName, link.interface].compactMap { $0 }.joined(separator: " · ")
        )
        .accessibilityValue(DistributedText.linkSpeed(link.port) + ". " + DistributedText.linkDetail(link))
    }
}

private struct DistributedInterfaceDetails: View {
    let local: DistributedLocalSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        Text(lines.joined(separator: "\n"))
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }

    private var lines: [String] {
        var lines = local.hardwarePorts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        lines.append(
            "Thunderbolt Bridge addresses: "
                + (local.bridgeAddresses.isEmpty ? "none" : local.bridgeAddresses.joined(separator: ", "))
        )
        for port in local.thunderboltPorts ?? [] {
            lines.append(
                "\(port.busName) domain \(port.ownDomainUUID ?? "unknown")"
                    + port.peers.map { " ↔ \($0.domainUUID)" }.joined()
            )
        }
        for device in local.rdmaDevices {
            lines.append("\(device.name): \(device.portState ?? "state unknown") \(device.linkLayer ?? "")")
        }
        return lines
    }
}

// MARK: - Shared presentation helpers

enum DistributedTone {
    case good, warn, bad, neutral

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .neutral: return "circle.dotted"
        }
    }

    func color(_ theme: ThemeProtocol) -> Color {
        switch self {
        case .good: return theme.successColor
        case .warn: return theme.warningColor
        case .bad: return theme.errorColor
        case .neutral: return theme.tertiaryText
        }
    }
}

enum DistributedSystemLinks {
    static let localNetwork = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    static let systemSettings = "x-apple.systempreferences:"
    static let appleRDMAGuide =
        "https://developer.apple.com/documentation/technotes/tn3205-low-latency-communication-with-rdma-over-thunderbolt"

    @MainActor static func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// User-facing wording, kept out of the views so it can be unit tested.
enum DistributedText {
    static func rdma(_ state: RDMAState) -> String {
        switch state {
        case .enabled: return L("RDMA enabled")
        case .disabled: return L("RDMA disabled")
        case .unsupported: return L("RDMA not available on this macOS")
        case .unknown: return L("RDMA state unknown")
        }
    }

    static func rdmaTone(_ state: RDMAState) -> DistributedTone {
        switch state {
        case .enabled: return .good
        case .disabled, .unsupported: return .bad
        case .unknown: return .warn
        }
    }

    /// Local Network access is only "Allowed" once something was actually seen
    /// on the network; an empty scan proves nothing (macOS silently holds
    /// browsing and publishing until the user answers its prompt).
    static func localNetwork(
        scan: DistributedNodeScanner.Phase,
        advertiser: DistributedNodeAdvertiser.State,
        discoverable: Bool,
        sawOwnAdvert: Bool,
        foundPeers: Bool
    ) -> (String, DistributedTone) {
        if scan == .failed(.localNetworkDenied) || advertiser == .failed(.localNetworkDenied)
            || advertiser == .notVisible || (scan == .finished && discoverable && !sawOwnAdvert && !foundPeers)
        {
            return (L("Not allowed — allow Osaurus in Local Network settings"), .bad)
        }
        if advertiser.isAdvertising || sawOwnAdvert || foundPeers { return (L("Allowed"), .good) }
        return (L("Not confirmed — turn on Make This Mac Discoverable"), .neutral)
    }

    static func linkSpeed(_ port: ThunderboltPort) -> String {
        if let gbps = port.linkGbps { return String(format: L("%lld Gb/s link"), gbps) }
        return port.connected ? (port.speed ?? L("Connected")) : L("Nothing connected")
    }

    static func linkDetail(_ link: ThunderboltLinkSummary) -> String {
        var parts: [String] = []
        if let mac = link.cabledMac {
            parts.append(String(format: L("Cabled to %@"), mac.name + (mac.model.map { " (\($0))" } ?? "")))
            if mac.offersIPService { parts.append(L("Thunderbolt networking offered")) }
        } else if !link.port.devices.isEmpty {
            parts.append(
                String(format: L("Devices: %@ — not a Mac-to-Mac link"), link.port.devices.joined(separator: ", "))
            )
        } else {
            parts.append(link.port.connected ? L("Connected, no Mac reported") : L("No cable"))
        }
        if let device = link.rdmaDevice {
            parts.append("\(device.name) \(device.portState ?? L("state unknown"))")
        } else if link.cabledMac != nil {
            parts.append(L("No RDMA device for this port"))
        }
        parts.append(link.addresses.isEmpty ? L("No IP address") : link.addresses.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    static func interfaces(_ names: [String], ports: [String: String]) -> String {
        guard !names.isEmpty else { return L("Unknown interface") }
        let byDevice = Dictionary(ports.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        return names.map { name in byDevice[name].map { "\($0) (\(name))" } ?? name }.joined(separator: ", ")
    }

    static func modelMatch(_ match: DiscoveredNode.ModelMatch) -> String {
        switch match {
        case .sameBundle: return L("Same model bundle (unauthenticated advertisement)")
        case .differentBundle: return L("Same model name, different files — cannot be used together")
        case .unverified: return L("Same model name — bundle identity not yet reported")
        case .differentModel(let other): return String(format: L("Selected a different model: %@"), other)
        case .peerHasNoSelection: return L("No model selected on that Mac")
        case .noLocalSelection: return L("Select a model on this Mac to compare")
        }
    }

    static func architecture(_ a: DistributedModelIdentity.Architecture) -> String {
        var parts = [[a.modelType, a.textModelType].compactMap { $0 }.joined(separator: " / ")]
        if let heads = a.attentionHeads, let kv = a.keyValueHeads {
            parts.append(String(format: L("%lld attention / %lld KV heads"), heads, kv))
        }
        if let experts = a.experts { parts.append(String(format: L("%lld experts"), experts)) }
        if let layers = a.layers { parts.append(String(format: L("%lld layers"), layers)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func quantization(_ a: DistributedModelIdentity.Architecture) -> String {
        let groups = a.bitGroups.map { "\($0.bits)-bit/g\($0.groupSize)" }.joined(separator: ", ")
        let text = [a.quantFormat, groups.isEmpty ? nil : groups].compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? L("Not declared (unquantized or unknown)") : text
    }

    static func divisibility(_ check: TensorParallelDivisibility) -> String {
        switch check.verdict {
        case .divides: return L("Heads divide evenly")
        case .needsKVReplication: return L("Attention heads divide; KV heads must be replicated")
        case .indivisible(let what): return String(format: L("Does not divide: %@"), what)
        case .unknown(let why): return String(format: L("Cannot check: %@"), why)
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Cache sizes use the Server cache section's formatter so both screens
    /// show the same number for the same bytes (GiB, labelled "GB" there).
    static func cacheBytes(_ free: Int64?, of total: Int64?) -> String {
        guard let free else { return L("Unknown") }
        let freeText = DiskCacheUsage.format(bytes: Int(clamping: free))
        guard let total else { return freeText }
        return String(format: L("%@ of %@"), freeText, DiskCacheUsage.format(bytes: Int(clamping: total)))
    }

    static func quota(_ resolution: DiskCacheCapPolicy.Resolution?) -> String {
        guard let resolution else { return L("Unknown") }
        let effective = DiskCacheUsage.format(bytes: Int(clamping: resolution.capBytes))
        switch resolution.rule {
        case .automatic: return String(format: L("%@ (automatic)"), effective)
        case .explicitPercent: return String(format: L("%@ (percent of disk)"), effective)
        case .legacyGB: return String(format: L("%@ (saved size)"), effective)
        case .unknownVolume: return String(format: L("%@ (fallback — disk size unknown)"), effective)
        }
    }

    static func device(_ disk: CacheDiskFacts) -> String {
        var parts: [String] = []
        if let device = disk.physicalDevice { parts.append(device) }
        if let media = disk.mediaName { parts.append(media) }
        if let bus = disk.busProtocol { parts.append(bus) }
        if let isInternal = disk.isInternal { parts.append(isInternal ? L("Internal") : L("External")) }
        return parts.isEmpty ? L("Unknown device") : parts.joined(separator: " · ")
    }

    static func medium(_ disk: CacheDiskFacts) -> String {
        if disk.isNetwork { return L("Network volume — use a local SSD") }
        switch disk.medium {
        case .solidState: return L("SSD")
        case .rotational: return L("Rotational disk — use an SSD")
        case .unknown: return L("Not reported by macOS")
        }
    }

    static func cacheState(_ report: CacheVolumeReport) -> String {
        switch report.state {
        case .present:
            return report.reuseEnabled
                ? L("Cache folder is ready on this volume.") : L("Cache folder exists, but disk reuse is off.")
        case .notCreated where !report.reuseEnabled:
            return L("Disk reuse is off in Server settings, so nothing is written here until it is turned on.")
        case .notCreated(let root):
            return String(
                format: L("Folder not created yet; the runtime creates it on %@ when it first saves."),
                report.disk?.volumeName ?? root
            )
        case .volumeMissing(let mount):
            return String(
                format: L(
                    "%@ is not connected. Nothing is written until it is reconnected; the cache does not move to another disk."
                ),
                mount
            )
        case .danglingSymlink(let link, let target):
            return String(format: L("%@ points to %@, which does not exist."), link, target)
        case .unreadable(let message):
            return message
        }
    }

    static func reuseTone(_ report: CacheVolumeReport) -> DistributedTone {
        switch report.state {
        case .present, .notCreated: return report.reuseEnabled ? .good : .warn
        case .volumeMissing, .danglingSymlink, .unreadable: return .warn
        }
    }

    static func cacheTone(_ report: CacheVolumeReport) -> DistributedTone {
        switch report.state {
        case .present: return report.reuseEnabled ? .good : .warn
        case .notCreated: return .neutral
        case .volumeMissing, .danglingSymlink, .unreadable: return .bad
        }
    }
}

private struct DistributedRow: View {
    let label: String
    let value: String
    var tone: DistributedTone = .neutral
    @Environment(\.theme) private var theme

    init(_ label: String, _ value: String, tone: DistributedTone = .neutral) {
        self.label = label
        self.value = value
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(theme.secondaryText).frame(width: 140, alignment: .leading)
            if tone != .neutral {
                Image(systemName: tone.symbol).font(.system(size: 10)).foregroundStyle(tone.color(theme))
                    .accessibilityHidden(true)
            }
            Text(value).foregroundStyle(theme.primaryText).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        // `.combine` drops selectable text, so VoiceOver heard only the label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

private struct DistributedNote: View {
    let text: String
    let tone: DistributedTone
    @Environment(\.theme) private var theme

    init(_ text: String, tone: DistributedTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .neutral ? "info.circle" : tone.symbol)
                .foregroundStyle(tone == .neutral ? theme.secondaryText : tone.color(theme))
                .accessibilityHidden(true)
            Text(text).font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

private struct DistributedPill: View {
    let text: String
    let tone: DistributedTone
    @Environment(\.theme) private var theme

    init(_ text: String, tone: DistributedTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(tone.color(theme))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tone.color(theme).opacity(0.12), in: Capsule())
    }
}

private struct DistributedPath: View {
    let path: String
    @Environment(\.theme) private var theme

    init(_ path: String) { self.path = path }

    var body: some View {
        Text(path)
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.primaryText)
            .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(theme.inputBackground, in: RoundedRectangle(cornerRadius: 8))
        // No .accessibilityLabel here: overriding the label of selectable text
        // makes SwiftUI's label resolution recurse between the node and its
        // platform text element until the main thread's stack overflows
        // (reproduced by walking this window's AX tree, macOS 27.0).
    }
}

private struct DistributedLoadingRow: View {
    let text: String
    @Environment(\.theme) private var theme

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(theme.secondaryText)
        }
    }
}
