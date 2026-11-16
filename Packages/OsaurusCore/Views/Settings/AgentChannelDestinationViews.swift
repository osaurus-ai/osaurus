//
//  AgentChannelDestinationViews.swift
//  osaurus
//
//  Settings UI for proactive agent destinations (outbound bindings) and
//  the outbound outbox (drafts, pending approvals, sent items, failures).
//

import SwiftUI

// MARK: - Connection Presentation Helpers

/// Provider identity for a destination's connection id: native providers
/// map to their brand, custom connections resolve through the manager.
@MainActor
enum AgentChannelConnectionPresentation {
    static func kind(for connectionId: String) -> AgentChannelKind {
        if let account = ChannelAccounts.account(connectionId: connectionId) { return account.kind }
        switch connectionId.lowercased() {
        case AgentChannelConnection.nativeDiscordConnectionId: return .discord
        case AgentChannelConnection.nativeSlackConnectionId: return .slack
        case AgentChannelConnection.nativeTelegramConnectionId: return .telegram
        case AgentChannelConnection.nativeIMessageConnectionId: return .imessage
        case AgentChannelConnection.nativeWhatsAppConnectionId: return .whatsapp
        case AgentChannelConnection.nativeEmailConnectionId: return .email
        default:
            return AgentChannelConnectionManager.shared.connection(id: connectionId)?.kind
                ?? .customHTTP
        }
    }

    static func displayName(for connectionId: String) -> String {
        if let name = ChannelAccounts.displayName(connectionId: connectionId) { return name }
        switch connectionId.lowercased() {
        case AgentChannelConnection.nativeDiscordConnectionId: return "Discord"
        case AgentChannelConnection.nativeSlackConnectionId: return "Slack"
        case AgentChannelConnection.nativeTelegramConnectionId: return "Telegram"
        case AgentChannelConnection.nativeIMessageConnectionId: return "iMessage"
        case AgentChannelConnection.nativeWhatsAppConnectionId: return "WhatsApp"
        case AgentChannelConnection.nativeEmailConnectionId: return "Email"
        default:
            let connection = AgentChannelConnectionManager.shared.connection(id: connectionId)
            guard let connection, !connection.name.isEmpty else { return connectionId }
            return connection.name
        }
    }
}

// MARK: - Default agent posting sheet

/// The Default agent's posting places, hosted in a sheet because the
/// built-in agent has no detail page of its own.
struct AgentChannelDefaultAgentPostingSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            HStack {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(AgentManager.shared.agent(for: Agent.defaultId)?.name ?? L("Default"))
                        .font(SettingsFont.detailTitle)
                        .foregroundColor(theme.text.primary)
                    Text("Where this agent may post on its own", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                }
                Spacer()
                SettingsIconButton("xmark", help: "Close", size: .compact) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s16)
            .background(theme.surface.subtle)

            ScrollView {
                AgentChannelAgentDestinationsSection(agentId: Agent.defaultId, showsChannelsLink: false)
                    .padding(theme.space.s24)
            }
        }
        .fittedSheetFrame(width: 560, height: 520)
        .background(theme.surface.canvas)
    }
}

/// Plain-language naming for outbound modes, used by every destination
/// surface. Storage/tool/raw values stay untouched — this is UI copy only.
extension AgentChannelBindingOutboundMode {
    var friendlyLabel: String {
        switch self {
        case .off: return L("Off")
        case .draft: return L("Drafts only")
        case .confirm: return L("Ask first")
        case .autonomous: return L("Auto-send")
        }
    }

    var friendlyDescription: String {
        switch self {
        case .off:
            return L("The agent cannot post here.")
        case .draft:
            return L("The agent writes drafts for you; nothing is ever sent.")
        case .confirm:
            return L("Every post waits for your approval first.")
        case .autonomous:
            return L("The agent posts without asking.")
        }
    }
}

// MARK: - Shared destination row

/// One destination as a card: where the agent can post, how it behaves
/// (inline plain-language mode menu), and a Customize entry point for the
/// full editor. Used by the per-agent section (Agents → agent → Channels).
///
/// Rows read name-first ("#content", a person's name) with provider
/// branding; the raw provider route stays available as a tooltip and in
/// the editor rather than leading the row.
///
/// Changing the mode persists immediately. On an AUTOMATIC (derived) row
/// this materializes a stored binding for the same route, which then
/// suppresses the derived one — operator customization always wins.
/// Switching to Auto-send always interposes an explicit confirmation.
struct AgentChannelDestinationRowCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var roomDirectory = AgentChannelRoomDirectory.shared

    let binding: AgentChannelBinding
    /// Derived from the channel setup rather than stored configuration.
    let isAutomatic: Bool
    let showAgentName: Bool
    let onCustomize: () -> Void
    let onChanged: () -> Void

    @State private var pendingAutonomousConfirm = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var effectiveMode: AgentChannelBindingOutboundMode {
        binding.enabled ? binding.outboundMode : .off
    }

    private var connectionKind: AgentChannelKind {
        AgentChannelConnectionPresentation.kind(for: binding.connectionId)
    }

    private var presentation: AgentChannelDestinationPresentation {
        AgentChannelDestinationPresentation.make(
            binding: binding,
            descriptor: roomDirectory.descriptor(
                connectionId: binding.connectionId,
                roomId: binding.roomId
            ),
            providerName: AgentChannelConnectionPresentation.displayName(for: binding.connectionId),
            agentName: showAgentName
                ? (AgentManager.shared.agent(for: binding.agentId)?.name ?? L("Unknown agent"))
                : nil
        )
    }

    var body: some View {
        let presentation = self.presentation
        return HStack(spacing: theme.space.s10) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        LinearGradient(
                            colors: connectionKind.brandGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: connectionKind.icon)
                    .glyphSize(.label, weight: .semibold)
                    .foregroundColor(FixedPalette.onMedia)
            }
            .frame(width: 32, height: 32)
            .opacity(binding.isUsable ? 1 : 0.5)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(presentation.title)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .help(presentation.technicalRoute)
                    if let typeBadge = presentation.typeBadge {
                        StatusChip(typeBadge, tone: .neutral)
                    }
                    if isAutomatic {
                        StatusChip(L("Automatic"), tint: theme.text.secondary)
                            .help(
                                L(
                                    "Added because an automation runs this agent for this channel and the room allows bot posts. No setup needed."
                                )
                            )
                    }
                }
                Text(presentation.subtitle)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
                    .help(presentation.technicalRoute)
                Text(effectiveMode.friendlyDescription)
                    .font(SettingsFont.footnote)
                    .foregroundColor(
                        effectiveMode == .autonomous ? theme.status.warning.foreground : theme.text.tertiary
                    )
            }

            Spacer()

            modeMenu

            Button {
                onCustomize()
            } label: {
                Text("Customize…", bundle: .module)
                    .font(SettingsFont.smallLabel)
            }
            .assignedSettingsButtonStyle()
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.surface)
        // Window-level modal: a contained overlay would center inside this
        // one row and clip/z-fight against sibling rows in the scroll view.
        .themedAlert(
            L("Let the agent post without asking?"),
            isPresented: $pendingAutonomousConfirm,
            message: L(
                "The agent will send messages to \(presentation.title) on its own, without a confirmation from you. Room allowlists, rate limits, and the global Sending switch still apply."
            ),
            primaryButton: .primary(L("Allow Auto-send")) { persist(mode: .autonomous) },
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .window
        )
    }

    private var modeMenu: some View {
        HStack(spacing: theme.space.s6) {
            if effectiveMode == .autonomous {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(SettingsFont.glyphSmall)
                    .foregroundColor(theme.status.warning.foreground)
            }
            SettingsMenuPicker(selection: Binding(get: { effectiveMode }, set: { select($0) })) {
                ForEach(AgentChannelBindingOutboundMode.allCases, id: \.self) { mode in
                    Text(mode.friendlyLabel).tag(mode)
                }
            }
        }
    }

    private func select(_ mode: AgentChannelBindingOutboundMode) {
        guard mode != effectiveMode || !binding.enabled else { return }
        if mode == .autonomous {
            pendingAutonomousConfirm = true
        } else {
            persist(mode: mode)
        }
    }

    private func persist(mode: AgentChannelBindingOutboundMode) {
        var updated = binding
        updated.outboundMode = mode
        // A quick mode change also re-enables a row that was left disabled:
        // in this simplified control "Off" IS the disabled state.
        updated.enabled = true
        do {
            try AgentChannelConnectionManager.shared.upsertBinding(
                updated,
                replacingOriginalId: isAutomatic ? nil : binding.id
            )
            onChanged()
        } catch {
            _ = ToastManager.shared.error(
                L("Couldn't update this place"),
                message: error.localizedDescription
            )
        }
    }
}

