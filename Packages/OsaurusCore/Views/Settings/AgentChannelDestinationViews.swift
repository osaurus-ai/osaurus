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
        switch connectionId.lowercased() {
        case AgentChannelConnection.nativeDiscordConnectionId: return .discord
        case AgentChannelConnection.nativeSlackConnectionId: return .slack
        case AgentChannelConnection.nativeTelegramConnectionId: return .telegram
        case AgentChannelConnection.nativeIMessageConnectionId: return .imessage
        default:
            return AgentChannelConnectionManager.shared.connection(id: connectionId)?.kind
                ?? .customHTTP
        }
    }

    static func displayName(for connectionId: String) -> String {
        switch connectionId.lowercased() {
        case AgentChannelConnection.nativeDiscordConnectionId: return "Discord"
        case AgentChannelConnection.nativeSlackConnectionId: return "Slack"
        case AgentChannelConnection.nativeTelegramConnectionId: return "Telegram"
        case AgentChannelConnection.nativeIMessageConnectionId: return "iMessage"
        default:
            let connection = AgentChannelConnectionManager.shared.connection(id: connectionId)
            guard let connection, !connection.name.isEmpty else { return connectionId }
            return connection.name
        }
    }
}

// MARK: - Destinations Section

/// "Messages Agents Can Start" section for the Channels pane: every
/// destination agents can post to on their own, across all agents.
/// Destinations appear here automatically once a channel has an assigned
/// agent and write-allowlisted rooms; stored (customized) rows are shown
/// alongside. Rows share the card + inline mode menu with the per-agent
/// section.
struct AgentChannelDestinationsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Effective bindings: stored plus automatic (derived).
    let bindings: [AgentChannelBinding]
    /// Ids of the stored subset, to badge the rest as "Automatic".
    let storedBindingIds: Set<String>
    /// Whether the global Sending switch is off, so the section can say
    /// exactly which layer is blocking deliveries.
    var sendingPaused = false
    let onAdd: () -> Void
    let onEdit: (AgentChannelBinding) -> Void
    let onChanged: () -> Void

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Messages Agents Can Start", bundle: .module)
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)
                Spacer()
                Button {
                    onAdd()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Add Destination", bundle: .module)
                    }
                }
                .buttonStyle(SettingsButtonStyle())
            }

            Text(
                "Where agents may bring things up on their own — and whether they ask you first. Replies to incoming messages are configured on each channel above.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if sendingPaused && !bindings.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 11))
                    Text(
                        "Sending is paused by the global switch below — nothing is delivered from these destinations until it's back on.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(theme.warningColor)
            }

            if bindings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents can't start messages yet", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Destinations appear here automatically once a connected channel lets the bot post somewhere and an agent is chosen to reply there. Agents always ask before sending unless you change a destination's setting.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(bindings) { binding in
                        AgentChannelDestinationRowCard(
                            binding: binding,
                            isAutomatic: !storedBindingIds.contains(binding.id),
                            showAgentName: true,
                            onCustomize: { onEdit(binding) },
                            onChanged: onChanged
                        )
                    }
                }
                Text(
                    "Automatic destinations come from your channel setup and always ask first. Each agent's destinations are also editable in its own settings, under Channels.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            }
        }
        .onAppear {
            AgentChannelRoomDirectory.shared.prepare(
                connectionIds: bindings.map(\.connectionId)
            )
        }
        .settingsLandingAnchor("agentChannels.destinations")
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

