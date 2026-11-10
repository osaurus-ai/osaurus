//
//  AgentChannelConnectionCenterView.swift
//  osaurus
//
//  Management UI for provider-neutral agent communication channels.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// Pages of the Channels pane: connection management is the primary surface;
/// Outbox holds sending. What incoming messages did lives in Automations
/// History.
private enum AgentChannelsPage: String, CaseIterable {
    case connections
    case outbox

    var title: String {
        switch self {
        case .connections: return L("Channels")
        case .outbox: return L("Outbox")
        }
    }
}

/// Which channel's configuration sheet is open.
private enum AgentChannelSheetTarget: Identifiable {
    case addChannel
    case native(AgentChannelKind)
    /// Another account of a native channel, by connection id.
    case account(AgentChannelKind, String)
    /// A channel's next account, before it exists.
    case newAccount(AgentChannelKind)
    case editCustom(AgentChannelConnection)
    case editN8n(AgentChannelConnection)

    var id: String {
        switch self {
        case .addChannel: return "add-channel"
        case .native(let kind): return "native-\(kind.rawValue)"
        case .account(_, let connectionId): return "account-\(connectionId)"
        case .newAccount(let kind): return "new-account-\(kind.rawValue)"
        case .editCustom(let connection): return "custom-\(connection.id)"
        case .editN8n(let connection): return "n8n-\(connection.id)"
        }
    }
}