// MARK: - Per-Agent "On channels" (Agent Settings)

/// Read-only list of the channels ONE agent takes part in — whether it
/// answers messages, replies automatically, and may post on its own —
/// embedded in that agent's Channels tab. All of it is edited on the
/// channel (Routing and Sending in its sheet), so each row deep-links there.
struct AgentChannelAgentOnChannelsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let agentId: UUID

    @State private var rows: [Row] = []

    struct Row: Identifiable {
        let connectionId: String
        let kind: AgentChannelKind
        let name: String
        let detail: String
        var id: String { connectionId }
    }

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            if rows.isEmpty {
                Text(
                    "This agent isn't on any channel yet. Open a channel under Channels and add it there.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: theme.space.s8) {
                    ForEach(rows) { row in
                        channelRow(row)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    AppDelegate.shared?.showManagementWindow(initialTab: .agentChannels)
                } label: {
                    HStack(spacing: theme.space.s4) {
                        Text("Open Channels", bundle: .module)
                        Image(systemName: "arrow.up.right")
                            .glyphSize(.tiny, weight: .semibold)
                    }
                    .textStyle(.footnote, weight: 500)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(theme.text.link)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .eventsChanged).receive(on: DispatchQueue.main)) { _ in
            reload()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .agentChannelConfigurationChanged).receive(on: DispatchQueue.main)
        ) { _ in reload() }
    }

    private func channelRow(_ row: Row) -> some View {
        HStack(spacing: theme.space.s10) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        LinearGradient(
                            colors: row.kind.brandGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: row.kind.icon)
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(FixedPalette.onMedia)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(row.name)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(row.detail)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                ManagementStateManager.shared.pendingChannelConnectionId = row.connectionId
                AppDelegate.shared?.showManagementWindow(initialTab: .agentChannels)
            } label: {
                HStack(spacing: theme.space.s4) {
                    Text("Edit in Channels", bundle: .module)
                    Image(systemName: "arrow.up.right")
                        .glyphSize(.tiny, weight: .semibold)
                }
                .textStyle(.footnote, weight: 500)
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(theme.text.link)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.surface)
    }

    /// Every connection the agent is on: any with an automation or a
    /// posting place for it, in the order Channels lists them.
    private func reload() {
        let events = EventManager.shared.events
        let bindings = AgentChannelAutoDestinationResolver.effectiveConfiguration().bindings
        var ids: [String] = []
        var seen = Set<String>()
        func note(_ id: String) {
            let normalized = AgentChannelConnection.normalizedId(id)
            if seen.insert(normalized).inserted { ids.append(normalized) }
        }
        for event in events {
            guard let source = event.source.channelMessage,
                ChannelAgentRoster.target(of: event)?.localAgentId == agentId
            else { continue }
            note(source.connectionId)
        }
        for binding in bindings where binding.agentId == agentId {
            note(binding.connectionId)
        }
        rows = ids.compactMap { connectionId in
            let kind = AgentChannelConnectionPresentation.kind(for: connectionId)
            let roster = ChannelAgentRoster.build(
                events: events.filter { $0.source.channelMessage?.connectionId == connectionId },
                bindings: bindings,
                connectionId: connectionId,
                writableRoomIds: ChannelAgentRoster.liveWritableRoomIds(connectionId: connectionId)
            )
            guard
                let detail = roster.presenceDetail(
                    for: agentId, roomName: ChannelRoomChoices.labeler(connectionId: connectionId))
            else { return nil }
            return Row(
                connectionId: connectionId, kind: kind,
                name: AgentChannelConnectionPresentation.displayName(for: connectionId), detail: detail)
        }
    }
}

// MARK: - Per-Agent Destinations (Agent Settings)