/// Small colored badge for a binding's outbound mode.
struct AgentChannelDestinationModeBadge: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let mode: AgentChannelBindingOutboundMode

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var color: Color {
        switch mode {
        case .off: return theme.tertiaryText
        case .draft: return theme.secondaryText
        case .confirm: return theme.accentColor
        case .autonomous: return theme.warningColor
        }
    }

    var body: some View {
        Text(mode.friendlyLabel)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Shared destination row

/// One destination as a card: where the agent can post, how it behaves
/// (inline plain-language mode menu), and a Customize entry point for the
/// full editor. Used by both the per-agent section (agent settings →
/// Automation) and the cross-agent section (Settings → Channels).
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
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: connectionKind.brandGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: connectionKind.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
            .opacity(binding.isUsable ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .help(presentation.technicalRoute)
                    if let typeBadge = presentation.typeBadge {
                        Text(typeBadge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                    if isAutomatic {
                        Text("Automatic", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.secondaryText.opacity(0.12)))
                            .help(
                                L(
                                    "Available because this agent answers on this channel and the room allows bot posts. No setup needed."
                                )
                            )
                    }
                }
                Text(presentation.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .help(presentation.technicalRoute)
                Text(effectiveMode.friendlyDescription)
                    .font(.system(size: 10))
                    .foregroundColor(
                        effectiveMode == .autonomous ? theme.warningColor : theme.tertiaryText
                    )
            }

            Spacer()

            modeMenu

            Button {
                onCustomize()
            } label: {
                Text("Customize…", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(SettingsButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
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
        Menu {
            ForEach(AgentChannelBindingOutboundMode.allCases, id: \.self) { mode in
                Button {
                    select(mode)
                } label: {
                    if mode == effectiveMode {
                        Label(mode.friendlyLabel, systemImage: "checkmark")
                    } else {
                        Text(mode.friendlyLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(effectiveMode.friendlyLabel)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(effectiveMode == .autonomous ? theme.warningColor : theme.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
                L("Couldn't update this destination"),
                message: error.localizedDescription
            )
        }
    }
}

// MARK: - Per-Agent Replies Summary (Agent Settings)

/// Read-only summary of where ONE agent answers incoming messages,
/// embedded in that agent's Channels tab. Reply routing itself is
/// configured per channel (Settings → Channels → the channel's sheet),
/// so this section reports the current state and links there instead of
/// duplicating the editor.
struct AgentChannelAgentRepliesSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let agentId: UUID

    @State private var rows: [Row] = []

    struct Row: Identifiable {
        let kind: AgentChannelKind
        let detail: String
        var id: String { kind.rawValue }
    }

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text(
                    "This agent doesn't reply on any channel yet. Open a connected channel in Channels settings and choose this agent under \u{201C}Reply to incoming messages\u{201D}.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        replyRow(row)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    ManagementStateManager.shared.selectedTab = .agentChannels
                } label: {
                    HStack(spacing: 4) {
                        Text("Manage replies in Channels settings", bundle: .module)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(theme.accentColor)
            }
        }
        .onAppear(perform: reload)
    }

    private func replyRow(_ row: Row) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        LinearGradient(
                            colors: row.kind.brandGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: row.kind.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.kind.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(row.detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func reload() {
        // Credential presence comes from the non-blocking availability cache
        // (seeded at launch, refreshed on credential mutation) — the direct
        // `hasBotToken()` / `helperAvailable()` probes are synchronous
        // Keychain / bundle-digest I/O and this runs on the main thread.
        let availability = AgentChannelCredentialAvailability.shared
        var next: [Row] = []
        if availability.hasCredential(.discord),
            let detail = AgentChannelAgentReplySummary.detail(
                for: agentId,
                dispatch: DiscordConnectionService.shared.configuration().inboundDispatch
            )
        {
            next.append(Row(kind: .discord, detail: detail))
        }
        if availability.hasCredential(.slack),
            let detail = AgentChannelAgentReplySummary.detail(
                for: agentId,
                dispatch: SlackConnectionService.shared.configuration().inboundDispatch
            )
        {
            next.append(Row(kind: .slack, detail: detail))
        }
        if availability.hasCredential(.telegram),
            let detail = AgentChannelAgentReplySummary.detail(
                for: agentId,
                dispatch: TelegramConnectionService.shared.configuration().inboundDispatch
            )
        {
            next.append(Row(kind: .telegram, detail: detail))
        }
        // iMessage has no remote credential; the verified local helper plays
        // that role.
        if availability.hasCredential(.imessage),
            let detail = AgentChannelAgentReplySummary.detail(
                for: agentId,
                dispatch: IMessageConnectionService.shared.configuration().inboundDispatch
            )
        {
            next.append(Row(kind: .imessage, detail: detail))
        }
        rows = next
    }
}

// MARK: - Per-Agent Destinations (Agent Settings)

/// New-message destinations scoped to ONE agent, embedded in that agent's
/// settings (Connections → Channels tab) next to the read-only Replies
/// summary. Shows the same effective rows (automatic + customized) as the
/// Channels pane and shares its editor sheet.
struct AgentChannelAgentDestinationsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let agentId: UUID

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
        VStack(alignment: .leading, spacing: 10) {
            if sendingPaused && !bindings.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 11))
                    Text(
                        "Sending is paused by the global switch in Channels settings — nothing is delivered from these destinations until it's back on.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(theme.warningColor)
            }

            if bindings.isEmpty {
                Text(
                    "Nothing to post to yet. Destinations appear here automatically once a connected channel lets the bot post somewhere and this agent is chosen to reply there — the agent then always asks before sending. You can also add a specific destination below.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
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
                .font(.system(size: 10))
                .foregroundColor(theme.warningColor)
            }

            HStack {
                Button {
                    sheetTarget = .add
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Add Destination", bundle: .module)
                    }
                }
                .buttonStyle(SettingsButtonStyle())

                Spacer()

                // Channel connections, the outbox, and the global write kill
                // switch are cross-agent concerns and stay in the Channels pane.
                Button {
                    ManagementStateManager.shared.selectedTab = .agentChannels
                } label: {
                    HStack(spacing: 4) {
                        Text("Channels & Outbox settings", bundle: .module)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(theme.accentColor)
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $sheetTarget, onDismiss: reload) { target in
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
        var options = [
            AgentChannelConnection.nativeDiscordConnectionId,
            AgentChannelConnection.nativeSlackConnectionId,
            AgentChannelConnection.nativeTelegramConnectionId,
            AgentChannelConnection.nativeIMessageConnectionId,
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
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identitySection
                    destinationSection
                    behaviorSection
                    advancedSection
                    readinessSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 560, height: 680)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder, lineWidth: 1)
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
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: connectionKind.brandGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: connectionKind.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? L("Add a Destination") : L("Customize Destination"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Choose where this agent may post on its own, and whether it asks you first.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(theme.secondaryBackground)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L("Agent"))
            if pinnedAgentId != nil {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    Text(agentDisplayName(agentId))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                }
            } else {
                Picker(selection: $agentId) {
                    ForEach(agentManager.agents, id: \.id) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)
            }

            fieldLabel(L("Name (optional)"))
            styledTextField(L("Team standup channel"), text: $label)
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L("Channel"))
            Picker(selection: $connectionId) {
                ForEach(connectionOptions, id: \.self) { option in
                    Text(connectionDisplayName(option)).tag(option)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding conversations…", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
        } else if discoveredRooms.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No conversations found on this channel yet.", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text(
                    "Check the channel's settings, or enter a conversation id directly under Advanced.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    discoverRooms()
                } label: {
                    Text("Try Again", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(isDiscoveringRooms)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
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
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !roomId.isEmpty, !discoveredRooms.contains(where: { $0.id == roomId }) {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                        Text(L("Currently set to \(roomId) (not in this list)"))
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundColor(theme.tertiaryText)
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
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(selected ? theme.accentColor : theme.tertiaryText)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(
                                room.writeAllowed ? theme.primaryText : theme.tertiaryText
                            )
                            .lineLimit(1)
                        if let badge = room.kind.badgeLabel {
                            Text(badge)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.tertiaryBackground))
                        }
                    }
                    Text(room.id)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if !room.writeAllowed {
                    Text("Posting not allowed", bundle: .module)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.tertiaryBackground))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!room.writeAllowed)
        .opacity(room.writeAllowed ? 1 : 0.55)
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L("When the agent wants to post"))
            Picker(selection: $outboundMode) {
                ForEach(AgentChannelBindingOutboundMode.allCases, id: \.self) { mode in
                    Text(mode.friendlyLabel).tag(mode)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(modeDescription)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if outboundMode == .autonomous {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.warningColor)
                        Text(
                            "Auto-send lets this agent post messages without asking you. Room permissions, rate limits, and the global Sending switch still apply.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.warningColor)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle(isOn: $autonomousAcknowledged) {
                        Text("I understand this agent can post here without asking", bundle: .module)
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.warningColor.opacity(0.08))
                )
            }

            // Only surfaced when this row arrived disabled (a deleted
            // channel's cascade, or an imported configuration): the operator
            // must explicitly reactivate it. New rows are simply active, and
            // "Off" mode covers the everyday disable case.
            if binding?.enabled == false {
                Toggle(isOn: $enabled) {
                    Text("Active", bundle: .module)
                        .font(.system(size: 12))
                }
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                Text(
                    "This room was turned off — for example its channel was removed, or it arrived from an imported file. Turn it back on to use it again.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
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
            VStack(alignment: .leading, spacing: 14) {
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
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(
                L("Allowed Run Kinds"),
                hint: L("Which kinds of agent runs may post here. Replies to incoming messages are separate and unaffected.")
            )
            HStack(spacing: 16) {
                ForEach(AgentChannelBindingRunSource.allCases, id: \.self) { source in
                    Toggle(isOn: sourceBinding(source)) {
                        Text(sourceLabel(source))
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
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
        case .schedule: return L("Schedules")
        case .watcher: return L("Watchers")
        case .selfSchedule: return L("Self-scheduled")
        }
    }

    private var rateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L("Rate Limits"))
            HStack(spacing: 18) {
                Stepper(value: $maxSendsPerHour, in: 1...120) {
                    Text(L("Max \(maxSendsPerHour)/hour"))
                        .font(.system(size: 12))
                }
                Stepper(value: $minSecondsBetweenSends, in: 0...3_600, step: 15) {
                    Text(L("Min \(minSecondsBetweenSends)s between sends"))
                        .font(.system(size: 12))
                }
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(findings, id: \.self) { finding in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.warningColor)
                        Text(finding)
                            .font(.system(size: 11))
                            .foregroundColor(theme.warningColor)
                    }
                }
                Text(
                    "Posting won't work until these are fixed. You can still save now.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.warningColor.opacity(0.08))
            )
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
        VStack(spacing: 8) {
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
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    private func fieldLabel(_ title: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(title), bundle: .module)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)
            if let hint {
                Text(LocalizedStringKey(hint), bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
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
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
    }

    /// Multiline input with the same chrome as `styledTextField`.
    private func styledTextEditor(_ placeholder: String, text: Binding<String>) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundColor(theme.placeholderText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
                )
        )
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
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Posts your agents want to send. You always see the exact message and destination before anything goes out, and every safety check runs again at send time.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
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
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Group {
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                        Text(LocalizedStringKey(emptyDetail), bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    VStack(spacing: 0) {
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
            .background(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    statusBadge(intent.status)
                    Text(routeDescription(intent))
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .help("\(intent.connectionId) · \(intent.roomId)")
                    Text(intent.updatedAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
                Text(AgentChannelAuditRedactor.redactedPreview(intent.content, maxLength: 240))
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = intent.failureMessage,
                    intent.status == .failed || intent.status == .deliveryUnknown
                {
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundColor(
                            intent.status == .failed ? theme.errorColor : theme.warningColor
                        )
                }
            }

            Spacer()

            if intent.status.isUnresolved && intent.status != .sending {
                HStack(spacing: 6) {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statusBadge(_ status: AgentChannelOutboundIntentStatus) -> some View {
        let color: Color
        switch status {
        case .draft: color = theme.secondaryText
        case .pending: color = theme.accentColor
        case .sending: color = theme.accentColor
        case .sent: color = theme.successColor
        case .failed: color = theme.errorColor
        case .cancelled: color = theme.tertiaryText
        case .deliveryUnknown: color = theme.warningColor
        }
        return Text(statusLabel(status))
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
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
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    destinationSection
                    if intent.status == .deliveryUnknown {
                        unknownDeliveryNotice
                    }
                    payloadSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .background(theme.primaryBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 20))
                .foregroundColor(theme.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Review Outbound Message", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "This is the exact text and destination; nothing else is added or removed.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 5) {
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var unknownDeliveryNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.warningColor)
            Text(
                "Delivery of this message was not confirmed — it may already be visible in the channel. \"Send Again\" can post a duplicate; use \"Mark as Sent\" if you can see it in the channel.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.warningColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.08))
        )
    }

    private var payloadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Exact message", bundle: .module)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)
            Text(intent.content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                )
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
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