struct AgentChannelConnectionCenterView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    @Environment(\.settingsLandingPending) private var landingPending

    @State private var hasAppeared = false
    @State private var page: AgentChannelsPage = .connections
    @State private var activeSheet: AgentChannelSheetTarget?
    @State private var nativeBadges: [AgentChannelKind: AgentChannelStatusPresentation] = [:]
    @State private var nativeRoutingDetails: [AgentChannelKind: String] = [:]
    @State private var nativeConfigured: [AgentChannelKind: Bool] = [:]
    /// Every account past each channel's first, with its own badge.
    @State private var extraAccounts: [ChannelAccount] = []
    @State private var accountBadges: [String: AgentChannelStatusPresentation] = [:]
    /// True once the first native-credential probe has reported back, so the
    /// sidebar badge is only published from a complete picture.
    @State private var nativeBadgesResolved = false
    @State private var anyNativeConfigured = false
    @State private var connections: [AgentChannelConnection] = []
    /// n8n workflows waiting for approve-on-first-contact, per connection id.
    @State private var n8nPendingCounts: [String: Int] = [:]
    /// Effective posting rooms: stored bindings plus automatic ones derived
    /// from the channel setup (writable rooms × assigned agents).
    /// Rows needing operator attention (pending approvals + unconfirmed
    /// deliveries), surfaced as a count on the Outbox header button.
    @State private var pendingOutboxCount = 0
    @State private var overviewGrouping: ChannelsOverviewGrouping = .byChannel

    @State private var globalWritesEnabled = true
    @State private var focusChatOnInboundEnabled = false

    private let manager = AgentChannelConnectionManager.shared
    private let writeKillSwitch = ChannelWriteKillSwitch.shared
    private let focusPreference = AgentChannelInboundFocusPreference.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            if page == .outbox {
                SettingsPageHeader(title: "Outbox", subtitle: headerSubtitle)
                    .settingsBackDestination(L("Channels"), verbatim: true) {
                        withAnimation(theme.motion.quick) { page = .connections }
                    }
            } else {
                headerView
                    .settingsHeaderEntrance(hasAppeared: hasAppeared)
            }

            Group {
                switch page {
                case .connections:
                    connectionsPage
                case .outbox:
                    AgentChannelOutboxView()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            reloadWriteGate()
            focusChatOnInboundEnabled = focusPreference.isEnabled
            reloadConnections()
            refreshNativeBadges()
            withAnimation(theme.motion.standard.delay(0.05)) {
                hasAppeared = true
            }
            openPendingChannel()
        }
        .onChange(of: page) {
            if page == .connections {
                refreshNativeBadges()
            }
        }
        .onChange(of: landingPending) { _, pending in
            routeForLandingTarget(pending)
        }
        .onChange(of: managementState.pendingChannelConnectionId) { _, _ in
            openPendingChannel()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .agentChannelConfigurationChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            reloadConnections()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .agentChannelOutboundIntentsChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            reloadPendingOutboxCount()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .agentChannelN8nPendingContactsChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            reloadN8nPendingCounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .eventsChanged).receive(on: DispatchQueue.main)) { _ in
            refreshNativeBadges()
        }
        .task {
            routeForLandingTarget(landingPending)
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { target in
            channelSheet(target)
                .environment(\.channelSheetIsEditing, isEditing(target))
                .themedAlertSheetHost()
        }
    }

    /// Whether the sheet opens on something already set up, so it reads as
    /// tabs rather than setup steps.
    private func isEditing(_ target: AgentChannelSheetTarget) -> Bool {
        switch target {
        case .native(let kind): return nativeConfigured[kind] == true
        case .account, .editCustom, .editN8n: return true
        case .addChannel, .newAccount: return false
        }
    }

    /// A channel's add button: its first account fills the channel's own
    /// slot; later ones are new accounts.
    private func addAccount(_ kind: AgentChannelKind) {
        activeSheet = hasAccount(kind) ? .newAccount(kind) : .native(kind)
    }

    /// True when the kind already has a connected account, so adding one
    /// creates another instead of setting up the first.
    private func hasAccount(_ kind: AgentChannelKind) -> Bool {
        nativeConfigured[kind] == true || extraAccounts.contains { $0.kind == kind }
    }

    @ViewBuilder
    private func channelSheet(_ target: AgentChannelSheetTarget) -> some View {
            switch target {
            case .addChannel:
                AgentChannelAddChannelSheet(
                    nativeBadges: configuredNativeBadges,
                    opensNewAccount: { kind in
                        ChannelAccounts.multiAccountKinds.contains(kind) && hasAccount(kind)
                    }
                ) {
                    reloadConnections()
                }
            case .native(.discord):
                DiscordSettingsView()
            case .native(.slack):
                SlackSettingsView()
            case .native(.telegram):
                TelegramSettingsView()
            case .native(.imessage):
                IMessageSettingsView()
            case .native(.whatsapp):
                WhatsAppSettingsView()
            case .native(.email):
                EmailSettingsView()
            case .account(.discord, let id):
                DiscordSettingsView(connectionId: id)
            case .account(.slack, let id):
                SlackSettingsView(connectionId: id)
            case .account(.telegram, let id):
                TelegramSettingsView(connectionId: id)
            case .account(.email, let id):
                EmailSettingsView(connectionId: id)
            case .account:
                EmptyView()
            case .newAccount(.discord):
                DiscordSettingsView(newAccount: true)
            case .newAccount(.slack):
                SlackSettingsView(newAccount: true)
            case .newAccount(.telegram):
                TelegramSettingsView(newAccount: true)
            case .newAccount(.email):
                EmailSettingsView(newAccount: true)
            case .newAccount:
                EmptyView()
            case .native(.customHTTP), .native(.n8n):
                // Custom HTTP and n8n connections are stored rows, never
                // presented as a fixed native channel.
                EmptyView()
            case .editCustom(let connection):
                AgentChannelCustomConnectionSheet(connection: connection) {
                    reloadConnections()
                }
            case .editN8n(let connection):
                N8nSettingsView(connection: connection) {
                    reloadConnections()
                }
            }
    }

    // MARK: - Header

    private var isFirstRun: Bool {
        !anyNativeConfigured && connections.isEmpty
    }

    private var connectedChannelCount: Int {
        Self.nativeProviderKinds.filter { nativeConfigured[$0] == true }.count + extraAccounts.count
            + connections.count
    }

    /// Badges for the Add Channel picker, limited to providers that are
    /// already set up so re-picking one reads as editing.
    private var configuredNativeBadges: [AgentChannelKind: AgentChannelStatusPresentation] {
        nativeBadges.filter { nativeConfigured[$0.key] == true }
    }

    private var headerSubtitle: String {
        switch page {
        case .outbox:
            return L("Posts agents want to send, plus what already went out")
        case .connections:
            if !globalWritesEnabled {
                return L("Sending is paused — every channel is read-only")
            }
            return L("Connect the messaging apps Osaurus can listen on and post to")
        }
    }

    private var headerView: some View {
        SettingsPageHeader(
            title: "Channels",
            subtitle: headerSubtitle,
            count: connectedChannelCount,
            secondary: {
                SettingsButton(
                    .secondary,
                    pendingOutboxCount > 0 ? L("Outbox (\(pendingOutboxCount))") : L("Outbox"),
                    icon: "tray.and.arrow.up"
                ) {
                    withAnimation(theme.motion.quick) { page = .outbox }
                }
            },
            primary: {
                SettingsButton(.primary, "Add Channel", icon: "plus") {
                    activeSheet = .addChannel
                }
            },
            toolbar: {
                if !overviewEntries.isEmpty {
                    SettingsTabsRow(selection: $overviewGrouping)
                        .settingsLandingAnchor("agentChannels.overviewGrouping")
                }
            }
        )
    }

    // MARK: - Connections Page

    private var connectedNativeKinds: [AgentChannelKind] {
        Self.nativeProviderKinds.filter { nativeConfigured[$0] == true }
    }

    /// Channels with no account at all.
    private var availableNativeKinds: [AgentChannelKind] {
        Self.nativeProviderKinds.filter { !hasAccount($0) }
    }

    private var connectionsPage: some View {
        ScrollViewReader { proxy in
            connectionsScrollView
                .settingsLandingScroll(proxy)
        }
    }

    private var connectionsScrollView: some View {
        ScrollView {
            SettingsPageContent {
                if !isFirstRun {
                    connectedSection
                }

                if !availableNativeKinds.isEmpty {
                    availableSection
                }

                incomingSection

                sendingSection
            }
        }
    }

    /// What happens on this Mac when a channel message arrives. Today: an
    /// opt-in to bring the conversation forward (for dedicated / monitoring
    /// machines); ordinary use keeps it off so inbound messages never steal
    /// focus.
    private var incomingSection: some View {
        SettingsSection(title: "Incoming") {
            SettingsToggle(
                title: "Focus Chat on Incoming Messages",
                description: focusChatOnInboundEnabled
                    ? "Every channel message brings its conversation forward: the tab is selected and the chat window comes to the front (opening one if needed)."
                    : "Channel messages run quietly in the background; watch them in Automations History or open the tab yourself. Turn on for a dedicated machine you keep an eye on.",
                anchorId: "agentChannels.focusOnInbound",
                isOn: Binding(
                    get: { focusChatOnInboundEnabled },
                    set: { setFocusChatOnInboundEnabled($0) }
                )
            )
        }
    }

    /// The master send control gets its own labeled section so it reads as
    /// the top of the sending hierarchy (replies AND new messages), not as
    /// a stray toggle after the destination list.
    private var sendingSection: some View {
        SettingsSection(title: "Sending") {
            SettingsToggle(
                title: "Allow Agents to Send Messages",
                description: globalWritesEnabled
                    ? "Master switch for replies and new messages. Agents may send to write-allowlisted destinations."
                    : "Sending is paused everywhere — replies and new messages. Agents can still read allowlisted channels.",
                badge: globalWritesEnabled ? nil : L("All channels read-only"),
                anchorId: "agentChannels.globalWrites",
                isOn: Binding(
                    get: { globalWritesEnabled },
                    set: { setGlobalWritesEnabled($0) }
                )
            )
        }
    }

    /// Channels that are set up, as one table: what each receives, where
    /// its messages go, and what agents may send (or the same, by agent).
    private var connectedSection: some View {
        ChannelsOverviewTable(
            entries: overviewEntries, writesEnabled: globalWritesEnabled, onAddAccount: { addAccount($0) },
            grouping: $overviewGrouping
        )
        .settingsLandingAnchor("agentChannels.overview")
    }

    private var overviewEntries: [ChannelOverviewEntry] {
        var entries: [ChannelOverviewEntry] = []
        for kind in Self.nativeProviderKinds {
            if nativeConfigured[kind] == true, let connectionId = ChannelMessageSourceConfig.nativeConnectionId(for: kind) {
                entries.append(
                    ChannelOverviewEntry(
                        connectionId: connectionId, kind: kind,
                        name: ChannelAccounts.account(connectionId: connectionId).map(\.name)
                            .flatMap { $0.isEmpty ? nil : $0 } ?? kind.displayName,
                        badge: nativeBadges[kind], open: { activeSheet = .native(kind) }))
            }
            for account in extraAccounts where account.kind == kind {
                entries.append(
                    ChannelOverviewEntry(
                        connectionId: account.connectionId, kind: kind,
                        name: account.name.isEmpty ? kind.displayName : account.name,
                        badge: accountBadges[account.connectionId],
                        open: { activeSheet = .account(kind, account.connectionId) }))
            }
        }
        for connection in connections {
            let pendingCount = connection.kind == .n8n ? (n8nPendingCounts[connection.id] ?? 0) : 0
            entries.append(
                ChannelOverviewEntry(
                    connectionId: connection.id,
                    kind: connection.kind,
                    name: connection.name.isEmpty ? connection.id : connection.name,
                    badge: Self.customBadge(
                        for: connection, writesEnabled: globalWritesEnabled, pendingApprovals: pendingCount),
                    note: pendingCount > 0
                        ? (pendingCount == 1
                            ? L("1 workflow is waiting for your approval")
                            : L("\(pendingCount) workflows are waiting for your approval"))
                        : nil,
                    enabledToggle: connection.kind == .n8n
                        ? AgentChannelCardEnabledToggle(
                            isOn: connection.enabled,
                            anchorId: "agentChannels.n8n.enabled",
                            onChange: { setConnectionEnabled($0, for: connection) })
                        : nil,
                    open: {
                        activeSheet = connection.kind == .n8n ? .editN8n(connection) : .editCustom(connection)
                    }))
        }
        return entries
    }

    /// Native providers that are not configured yet, as compact tiles below
    /// the table.
    @ViewBuilder
    private var availableSection: some View {
        if isFirstRun {
            SettingsSection(
                title: "Connect Your First Channel",
                subtitle:
                    "Let agents read and reply where your team already talks. Each guided setup ends with a live verification of an incoming message.",
                anchorId: "agentChannels.overview"
            ) {
                ForEach(availableNativeKinds, id: \.self) { kind in
                    nativeCard(for: kind)
                }
            }
        } else {
            SettingsSection(title: "Available", layout: .plain) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: theme.libraryGridGap)], spacing: theme.libraryGridGap) {
                    ForEach(availableNativeKinds, id: \.self) { kind in
                        providerTile(kind)
                    }
                }
            }
        }
    }

    private func providerTile(_ kind: AgentChannelKind) -> some View {
        Button {
            activeSheet = .native(kind)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(LinearGradient(colors: kind.brandGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: kind.icon)
                        .glyphSize(11, weight: .semibold)
                        .foregroundColor(FixedPalette.onMedia)
                }
                .frame(width: 26, height: 26)
                Text(verbatim: kind.displayName)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "plus")
                    .glyphSize(10, weight: .semibold)
                    .foregroundColor(theme.text.link)
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .settingsChrome(.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.nativeSubtitle(for: kind))
        .settingsLandingAnchor("agentChannels.\(kind.rawValue)")
    }

    private func nativeCard(for kind: AgentChannelKind) -> some View {
        AgentChannelCard(
            icon: kind.icon,
            gradient: kind.brandGradient,
            title: kind.displayName,
            subtitle: Self.nativeSubtitle(for: kind),
            badge: nativeBadges[kind],
            detail: nativeRoutingDetails[kind],
            anchorId: "agentChannels.\(kind.rawValue)"
        ) {
            activeSheet = .native(kind)
        }
    }

    // MARK: - Channel Data

    private static let nativeProviderKinds: [AgentChannelKind] = [
        .discord, .slack, .telegram, .imessage, .whatsapp, .email,
    ]

    private static func nativeSubtitle(for kind: AgentChannelKind) -> String {
        switch kind {
        case .discord: return L("Bot access to allowlisted servers and channels")
        case .slack: return L("Bot access to allowlisted channels and DMs")
        case .telegram: return L("Bot access to allowlisted chats and groups")
        case .imessage: return L("This Mac's Messages app, allowlisted chats only")
        case .whatsapp: return L("QR-linked WhatsApp Web bridge, allowlisted chats only")
        case .email: return L("Mail app or IMAP accounts, allowlisted senders only")
        case .n8n: return L("n8n HTTP Request in, poll or webhook out")
        case .customHTTP: return L("JSON-defined HTTP channel")
        }
    }

    private func handleSheetDismiss() {
        reloadConnections()
        refreshNativeBadges()
        // Allowlists or credentials may have changed; re-resolve room names.
        AgentChannelRoomDirectory.shared.invalidate()
    }

    /// Derive channel badges for native providers from saved-credential
    /// presence plus live receive-transport health.
    private func refreshNativeBadges() {
        // Credential presence lives in the keychain; read it off the main
        // thread so a slow securityd never stalls the connection list.
        Task {
            let discordConfigured = await DiscordConnectionService.shared.hasBotTokenOffMain()
            let slackPresence = await SlackConnectionService.shared.credentialPresenceOffMain()
            let telegramConfigured = await TelegramConnectionService.shared.hasBotTokenOffMain()
            applyNativeBadges(
                discordConfigured: discordConfigured,
                slackConfigured: slackPresence.botToken,
                slackReceiveExpected: slackPresence.appToken,
                telegramConfigured: telegramConfigured
            )
        }
    }

    private func applyNativeBadges(
        discordConfigured: Bool,
        slackConfigured: Bool,
        slackReceiveExpected: Bool,
        telegramConfigured: Bool
    ) {
        let imessageConfigured = AgentChannelConnectionManager.isIMessageConfigured()
        let imessageReceiveExpected = IMessageConnectionService.shared.configuration().canStartReceive()
        // Linked-session state feeds the transport health badge instead
        // (probing spawns the helper).
        let whatsappConfigured = AgentChannelConnectionManager.isWhatsAppConfigured()
        let whatsappReceiveExpected = WhatsAppConnectionService.shared.configuration().canStartReceive()
        let emailConfig = EmailChannelService.shared.configuration()
        let emailPrimary = emailConfig.account(channelConnectionId: AgentChannelConnection.nativeEmailConnectionId)
        let emailConfigured = emailPrimary != nil
        let emailReceiveExpected = emailPrimary?.canStartReceive() == true
        let extras = AgentChannelConnectionManager.extraAccounts()
        extraAccounts = extras
        let discordConfig = DiscordConnectionService.shared.configuration()
        let discordReceiveExpected = discordConfigured
            && !discordConfig.readableChannelIds.isEmpty
            && !discordConfig.senderAllowlist.isEmpty
        let telegramConfig = TelegramConnectionService.shared.configuration()
        let telegramReceiveExpected = telegramConfig.longPollingEnabled

        anyNativeConfigured =
            discordConfigured || slackConfigured || telegramConfigured || imessageConfigured
            || whatsappConfigured || emailConfigured || !extras.isEmpty
        nativeConfigured[.discord] = discordConfigured
        nativeConfigured[.slack] = slackConfigured
        nativeConfigured[.telegram] = telegramConfigured
        nativeConfigured[.imessage] = imessageConfigured
        nativeConfigured[.whatsapp] = whatsappConfigured
        nativeConfigured[.email] = emailConfigured
        nativeBadgesResolved = true
        publishSidebarBadgeCount()
        // Reply state only makes sense on configured channels; the
        // "Available" list would otherwise show a noisy "Replies off".
        for (kind, configured) in nativeConfigured {
            guard let connectionId = ChannelMessageSourceConfig.nativeConnectionId(for: kind) else { continue }
            nativeRoutingDetails[kind] =
                configured
                ? Self.routingSummary(EventManager.channelListeners(kind: kind, connectionId: connectionId)) : nil
        }

        Task {
            let discordHealth = await AgentChannelTransportHealthCenter.shared.state(
                connectionId: AgentChannelConnection.nativeDiscordConnectionId,
                transportId: DiscordPollingTransportRuntime.transportId
            )
            let slackHealth = await AgentChannelTransportHealthCenter.shared.state(
                connectionId: AgentChannelConnection.nativeSlackConnectionId,
                transportId: SlackSocketModeTransportRuntime.transportId
            )
            let telegramHealth = await AgentChannelTransportHealthCenter.shared.state(
                connectionId: AgentChannelConnection.nativeTelegramConnectionId,
                transportId: TelegramLongPollTransportRuntime.transportId
            )
            let imessageHealth = await AgentChannelTransportHealthCenter.shared.state(
                connectionId: AgentChannelConnection.nativeIMessageConnectionId,
                transportId: IMessageWatchTransportRuntime.transportId
            )
            let whatsappHealth = await AgentChannelTransportHealthCenter.shared.state(
                connectionId: AgentChannelConnection.nativeWhatsAppConnectionId,
                transportId: WhatsAppWatchTransportRuntime.transportId
            )
            // One check per watched mailbox; the badge shows the worst.
            let emailHealth = await AgentChannelTransportHealthCenter.shared
                .allStates(connectionId: AgentChannelConnection.nativeEmailConnectionId)
                .max { Self.healthRank($0.status) < Self.healthRank($1.status) }
            await MainActor.run {
                nativeBadges[.discord] = Self.nativeBadge(
                    configured: discordConfigured,
                    receiveExpected: discordReceiveExpected,
                    health: discordHealth
                )
                nativeBadges[.slack] = Self.nativeBadge(
                    configured: slackConfigured,
                    receiveExpected: slackReceiveExpected,
                    health: slackHealth
                )
                nativeBadges[.telegram] = Self.nativeBadge(
                    configured: telegramConfigured,
                    receiveExpected: telegramReceiveExpected,
                    health: telegramHealth
                )
                nativeBadges[.imessage] = Self.nativeBadge(
                    configured: imessageConfigured,
                    receiveExpected: imessageReceiveExpected,
                    health: imessageHealth
                )
                nativeBadges[.whatsapp] = Self.nativeBadge(
                    configured: whatsappConfigured,
                    receiveExpected: whatsappReceiveExpected,
                    health: whatsappHealth
                )
                nativeBadges[.email] = Self.nativeBadge(
                    configured: emailConfigured,
                    receiveExpected: emailReceiveExpected,
                    health: emailHealth
                )
            }
        }
        refreshAccountBadges(extras, email: emailConfig)
    }

    /// Badges for the extra accounts: each one's own receive state and
    /// listener health.
    private func refreshAccountBadges(_ accounts: [ChannelAccount], email: EmailChannelConfiguration) {
        Task {
            var badges: [String: AgentChannelStatusPresentation] = [:]
            for account in accounts {
                let id = account.connectionId
                let health: AgentChannelTransportHealthState?
                let receiveExpected: Bool
                switch account.kind {
                case .discord:
                    let config = DiscordConnectionConfigurationStore.load(connectionId: id)
                    receiveExpected = !config.readableChannelIds.isEmpty && !config.senderAllowlist.isEmpty
                    health = await AgentChannelTransportHealthCenter.shared.state(
                        connectionId: id, transportId: DiscordPollingTransportRuntime.transportId)
                case .telegram:
                    receiveExpected = TelegramConnectionConfigurationStore.load(connectionId: id).longPollingEnabled
                    health = await AgentChannelTransportHealthCenter.shared.state(
                        connectionId: id, transportId: TelegramLongPollTransportRuntime.transportId)
                case .slack:
                    // A workspace is added with both tokens.
                    receiveExpected = true
                    health = await AgentChannelTransportHealthCenter.shared.state(
                        connectionId: id, transportId: SlackSocketModeTransportRuntime.transportId)
                case .email:
                    receiveExpected = email.account(channelConnectionId: id)?.canStartReceive() == true
                    health = await AgentChannelTransportHealthCenter.shared.allStates(connectionId: id)
                        .max { Self.healthRank($0.status) < Self.healthRank($1.status) }
                default:
                    continue
                }
                badges[id] = Self.nativeBadge(configured: true, receiveExpected: receiveExpected, health: health)
            }
            await MainActor.run { accountBadges = badges }
        }
    }

    private static func healthRank(_ status: AgentChannelTransportHealthStatus) -> Int {
        switch status {
        case .disabled, .idle: 0
        case .healthy: 1
        case .degraded: 2
        case .conflict: 3
        case .failed: 4
        }
    }

    /// One-line description of who answers messages on this channel, shown
    /// on the card. Always explicit — a configured channel nobody answers
    /// on says so instead of hiding the state. Names are the agents and
    /// workflows (what the user picked in the sheet), not automation names.
    @MainActor
    static func routingSummary(
        _ listeners: ChannelEventListeners,
        nameFor: @MainActor (ChannelEventListeners.Listener) -> String = Self.answererName
    ) -> String? {
        var seen = Set<String>()
        let names = listeners.listeners.map(nameFor).filter { seen.insert($0).inserted }
        switch names.count {
        case 0:
            return L("Nobody answers here yet — messages stay in the inbox")
        case 1:
            return L("Answered by \(names[0])")
        case 2, 3:
            return L("Answered by \(names.joined(separator: ", "))")
        default:
            return L("Answered by \(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more")
        }
    }

    @MainActor
    static func answererName(_ listener: ChannelEventListeners.Listener) -> String {
        if let workflowId = listener.workflowId {
            return InstalledWorkflowStore.shared.workflow(id: workflowId)?.name ?? L("Missing workflow")
        }
        return EventInspection.targetName(listener.target)
    }

    /// Honest custom-channel badge: enabled alone is not usable — a custom
    /// channel needs defined HTTP actions before agents can do anything.
    static func customBadge(
        for connection: AgentChannelConnection,
        writesEnabled: Bool = true,
        pendingApprovals: Int = 0,
        listeners: ChannelEventListeners? = nil
    ) -> AgentChannelStatusPresentation {
        guard connection.enabled else {
            return AgentChannelStatusPresentation(label: L("Disabled"), tone: .neutral)
        }
        if connection.kind == .n8n {
            return n8nBadge(
                for: connection, writesEnabled: writesEnabled, pendingApprovals: pendingApprovals, listeners: listeners)
        }
        let actionCount = connection.customHTTP?.actions.count ?? 0
        guard actionCount > 0 else {
            return AgentChannelStatusPresentation(label: L("No actions defined"), tone: .warning)
        }
        if connection.writeEnabled {
            return AgentChannelStatusPresentation(label: L("Enabled"), tone: .success)
        }
        return AgentChannelStatusPresentation(label: L("Enabled (read-only)"), tone: .success)
    }

    /// n8n rows are inbound-first: usable once an event listens to it and
    /// at least one workflow identity has been approved (both allowlists are
    /// fail-closed; approve-on-first-contact fills them).
    /// `listeners` defaults to the events currently listening on the connection.
    static func n8nBadge(
        for connection: AgentChannelConnection,
        writesEnabled: Bool = true,
        pendingApprovals: Int = 0,
        listeners: ChannelEventListeners? = nil
    ) -> AgentChannelStatusPresentation {
        if pendingApprovals > 0 {
            return AgentChannelStatusPresentation(
                label: pendingApprovals == 1 ? L("1 waiting for approval") : L("\(pendingApprovals) waiting for approval"),
                tone: .warning
            )
        }
        let listeners = listeners ?? EventManager.channelListeners(kind: connection.kind, connectionId: connection.id)
        guard !listeners.isEmpty else {
            return AgentChannelStatusPresentation(label: L("No automation yet"), tone: .warning)
        }
        let authorization = connection.inboundAuthorization
        guard !authorization.senderAllowlist.isEmpty, !authorization.roomAllowlist.isEmpty else {
            return AgentChannelStatusPresentation(label: L("Waiting for first workflow"), tone: .neutral)
        }
        let mode = N8nSetupRecipe.verifyModeChip(
            for: connection.n8n?.inboundVerification.method ?? .hmacSHA256
        )
        let wantsPush = connection.n8n?.outbound.isConfigured == true
            || connection.writeEnabled
        if wantsPush && !writesEnabled {
            return AgentChannelStatusPresentation(
                label: "\(mode) · \(L("Push blocked"))",
                tone: .warning
            )
        }
        if wantsPush {
            return AgentChannelStatusPresentation(
                label: "\(mode) · \(L("Enabled (push + poll)"))",
                tone: .success
            )
        }
        return AgentChannelStatusPresentation(
            label: "\(mode) · \(L("Enabled (poll replies)"))",
            tone: .success
        )
    }

    /// A saved token must not read as "Configured" while a receive transport
    /// the user expects is stopped or blocked: with a live health state the
    /// badge always mirrors the transport, and a missing health state with
    /// receive credentials shows "Not running" instead of a green badge.
    static func nativeBadge(
        configured: Bool,
        receiveExpected: Bool,
        health: AgentChannelTransportHealthState?
    ) -> AgentChannelStatusPresentation {
        guard configured else {
            return .diagnostics(status: "not_configured")
        }
        if let health {
            return .transport(status: health.status)
        }
        if receiveExpected {
            return .transportNotRunning
        }
        return .diagnostics(status: "configured")
    }

    private func reloadN8nPendingCounts() {
        Task {
            let counts = await AgentChannelN8nPendingContactCenter.shared.pendingCounts()
            await MainActor.run { n8nPendingCounts = counts }
        }
    }

    /// Card-level on/off for stored connections. Persists through the
    /// manager so validation and the n8n projection run as on Save.
    private func setConnectionEnabled(_ enabled: Bool, for connection: AgentChannelConnection) {
        var updated = connection
        updated.enabled = enabled
        do {
            try manager.upsertConnection(updated, replacingOriginalId: connection.id)
            reloadConnections()
            _ = ToastManager.shared.success(
                enabled ? L("\(updated.name) enabled") : L("\(updated.name) disabled")
            )
        } catch {
            _ = ToastManager.shared.error(error.localizedDescription)
        }
    }

    /// Opens the settings sheet a History row asked for.
    private func openPendingChannel() {
        guard let id = managementState.pendingChannelConnectionId else { return }
        managementState.pendingChannelConnectionId = nil
        page = .connections
        let normalized = AgentChannelConnection.normalizedId(id)
        if let kind = AgentChannelKind(rawValue: normalized), Self.nativeProviderKinds.contains(kind) {
            activeSheet = .native(kind)
        } else if let account = ChannelAccounts.account(connectionId: normalized) {
            activeSheet = account.isPrimary ? .native(account.kind) : .account(account.kind, account.connectionId)
        } else if let connection = manager.editableConnections().first(where: { $0.id == normalized }) {
            activeSheet = connection.kind == .n8n ? .editN8n(connection) : .editCustom(connection)
        }
    }

    private func reloadConnections() {
        connections = manager.editableConnections()
        reloadN8nPendingCounts()
        reloadPendingOutboxCount()
        publishSidebarBadgeCount()
    }

    /// The Settings sidebar shows the same connected-channel count as this
    /// page's header. The badge store never probes the Keychain itself, so
    /// this page (which does, off-main) hands it the number whenever the
    /// native-credential or custom-connection picture changes.
    private func publishSidebarBadgeCount() {
        // Before the first Keychain probe lands, `nativeConfigured` is empty
        // and the count would briefly undershoot; wait for a real reading.
        guard nativeBadgesResolved else { return }
        ManagementBadgeStore.shared.setObservedCount(connectedChannelCount, for: .agentChannels)
    }

    private func reloadPendingOutboxCount() {
        let store = AgentChannelMessageStore.shared
        guard (try? store.openIfNeeded()) != nil else {
            pendingOutboxCount = 0
            return
        }
        let pending = (try? store.outboundIntentCount(status: .pending)) ?? 0
        let unknown = (try? store.outboundIntentCount(status: .deliveryUnknown)) ?? 0
        pendingOutboxCount = pending + unknown
    }

    /// Settings-search landing targets that live on a secondary page need the
    /// page switched before the anchor can scroll/glow.
    private func routeForLandingTarget(_ pending: String?) {
        guard let pending else { return }
        if pending == "agentChannels.outbox", page != .outbox {
            page = .outbox
        } else if pending == "agentChannels.routing" || pending == "agentChannels.addRule"
            || pending == "agentChannels.posting" || pending == "agentChannels.overviewGrouping"
            || pending == "agentChannels.focusOnInbound"
            || pending == "agentChannels.globalWrites", page != .connections
        {
            page = .connections
        }
    }

    private func reloadWriteGate() {
        globalWritesEnabled = writeKillSwitch.snapshot().writeEnabled
    }

    private func setFocusChatOnInboundEnabled(_ enabled: Bool) {
        focusChatOnInboundEnabled = enabled
        focusPreference.setEnabled(enabled)
    }

    private func setGlobalWritesEnabled(_ enabled: Bool) {
        let previousEnabled = globalWritesEnabled
        globalWritesEnabled = enabled
        do {
            _ = try writeKillSwitch.setWriteEnabled(enabled)
        } catch {
            globalWritesEnabled = previousEnabled
            reloadWriteGate()
            _ = ToastManager.shared.error(
                L("Couldn't update the Sending switch"),
                message: error.localizedDescription
            )
        }
    }

}