/// Places ONE agent may post on its own, embedded in that agent's settings
/// (Agents → agent → Channels) next to the read-only Replies summary. This
/// is the only editor for posting places; the Channels pane summarizes
/// them per agent and links here.
struct AgentChannelAgentDestinationsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let agentId: UUID
    var showsChannelsLink = true

    @State private var bindings: [AgentChannelBinding] = []
    @State private var storedBindingIds: Set<String> = []
    @State private var sheetTarget: SheetTarget?

    private enum SheetTarget: Identifiable {
        case add
        case edit(AgentChannelBinding)

        var id: String {
            switch self {
            case .add: return "destination-new"
            case .edit(let binding): return "destination-\(binding.id)"
            }
        }
    }

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var autonomousCount: Int {
        bindings.filter { $0.isUsable && $0.outboundMode == .autonomous }.count
    }

    private var sendingPaused: Bool {
        !ChannelWriteKillSwitch.shared.snapshot().writeEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            if sendingPaused && !bindings.isEmpty {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "pause.circle.fill")
                        .glyphSize(.footnote)
                    Text(
                        "Sending is paused by the global switch in Channels settings — nothing is delivered from these destinations until it's back on.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(theme.status.warning.foreground)
            }

            if bindings.isEmpty {
                Text(
                    "Nowhere to post yet. A place appears here automatically when an automation runs this agent for a room the bot may post in — the agent then always asks before sending. You can also add a specific place below.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: theme.space.s8) {
                    ForEach(bindings) { binding in
                        AgentChannelDestinationRowCard(
                            binding: binding,
                            isAutomatic: !storedBindingIds.contains(binding.id),
                            showAgentName: false,
                            onCustomize: { sheetTarget = .edit(binding) },
                            onChanged: reload
                        )
                    }
                }
            }

            if autonomousCount > 0 {
                Text(
                    "\(autonomousCount) destination(s) are set to Auto-send: this agent posts there without asking.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.status.warning.foreground)
            }

            HStack {
                Button {
                    sheetTarget = .add
                } label: {
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: "plus")
                            .glyphSize(.tiny, weight: .semibold)
                        Text("Add Place", bundle: .module)
                    }
                }
                .assignedSettingsButtonStyle()

                Spacer()

                // Channel connections, the outbox, and the global write kill
                // switch are cross-agent concerns and stay in the Channels pane.
                if showsChannelsLink {
                    Button {
                        ManagementStateManager.shared.selectedTab = .agentChannels
                    } label: {
                        HStack(spacing: theme.space.s4) {
                            Text("Channels & Outbox settings", bundle: .module)
                            Image(systemName: "arrow.up.right")
                                .glyphSize(.tiny, weight: .semibold)
                        }
                        .textStyle(.footnote, weight: 500)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(theme.text.link)
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $sheetTarget, onDismiss: reload) { target in
            Group {
                switch target {
                case .add:
                    AgentChannelDestinationEditorSheet(binding: nil, pinnedAgentId: agentId) {
                        reload()
                    }
                case .edit(let binding):
                    AgentChannelDestinationEditorSheet(binding: binding, pinnedAgentId: agentId) {
                        reload()
                    }
                }
            }
            .themedAlertSheetHost()
        }
    }

    private func reload() {
        let stored = AgentChannelConnectionManager.shared.loadConfiguration().bindings
        storedBindingIds = Set(stored.map(\.id))
        bindings = AgentChannelAutoDestinationResolver.effectiveConfiguration()
            .bindings(agentId: agentId)
            .sorted {
                $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel)
                    == .orderedAscending
            }
        AgentChannelRoomDirectory.shared.prepare(connectionIds: bindings.map(\.connectionId))
    }
}

// MARK: - Destination Editor Sheet

struct AgentChannelDestinationEditorSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Existing binding to edit, or nil to create a new one.
    let binding: AgentChannelBinding?
    /// When set (the sheet was opened from one agent's own settings), the
    /// destination belongs to this agent and the agent picker is replaced
    /// with a static row — the agent's identity is not an editable field of
    /// somebody else's configuration surface.
    var pinnedAgentId: UUID? = nil
    let onDidChange: () -> Void

    @State private var bindingId = ""
    @State private var agentId: UUID = Agent.defaultId
    @State private var connectionId = AgentChannelConnection.nativeDiscordConnectionId
    @State private var roomId = ""
    @State private var threadId = ""
    @State private var label = ""
    @State private var guidance = ""
    @State private var outboundMode: AgentChannelBindingOutboundMode = .confirm
    // Every run kind by default, matching automatic destinations: ask-first
    // mode keeps a human on each send regardless of what triggered the run.
    @State private var allowedSources: Set<AgentChannelBindingRunSource> = Set(
        AgentChannelBindingRunSource.allCases
    )
    @State private var maxSendsPerHour = AgentChannelBindingRatePolicy.defaultMaxSendsPerHour
    @State private var minSecondsBetweenSends =
        AgentChannelBindingRatePolicy.defaultMinSecondsBetweenSends
    @State private var enabled = true
    @State private var autonomousAcknowledged = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var showDeleteConfirmation = false
    @State private var discoveredRooms: [DiscoveredRoom] = []
    @State private var isDiscoveringRooms = false
    @State private var roomQuery = ""

    private struct DiscoveredRoom: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: AgentChannelRoomKind
        let writeAllowed: Bool
    }

    private let manager = AgentChannelConnectionManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }
    private var isNew: Bool { binding == nil }
    /// Whether the row being edited exists in stored configuration. An
    /// AUTOMATIC (derived) row opens in this editor too; saving it
    /// materializes a stored customization, and there is nothing to delete.
    private var isStoredBinding: Bool {
        guard let binding else { return false }
        return manager.binding(id: binding.id) != nil
    }
    /// A stored customization of an automatic route: deleting it reverts
    /// the room to its automatic ask-first behavior instead of removing it.
    private var deleteRevertsToAutomatic: Bool {
        guard let binding else { return false }
        return AgentChannelAutoDestinationResolver.isAutomaticBindingId(binding.id)
    }

    private var connectionOptions: [String] {
        var options = [AgentChannelKind.discord, .slack, .telegram].flatMap {
            ChannelAccounts.accounts(kind: $0).map(\.connectionId)
        }
        options += [
            AgentChannelConnection.nativeIMessageConnectionId,
            AgentChannelConnection.nativeWhatsAppConnectionId,
        ]
        options.append(contentsOf: manager.editableConnections().map(\.id))
        if !options.contains(connectionId) {
            options.append(connectionId)
        }
        return options
    }

    /// Provider kind for the selected connection, driving the brand tile in
    /// the header and the room-row icon — the same visual identity used by
    /// the channel cards and setup sheets.
    private var connectionKind: AgentChannelKind {
        AgentChannelConnectionPresentation.kind(for: connectionId)
    }

    private func connectionDisplayName(_ id: String) -> String {
        AgentChannelConnectionPresentation.displayName(for: id)
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s20) {
                    identitySection
                    destinationSection
                    behaviorSection
                    advancedSection
                    readinessSection
                }
                .padding(theme.space.s24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .fittedSheetFrame(width: 560, height: 680)
        .background(theme.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge)
                .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
        )
        .onAppear {
            loadDraft()
            // Room discovery is the primary way to pick a room — run it
            // up front so the picker is ready instead of hiding behind a
            // "Find Rooms" click.
            discoverRooms()
        }
        // Material route/identity change on an existing binding: autonomous
        // mode must be re-acknowledged for the NEW destination — the old
        // acknowledgement approved a different route.
        .onChange(of: connectionId) { _ in
            discoveredRooms = []
            roomQuery = ""
            resetAutonomousAckForRouteChange()
            discoverRooms()
        }
        .onChange(of: roomId) { _ in resetAutonomousAckForRouteChange() }
        .onChange(of: threadId) { _ in resetAutonomousAckForRouteChange() }
        .onChange(of: agentId) { _ in resetAutonomousAckForRouteChange() }
        .themedAlert(
            deleteRevertsToAutomatic ? L("Reset this room?") : L("Remove this room?"),
            isPresented: $showDeleteConfirmation,
            message: deleteRevertsToAutomatic
                ? L(
                    "Your customization is removed. If the room is still writable and this agent still answers there, it returns to Automatic — the agent asks before every post."
                )
                : L(
                    "The agent can no longer post here on its own. Waiting or drafted posts for this room can no longer be sent."
                ),
            primaryButton: .destructive(
                deleteRevertsToAutomatic ? L("Reset") : L("Remove")
            ) { performDelete() },
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
    }

    private var header: some View {
        HStack(spacing: theme.space.s12) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        LinearGradient(
                            colors: connectionKind.brandGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: connectionKind.icon)
                    .glyphSize(.large, weight: .semibold)
                    .foregroundColor(FixedPalette.onMedia)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(isNew ? L("Add a Place") : L("Customize Place"))
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
                Text(
                    "Choose where this agent may post on its own, and whether it asks you first.",
                    bundle: .module
                )
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
            }

            Spacer()

            SettingsIconButton("xmark", help: "Close", size: .compact) { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
        .background(theme.surface.subtle)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            fieldLabel(L("Agent"))
            if pinnedAgentId != nil {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "person.crop.circle")
                        .glyphSize(.caption)
                        .foregroundColor(theme.text.secondary)
                    Text(agentDisplayName(agentId))
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                }
            } else {
                SettingsMenuPicker(selection: $agentId) {
                    ForEach(agentManager.agents, id: \.id) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                .frame(maxWidth: 280, alignment: .leading)
            }

            fieldLabel(L("Name (optional)"))
            styledTextField(L("Team standup channel"), text: $label)
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            fieldLabel(L("Channel"))
            SettingsMenuPicker(selection: $connectionId) {
                ForEach(connectionOptions, id: \.self) { option in
                    Text(connectionDisplayName(option)).tag(option)
                }
            }
            .frame(maxWidth: 280, alignment: .leading)

            fieldLabel(
                L("Conversation"),
                hint: L("Where the agent posts. The bot must be allowed to post there.")
            )
            roomSelector

            fieldLabel(
                L("When to use"),
                hint: L("Tell the agent when posting here is appropriate.")
            )
            styledTextEditor(
                L("e.g. Share daily status updates and important findings here."),
                text: $guidance
            )
        }
    }

    /// Room picker following the same discovery-selector pattern as the
    /// channel setup sheets (search field above a selectable list card):
    /// discovery runs automatically, writable rooms are selectable, and
    /// rooms without posting access are shown but disabled so the user
    /// learns where to fix it. Direct id entry lives under Advanced.
    @ViewBuilder
    private var roomSelector: some View {
        if isDiscoveringRooms && discoveredRooms.isEmpty {
            HStack(spacing: theme.space.s8) {
                SettingsSpinner()
                Text("Finding conversations…", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.space.s24)
            .settingsChrome(.surface)
        } else if discoveredRooms.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("No conversations found on this channel yet.", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                Text(
                    "Check the channel's settings, or enter a conversation id directly under Advanced.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    discoverRooms()
                } label: {
                    Text("Try Again", bundle: .module)
                }
                .assignedSettingsButtonStyle()
                .disabled(isDiscoveringRooms)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.space.s12)
            .settingsChrome(.surface)
        } else {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                AgentChannelSelectorSearchField(
                    placeholder: L("Search conversations"),
                    text: $roomQuery
                )
                AgentChannelSelectorListCard(
                    shaped: shapedRooms,
                    emptyText: L("No matching conversations"),
                    maxHeight: 190
                ) { item in
                    roomRow(item.entry, selected: item.state)
                }
                if discoveredRooms.contains(where: { !$0.writeAllowed }) {
                    Text(
                        "Grayed-out conversations don't allow bot posts yet — enable posting for them in the channel's settings.",
                        bundle: .module
                    )
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !roomId.isEmpty, !discoveredRooms.contains(where: { $0.id == roomId }) {
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: "info.circle")
                            .glyphSize(.micro)
                        Text(L("Currently set to \(roomId) (not in this list)"))
                            .font(SettingsFont.monoSmall)
                    }
                    .foregroundColor(theme.text.tertiary)
                }
            }
        }
    }

    private var shapedRooms: AgentChannelSelectorList.Shaped<DiscoveredRoom, Bool> {
        AgentChannelSelectorList.shape(
            discoveredRooms,
            query: roomQuery,
            fields: { [$0.name, $0.id] },
            state: { $0.id == roomId },
            isSelected: { $0 }
        )
    }

    private func roomRow(_ room: DiscoveredRoom, selected: Bool) -> some View {
        let displayName =
            room.name != room.id && room.kind.usesHashPrefix && !room.name.hasPrefix("#")
            ? "#\(room.name)" : room.name
        return Button {
            roomId = room.id
            if label.isEmpty { label = room.name }
        } label: {
            HStack(spacing: theme.space.s8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .glyphSize(.label, weight: .semibold)
                    .foregroundColor(selected ? theme.text.link : theme.text.tertiary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    HStack(spacing: theme.space.s4) {
                        Text(displayName)
                            .font(SettingsFont.smallLabel)
                            .foregroundColor(
                                room.writeAllowed ? theme.text.primary : theme.text.tertiary
                            )
                            .lineLimit(1)
                        if let badge = room.kind.badgeLabel {
                            StatusChip(badge, tone: .neutral)
                        }
                    }
                    Text(room.id)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if !room.writeAllowed {
                    StatusChip(L("Posting not allowed"), tone: .neutral)
                }
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!room.writeAllowed)
        .opacity(room.writeAllowed ? 1 : 0.55)
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            fieldLabel(L("When the agent wants to post"))
            AssignedBaseSegmentedPicker(
                selection: $outboundMode,
                options: AgentChannelBindingOutboundMode.allCases.map { .init($0, $0.friendlyLabel, verbatim: true) }
            )
            .fixedSize()
            .accessibilityLabel(Text(verbatim: L("When the agent wants to post")))

            Text(modeDescription)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if outboundMode == .autonomous {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    HStack(spacing: theme.space.s8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .glyphSize(.caption)
                            .foregroundColor(theme.status.warning.foreground)
                        Text(
                            "Auto-send lets this agent post messages without asking you. Room permissions, rate limits, and the global Sending switch still apply.",
                            bundle: .module
                        )
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.status.warning.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle(isOn: $autonomousAcknowledged) {
                        Text("I understand this agent can post here without asking", bundle: .module)
                            .font(SettingsFont.rowDescription)
                    }
                    .settingsCheckbox()
                }
                .padding(theme.space.s8)
                .settingsChrome(.status(.warning))
            }

            // Only surfaced when this row arrived disabled (a deleted
            // channel's cascade, or an imported configuration): the operator
            // must explicitly reactivate it. New rows are simply active, and
            // "Off" mode covers the everyday disable case.
            if binding?.enabled == false {
                Toggle(isOn: $enabled) {
                    Text("Active", bundle: .module)
                        .font(SettingsFont.caption)
                }
                .settingsSwitch(showsLabel: true)
                Text(
                    "This room was turned off — for example its channel was removed, or it arrived from an imported file. Turn it back on to use it again.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeDescription: String {
        switch outboundMode {
        case .off:
            return L("The room stays listed, but the agent can't post to it.")
        case .draft:
            return L("The agent writes drafts for your review; nothing is ever sent.")
        case .confirm:
            return L(
                "In chat, you get an approval card before anything is sent. For scheduled runs, posts wait in the Outbox for your approval."
            )
        case .autonomous:
            return L("The agent posts directly, within the rate limits under Advanced.")
        }
    }

    /// Everything a non-technical user never needs: thread pinning, which
    /// kinds of runs may post, rate limits, and (when editing) the stable
    /// reference id the agent uses. All have safe defaults.
    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            VStack(alignment: .leading, spacing: theme.space.s14) {
                fieldLabel(
                    L("Room ID"),
                    hint: L("Set the room directly if it doesn't appear in the list above.")
                )
                styledTextField("C0123456789", text: $roomId, monospaced: true)

                fieldLabel(
                    L("Thread ID (optional)"),
                    hint: L("Post into a specific thread instead of the room itself.")
                )
                styledTextField("", text: $threadId, monospaced: true)

                sourcesSection
                rateSection

                if let binding {
                    fieldLabel(
                        L("Reference ID"),
                        hint: L("The agent refers to this room by this stable id.")
                    )
                    Text(binding.id)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            fieldLabel(
                L("Allowed Run Kinds"),
                hint: L("Which kinds of agent runs may post here. Replies to incoming messages are separate and unaffected.")
            )
            HStack(spacing: theme.space.s16) {
                ForEach(AgentChannelBindingRunSource.allCases, id: \.self) { source in
                    Toggle(isOn: sourceBinding(source)) {
                        Text(sourceLabel(source))
                            .font(SettingsFont.rowDescription)
                    }
                    .settingsCheckbox()
                }
            }
        }
    }

    private func sourceBinding(_ source: AgentChannelBindingRunSource) -> Binding<Bool> {
        Binding(
            get: { allowedSources.contains(source) },
            set: { include in
                if include {
                    allowedSources.insert(source)
                } else {
                    allowedSources.remove(source)
                }
            }
        )
    }

    private func sourceLabel(_ source: AgentChannelBindingRunSource) -> String {
        switch source {
        case .chat: return L("Chat")
        case .schedule: return L("Scheduled automations")
        case .watcher: return L("Folder automations")
        case .selfSchedule: return L("Self-scheduled")
        }
    }

    private var rateSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            fieldLabel(L("Rate Limits"))
            HStack(spacing: theme.space.s12) {
                Text("Max sends per hour", bundle: .module)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
                SettingsStepper(value: $maxSendsPerHour, range: 1 ... 120)
                    .settingsFieldAccessibility(L("Max sends per hour"))
            }
            HStack(spacing: theme.space.s12) {
                Text("Min seconds between sends", bundle: .module)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
                SettingsStepper(value: $minSecondsBetweenSends, range: 0 ... 3_600, step: 15)
                    .settingsFieldAccessibility(L("Min seconds between sends"))
            }
        }
    }

    /// Live readiness findings for the drafted destination. Non-blocking:
    /// the publish service re-validates at send time anyway, but showing
    /// failures here prevents "why didn't it send" confusion later.
    private var readinessFindings: [String] {
        var findings: [String] = []
        let trimmedRoom = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoom.isEmpty else { return findings }
        guard
            let connection = try? AgentChannelConnectionService.shared.resolvedConnectionView(
                id: connectionId
            )
        else {
            findings.append(L("Connection could not be resolved."))
            return findings
        }
        if !connection.enabled {
            findings.append(L("This channel is turned off."))
        }
        if !connection.writeEnabled {
            findings.append(L("This channel is read-only right now — posting is turned off in its settings."))
        }
        let trimmedThread = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedThread.isEmpty, !connection.writeRoomAllowlist.contains(trimmedRoom) {
            findings.append(
                L("The bot isn't allowed to post in this room yet. Allow it in the channel's settings.")
            )
        }
        if !trimmedThread.isEmpty, !connection.supportedActions.contains(.replyThread) {
            findings.append(L("This channel does not support posting into threads."))
        }
        return findings
    }

    @ViewBuilder
    private var readinessSection: some View {
        let findings = readinessFindings
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                ForEach(findings, id: \.self) { finding in
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .glyphSize(.footnote)
                            .foregroundColor(theme.status.warning.foreground)
                        Text(finding)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.status.warning.foreground)
                    }
                }
                Text(
                    "Posting won't work until these are fixed. You can still save now.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            }
            .padding(theme.space.s8)
            .settingsChrome(.status(.warning))
        }
    }

    private var canSave: Bool {
        // The reference id is auto-generated for new rooms; only the room
        // itself, at least one allowed run kind, and the auto-send
        // acknowledgement are required.
        (isNew || !bindingId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !roomId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !allowedSources.isEmpty
            && (outboundMode != .autonomous || autonomousAcknowledged)
    }

    private var footer: some View {
        VStack(spacing: theme.space.s8) {
            if let statusMessage {
                AgentChannelInlineStatusMessage(
                    message: statusMessage,
                    isError: statusIsError,
                    onAutoClear: { self.statusMessage = nil }
                )
            }
            HStack {
                // Only stored rows have anything to delete; an automatic row
                // opened for customization simply cancels back to automatic.
                if !isNew, isStoredBinding {
                    AgentChannelSheetActionButton(
                        title: deleteRevertsToAutomatic ? L("Reset") : L("Remove"),
                        busyTitle: deleteRevertsToAutomatic ? L("Reset") : L("Remove"),
                        isBusy: false,
                        isDestructive: true,
                        action: { showDeleteConfirmation = true }
                    )
                }
                Spacer()
                AgentChannelSheetActionButton(
                    title: L("Cancel"),
                    busyTitle: L("Cancel"),
                    isBusy: false,
                    action: { dismiss() }
                )
                AgentChannelSheetActionButton(
                    title: L("Save"),
                    busyTitle: L("Saving..."),
                    isBusy: false,
                    isPrimary: true,
                    action: save
                )
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s16)
        .background(
            theme.surface.subtle
                .overlay(
                    ThemeHairlineDivider(),
                    alignment: .top
                )
        )
    }

    private func fieldLabel(_ title: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)
            if let hint {
                Text(LocalizedStringKey(hint), bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
        }
    }

    /// Single-line input matching the app's field chrome (plain field on
    /// `inputBackground` with an `inputBorder` stroke), instead of the stock
    /// macOS rounded-border style.
    private func styledTextField(
        _ placeholder: String,
        text: Binding<String>,
        monospaced: Bool = false
    ) -> some View {
        SettingsTextField(placeholder: placeholder, text: text, monospaced: monospaced)
    }

    /// Multiline input with the same chrome as `styledTextField`.
    private func styledTextEditor(_ placeholder: String, text: Binding<String>) -> some View {
        SettingsTextEditor(text: text, placeholder: placeholder, minHeight: 52)
    }

    private func agentDisplayName(_ id: UUID) -> String {
        AgentManager.shared.agent(for: id)?.name ?? L("Unknown agent")
    }

    private func loadDraft() {
        if let pinnedAgentId {
            agentId = pinnedAgentId
        }
        guard let binding else { return }
        bindingId = binding.id
        agentId = binding.agentId
        connectionId = binding.connectionId
        roomId = binding.roomId
        threadId = binding.threadId ?? ""
        label = binding.label
        guidance = binding.guidance
        outboundMode = binding.outboundMode
        allowedSources = Set(binding.allowedSources)
        maxSendsPerHour = binding.ratePolicy.maxSendsPerHour
        minSecondsBetweenSends = binding.ratePolicy.minSecondsBetweenSends
        enabled = binding.enabled
        // Editing an existing autonomous binding does not require re-acking
        // UNLESS the route/agent is materially changed (see the onChange
        // handlers, which reset this when the destination drifts).
        autonomousAcknowledged = binding.outboundMode == .autonomous
    }

    /// Whether the drafted agent/route still matches the binding being
    /// edited. A material change invalidates a prior autonomous
    /// acknowledgement; returning to the original route restores it.
    private func resetAutonomousAckForRouteChange() {
        guard let binding else { return }
        let trimmedThread = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        let routeUnchanged =
            binding.agentId == agentId
            && binding.connectionId == AgentChannelConnection.normalizedId(connectionId)
            && binding.roomId == AgentChannelConnection.normalizedId(roomId)
            && (binding.threadId ?? "") == trimmedThread
        if routeUnchanged {
            autonomousAcknowledged = binding.outboundMode == .autonomous
        } else {
            autonomousAcknowledged = false
        }
    }

    /// Provider room discovery for the selected connection: lists spaces,
    /// then rooms per space, so the operator picks a real destination
    /// instead of hand-copying provider IDs.
    private func discoverRooms() {
        isDiscoveringRooms = true
        statusMessage = nil
        Task { @MainActor in
            defer { isDiscoveringRooms = false }
            do {
                let service = AgentChannelConnectionService.shared
                let spaces = try await service.listSpaces(connectionId: connectionId)
                var rooms: [DiscoveredRoom] = []
                var seen = Set<String>()
                for space in spaces.prefix(10) {
                    guard let spaceId = space["id"] as? String, !spaceId.isEmpty else { continue }
                    let rows = try await service.listRooms(
                        connectionId: connectionId,
                        spaceId: spaceId
                    )
                    for row in rows {
                        guard let id = row["id"] as? String, !id.isEmpty,
                            seen.insert(id).inserted
                        else { continue }
                        let kindString = (row["kind"] as? String) ?? ""
                        // Skip synthetic rows (e.g. Slack's pagination notice).
                        guard kindString != "notice" else { continue }
                        rooms.append(
                            DiscoveredRoom(
                                id: id,
                                name: (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                kind: .from(providerKind: kindString),
                                writeAllowed: (row["write_allowed"] as? Bool) ?? false
                            )
                        )
                    }
                }
                // Writable rooms first; the empty-discovery state has its own
                // inline card, so no footer status is needed for that case.
                discoveredRooms = rooms.sorted {
                    ($0.writeAllowed ? 0 : 1, $0.name.lowercased())
                        < ($1.writeAllowed ? 0 : 1, $1.name.lowercased())
                }
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
    }

    /// Stable slug for a new room, generated from the name (or route) so
    /// the user never has to invent an identifier. Uniqued against the
    /// effective configuration, including automatic ids.
    private func generatedBindingId() -> String {
        let source = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = Self.slugified(source.isEmpty ? "\(connectionId)-\(roomId)" : source)
        let existing = Set(
            AgentChannelAutoDestinationResolver.effectiveConfiguration().bindings.map(\.id)
        )
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }

    static func slugified(_ text: String) -> String {
        var slug = ""
        var previousWasDash = true
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
                previousWasDash = false
            } else if !previousWasDash {
                slug.append("-")
                previousWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "room" : slug
    }

    private func save() {
        let draft = AgentChannelBinding(
            id: isNew ? generatedBindingId() : bindingId,
            agentId: agentId,
            connectionId: connectionId,
            roomId: roomId,
            threadId: threadId.isEmpty ? nil : threadId,
            label: label,
            guidance: guidance,
            allowedSources: Array(allowedSources).sorted { $0.rawValue < $1.rawValue },
            outboundMode: outboundMode,
            ratePolicy: AgentChannelBindingRatePolicy(
                maxSendsPerHour: maxSendsPerHour,
                minSecondsBetweenSends: minSecondsBetweenSends
            ),
            enabled: enabled
        )
        do {
            try manager.upsertBinding(draft, replacingOriginalId: binding?.id)
            onDidChange()
            dismiss()
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    private func performDelete() {
        guard let binding else { return }
        do {
            try manager.deleteBinding(id: binding.id)
            onDidChange()
            dismiss()
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }
}

// MARK: - Outbox

/// Outbound activity page: pending approvals, unknown deliveries, drafts,
/// and recent history from the durable outbound-intent ledger. Unresolved
/// rows are queried separately from paginated history so they can never be
/// pushed out of view by newer terminal rows. Every send action goes
/// through the review sheet, which shows the COMPLETE exact payload and
/// destination before anything is written; approval re-runs full
/// authorization in `AgentChannelPublishService`.
struct AgentChannelOutboxView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var roomDirectory = AgentChannelRoomDirectory.shared

    @State private var pending: [AgentChannelOutboundIntent] = []
    @State private var unknownDeliveries: [AgentChannelOutboundIntent] = []
    @State private var drafts: [AgentChannelOutboundIntent] = []
    @State private var history: [AgentChannelOutboundIntent] = []
    @State private var busyIntentIds: Set<String> = []
    @State private var reviewedIntent: AgentChannelOutboundIntent?
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        ScrollView {
            SettingsPageContent {
                Text(
                    "Posts your agents want to send. You always see the exact message and destination before anything goes out, and every safety check runs again at send time.",
                    bundle: .module
                )
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let statusMessage {
                    AgentChannelInlineStatusMessage(
                        message: statusMessage,
                        isError: statusIsError,
                        onAutoClear: { self.statusMessage = nil }
                    )
                }

                outboxPanel(
                    title: L("Waiting for Your Approval"),
                    items: pending,
                    emptyDetail: L("Posts that need your OK before sending appear here.")
                )
                if !unknownDeliveries.isEmpty {
                    outboxPanel(
                        title: L("Unconfirmed Deliveries"),
                        items: unknownDeliveries,
                        emptyDetail: ""
                    )
                }
                outboxPanel(
                    title: L("Drafts"),
                    items: drafts,
                    emptyDetail: L("Rooms set to \"Drafts only\" save posts here without sending.")
                )
                outboxPanel(
                    title: L("Recent Activity"),
                    items: history,
                    emptyDetail: L("Sent, failed, and discarded posts appear here.")
                )
            }
        }
        .onAppear {
            Task { @MainActor in
                await AgentChannelPublishService.shared.reconcileInterruptedWork()
                reload()
            }
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .agentChannelOutboundIntentsChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            reload()
        }
        .sheet(item: $reviewedIntent) { intent in
            AgentChannelOutboundReviewSheet(
                intent: intent,
                isBusy: busyIntentIds.contains(intent.id),
                onSend: { send(intent) },
                onMarkSent: { resolveUnknown(intent, markSent: true) },
                onDiscard: { discard(intent) }
            )
        }
        .settingsLandingAnchor("agentChannels.outbox")
    }

    private func outboxPanel(
        title: String,
        items: [AgentChannelOutboundIntent],
        emptyDetail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)

            Group {
                if items.isEmpty {
                    VStack(spacing: theme.space.s6) {
                        Image(systemName: "tray")
                            .glyphSize(.large, weight: .medium)
                            .foregroundColor(theme.text.tertiary)
                        Text(LocalizedStringKey(emptyDetail), bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, theme.space.s16)
                } else {
                    VStack(spacing: theme.space.s0) {
                        ForEach(items) { intent in
                            intentRow(intent)
                            if intent.id != items.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .background(theme.surface.raised)
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .stroke(theme.border.default, lineWidth: theme.stroke.default)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
        }
    }

    /// Route header for one intent, name-first: "Dinoki → #content · Slack".
    /// Falls back to the raw room id until the directory resolves the name.
    private func routeDescription(_ intent: AgentChannelOutboundIntent) -> String {
        let provider = AgentChannelConnectionPresentation.displayName(for: intent.connectionId)
        let room =
            roomDirectory.descriptor(connectionId: intent.connectionId, roomId: intent.roomId)?
            .formattedName ?? intent.roomId
        return "\(agentName(intent.agentId)) → \(room) · \(provider)"
    }

    private func intentRow(_ intent: AgentChannelOutboundIntent) -> some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s8) {
                    statusBadge(intent.status)
                    Text(routeDescription(intent))
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .help("\(intent.connectionId) · \(intent.roomId)")
                    Text(intent.updatedAt, style: .relative)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
                Text(AgentChannelAuditRedactor.redactedPreview(intent.content, maxLength: 240))
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = intent.failureMessage,
                    intent.status == .failed || intent.status == .deliveryUnknown
                {
                    Text(failure)
                        .font(SettingsFont.footnote)
                        .foregroundColor(
                            intent.status == .failed ? theme.status.error.foreground : theme.status.warning.foreground
                        )
                }
            }

            Spacer()

            if intent.status.isUnresolved && intent.status != .sending {
                HStack(spacing: theme.space.s6) {
                    AgentChannelSheetActionButton(
                        title: L("Review…"),
                        busyTitle: L("Working..."),
                        isBusy: busyIntentIds.contains(intent.id),
                        isPrimary: intent.status == .pending,
                        action: { reviewedIntent = intent }
                    )
                    .disabled(busyIntentIds.contains(intent.id))
                    AgentChannelSheetActionButton(
                        title: L("Discard"),
                        busyTitle: L("Discard"),
                        isBusy: false,
                        isDestructive: true,
                        action: { discard(intent) }
                    )
                    .disabled(busyIntentIds.contains(intent.id))
                }
            }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    private func statusBadge(_ status: AgentChannelOutboundIntentStatus) -> some View {
        let color: Color
        switch status {
        case .draft: color = theme.text.secondary
        case .pending: color = theme.action.primary.default.background
        case .sending: color = theme.action.primary.default.background
        case .sent: color = theme.status.success.foreground
        case .failed: color = theme.status.error.foreground
        case .cancelled: color = theme.text.tertiary
        case .deliveryUnknown: color = theme.status.warning.foreground
        }
        return StatusChip(statusLabel(status), tint: color)
    }

    private func statusLabel(_ status: AgentChannelOutboundIntentStatus) -> String {
        switch status {
        case .deliveryUnknown: return L("Unconfirmed")
        case .pending: return L("Needs approval")
        case .cancelled: return L("Discarded")
        default: return status.rawValue.capitalized
        }
    }

    private func agentName(_ agentId: UUID) -> String {
        AgentManager.shared.agent(for: agentId)?.name ?? L("Unknown agent")
    }

    private func reload() {
        do {
            let store = AgentChannelMessageStore.shared
            try store.openIfNeeded()
            // Unresolved rows are fetched per status (never behind history
            // pagination); terminal history is a separate bounded page.
            pending = try store.recentOutboundIntents(statuses: [.pending], limit: 200)
            unknownDeliveries = try store.recentOutboundIntents(
                statuses: [.deliveryUnknown],
                limit: 200
            )
            drafts = try store.recentOutboundIntents(statuses: [.draft], limit: 200)
            history = try store.recentOutboundIntents(
                statuses: [.sending, .sent, .failed, .cancelled],
                limit: 100
            )
            AgentChannelRoomDirectory.shared.prepare(
                connectionIds: (pending + unknownDeliveries + drafts + history)
                    .map(\.connectionId)
            )
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    /// Send action from the review sheet: approve a pending item, send a
    /// draft, or explicitly retry an unconfirmed delivery.
    private func send(_ intent: AgentChannelOutboundIntent) {
        busyIntentIds.insert(intent.id)
        reviewedIntent = nil
        Task { @MainActor in
            let service = AgentChannelPublishService.shared
            let outcome: AgentChannelPublishOutcome
            switch intent.status {
            case .pending:
                outcome = await service.approvePendingIntent(id: intent.id)
            case .draft:
                outcome = await service.sendDraftIntent(id: intent.id)
            case .deliveryUnknown:
                outcome = await service.retryUnknownDeliveryIntent(id: intent.id)
            default:
                busyIntentIds.remove(intent.id)
                return
            }
            busyIntentIds.remove(intent.id)
            switch outcome {
            case .sent:
                statusMessage = L("Message sent.")
                statusIsError = false
            case .denied(_, let message, _):
                statusMessage = message
                statusIsError = true
            case .draftRecorded, .queuedForApproval, .duplicate:
                statusMessage = L("Item did not send; check its destination settings.")
                statusIsError = true
            }
            reload()
        }
    }

    private func resolveUnknown(_ intent: AgentChannelOutboundIntent, markSent: Bool) {
        busyIntentIds.insert(intent.id)
        reviewedIntent = nil
        Task { @MainActor in
            let resolved = await AgentChannelPublishService.shared.resolveUnknownDeliveryIntent(
                id: intent.id,
                markSent: markSent
            )
            busyIntentIds.remove(intent.id)
            if !resolved {
                statusMessage = L("Could not resolve this item.")
                statusIsError = true
            }
            reload()
        }
    }

    private func discard(_ intent: AgentChannelOutboundIntent) {
        busyIntentIds.insert(intent.id)
        reviewedIntent = nil
        Task { @MainActor in
            let service = AgentChannelPublishService.shared
            let discarded: Bool
            if intent.status == .deliveryUnknown {
                discarded = await service.resolveUnknownDeliveryIntent(
                    id: intent.id,
                    markSent: false
                )
            } else {
                discarded = await service.discardIntent(id: intent.id)
            }
            busyIntentIds.remove(intent.id)
            if !discarded {
                statusMessage = L("Could not discard this item.")
                statusIsError = true
            }
            reload()
        }
    }
}

// MARK: - Review sheet

/// Informed-consent surface for outbox actions: shows the COMPLETE exact
/// outbound payload (no redaction, no truncation — this text goes to the
/// provider verbatim) plus the exact stored destination before offering a
/// send. Unconfirmed deliveries additionally explain the duplicate risk and
/// offer mark-sent / retry / discard.
struct AgentChannelOutboundReviewSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    let intent: AgentChannelOutboundIntent
    let isBusy: Bool
    let onSend: () -> Void
    let onMarkSent: () -> Void
    let onDiscard: () -> Void

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var sendTitle: String {
        switch intent.status {
        case .pending: return L("Approve & Send")
        case .draft: return L("Send Now")
        case .deliveryUnknown: return L("Send Again")
        default: return L("Send")
        }
    }

    /// Conversation shown name-first with the exact provider id alongside,
    /// so the informed-consent surface loses no precision.
    private var reviewedRoomDescription: String {
        guard
            let descriptor = AgentChannelRoomDirectory.shared.descriptor(
                connectionId: intent.connectionId,
                roomId: intent.roomId
            ),
            descriptor.name != intent.roomId
        else { return intent.roomId }
        return "\(descriptor.formattedName) (\(intent.roomId))"
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s14) {
                    destinationSection
                    if intent.status == .deliveryUnknown {
                        unknownDeliveryNotice
                    }
                    payloadSection
                }
                .padding(theme.space.s16)
            }
            Divider()
            footer
        }
        .fittedSheetFrame(width: 560, height: 520)
        .background(theme.surface.canvas)
    }

    private var header: some View {
        HStack(spacing: theme.space.s10) {
            Image(systemName: "doc.text.magnifyingglass")
                .glyphSize(.xlarge)
                .foregroundColor(theme.text.link)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("Review Outbound Message", bundle: .module)
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
                Text(
                    "This is the exact text and destination; nothing else is added or removed.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
            }
            Spacer()
            SettingsIconButton("xmark", help: "Close", size: .compact) { dismiss() }
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            detailRow(L("Agent"), agentName(intent.agentId))
            detailRow(
                L("Channel"),
                AgentChannelConnectionPresentation.displayName(for: intent.connectionId)
            )
            detailRow(L("Conversation"), reviewedRoomDescription)
            if let threadId = intent.threadId, !threadId.isEmpty {
                detailRow(L("Thread"), threadId)
            }
            if let runSource = intent.runSource {
                detailRow(L("Queued by"), runSourceLabel(runSource))
            }
            detailRow(L("Room reference"), intent.bindingId)
            detailRow(
                L("Recorded"),
                intent.createdAt.formatted(date: .abbreviated, time: .shortened)
            )
        }
        .padding(theme.space.s12)
        .settingsChrome(.surface)
    }

    private var unknownDeliveryNotice: some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(.caption)
                .foregroundColor(theme.status.warning.foreground)
            Text(
                "Delivery of this message was not confirmed — it may already be visible in the channel. \"Send Again\" can post a duplicate; use \"Mark as Sent\" if you can see it in the channel.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.status.warning.foreground)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(theme.space.s8)
        .settingsChrome(.status(.warning))
    }

    private var payloadSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Text("Exact message", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)
            Text(intent.content)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.space.s12)
                .settingsChrome(.surface)
        }
    }

    private var footer: some View {
        HStack {
            AgentChannelSheetActionButton(
                title: L("Discard"),
                busyTitle: L("Discard"),
                isBusy: false,
                isDestructive: true,
                action: {
                    onDiscard()
                    dismiss()
                }
            )
            .disabled(isBusy)
            if intent.status == .deliveryUnknown {
                AgentChannelSheetActionButton(
                    title: L("Mark as Sent"),
                    busyTitle: L("Working..."),
                    isBusy: false,
                    action: {
                        onMarkSent()
                        dismiss()
                    }
                )
                .disabled(isBusy)
            }
            Spacer()
            AgentChannelSheetActionButton(
                title: L("Cancel"),
                busyTitle: L("Cancel"),
                isBusy: false,
                action: { dismiss() }
            )
            AgentChannelSheetActionButton(
                title: sendTitle,
                busyTitle: L("Sending..."),
                isBusy: isBusy,
                isPrimary: true,
                action: {
                    onSend()
                    dismiss()
                }
            )
            .disabled(isBusy)
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .background(theme.surface.subtle)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func agentName(_ agentId: UUID) -> String {
        AgentManager.shared.agent(for: agentId)?.name ?? L("Unknown agent")
    }

    private func runSourceLabel(_ raw: String) -> String {
        switch AgentChannelBindingRunSource(rawValue: raw) {
        case .chat: return L("A chat with you")
        case .schedule: return L("A scheduled run")
        case .watcher: return L("A watcher")
        case .selfSchedule: return L("A self-scheduled run")
        case nil: return raw
        }
    }
}
