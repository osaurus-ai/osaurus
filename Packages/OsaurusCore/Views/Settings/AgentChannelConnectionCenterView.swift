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
/// Activity is a secondary destination reached from the header.
private enum AgentChannelsPage {
    case connections
    case activity
    case outbox
}

/// Which channel's configuration sheet is open.
private enum AgentChannelSheetTarget: Identifiable {
    case addChannel
    case native(AgentChannelKind)
    case editCustom(AgentChannelConnection)
    case addDestination
    case editDestination(AgentChannelBinding)

    var id: String {
        switch self {
        case .addChannel: return "add-channel"
        case .native(let kind): return "native-\(kind.rawValue)"
        case .editCustom(let connection): return "custom-\(connection.id)"
        case .addDestination: return "destination-new"
        case .editDestination(let binding): return "destination-\(binding.id)"
        }
    }
}

struct AgentChannelConnectionCenterView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.settingsLandingPending) private var landingPending

    @State private var hasAppeared = false
    @State private var page: AgentChannelsPage = .connections
    @State private var activeSheet: AgentChannelSheetTarget?
    @State private var nativeBadges: [AgentChannelKind: AgentChannelStatusPresentation] = [:]
    @State private var nativeRoutingDetails: [AgentChannelKind: String] = [:]
    @State private var nativeConfigured: [AgentChannelKind: Bool] = [:]
    @State private var anyNativeConfigured = false
    @State private var connections: [AgentChannelConnection] = []
    /// Effective posting rooms: stored bindings plus automatic ones derived
    /// from the channel setup (writable rooms × assigned agents).
    @State private var destinationBindings: [AgentChannelBinding] = []
    @State private var storedDestinationIds: Set<String> = []
    /// Rows needing operator attention (pending approvals + unconfirmed
    /// deliveries), surfaced as a count on the Outbox header button.
    @State private var pendingOutboxCount = 0

    @State private var auditScopeId: String?
    @State private var auditSnapshot: AgentChannelAuditWorkbenchSnapshot?
    @State private var auditErrorMessage: String?
    @State private var isLoadingAudit = false
    @State private var auditLoadID = UUID()

    @State private var globalWritesEnabled = true

    private let manager = AgentChannelConnectionManager.shared
    private let auditWorkbench = AgentChannelAuditWorkbenchService()
    private let writeKillSwitch = ChannelWriteKillSwitch.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            Group {
                switch page {
                case .connections:
                    connectionsPage
                case .activity:
                    activityTab
                case .outbox:
                    AgentChannelOutboxView()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            reloadWriteGate()
            reloadConnections()
            refreshNativeBadges()
            reloadAuditWorkbench()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onChange(of: page) {
            if page == .connections {
                refreshNativeBadges()
            } else if page == .activity {
                reloadAuditWorkbench()
            }
        }
        .onChange(of: landingPending) { _, pending in
            routeForLandingTarget(pending)
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .agentChannelOutboundIntentsChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            reloadPendingOutboxCount()
        }
        .task {
            routeForLandingTarget(landingPending)
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { target in
            switch target {
            case .addChannel:
                AgentChannelAddChannelSheet(nativeBadges: configuredNativeBadges) {
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
            case .native(.customHTTP):
                // Custom HTTP is never presented as a native channel.
                EmptyView()
            case .editCustom(let connection):
                AgentChannelCustomConnectionSheet(connection: connection) {
                    reloadConnections()
                }
            case .addDestination:
                AgentChannelDestinationEditorSheet(binding: nil) {
                    reloadConnections()
                }
            case .editDestination(let binding):
                AgentChannelDestinationEditorSheet(binding: binding) {
                    reloadConnections()
                }
            }
        }
    }

    // MARK: - Header

    private var isFirstRun: Bool {
        !anyNativeConfigured && connections.isEmpty
    }

    private var connectedChannelCount: Int {
        Self.nativeProviderKinds.filter { nativeConfigured[$0] == true }.count + connections.count
    }

    /// Badges for the Add Channel picker, limited to providers that are
    /// already set up so re-picking one reads as editing.
    private var configuredNativeBadges: [AgentChannelKind: AgentChannelStatusPresentation] {
        nativeBadges.filter { nativeConfigured[$0.key] == true }
    }

    private var headerSubtitle: String {
        switch page {
        case .activity:
            return L("Incoming messages and receive decisions across your channels")
        case .outbox:
            return L("Posts agents want to send, plus what already went out")
        case .connections:
            if !globalWritesEnabled {
                return L("Sending is paused — every channel is read-only")
            }
            return L("Let agents read and reply on Discord, Slack, and Telegram")
        }
    }

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Channels"),
            subtitle: headerSubtitle,
            count: connectedChannelCount > 0 ? connectedChannelCount : nil
        ) {
            switch page {
            case .connections:
                HeaderSecondaryButton(
                    pendingOutboxCount > 0 ? L("Outbox (\(pendingOutboxCount))") : L("Outbox"),
                    icon: "paperplane"
                ) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        page = .outbox
                    }
                }
                HeaderSecondaryButton(L("Activity"), icon: "clock.arrow.circlepath") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        page = .activity
                    }
                }
                HeaderPrimaryButton(L("Add Channel"), icon: "plus") {
                    activeSheet = .addChannel
                }
            case .activity, .outbox:
                HeaderSecondaryButton(L("Back to Channels"), icon: "chevron.left") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        page = .connections
                    }
                }
            }
        }
    }

    // MARK: - Connections Page

    private var connectedNativeKinds: [AgentChannelKind] {
        Self.nativeProviderKinds.filter { nativeConfigured[$0] == true }
    }

    private var availableNativeKinds: [AgentChannelKind] {
        Self.nativeProviderKinds.filter { nativeConfigured[$0] != true }
    }

    private var connectionsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isFirstRun {
                    emptyStateHero
                } else {
                    connectedSection
                }

                if !availableNativeKinds.isEmpty {
                    availableSection
                }

                if !isFirstRun || !destinationBindings.isEmpty {
                    AgentChannelDestinationsSection(
                        bindings: destinationBindings,
                        storedBindingIds: storedDestinationIds,
                        sendingPaused: !globalWritesEnabled,
                        onAdd: { activeSheet = .addDestination },
                        onEdit: { activeSheet = .editDestination($0) },
                        onChanged: { reloadConnections() }
                    )
                }

                sendingSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    /// The master send control gets its own labeled section so it reads as
    /// the top of the sending hierarchy (replies AND new messages), not as
    /// a stray toggle after the destination list.
    private var sendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(L("Sending"))
            writeGateRow
        }
    }

    /// Polished first-run state: one clear action, with the provider catalog
    /// listed right below as the guided starting path.
    private var emptyStateHero: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 56, height: 56)
                .background(Circle().fill(theme.accentColor.opacity(0.1)))

            VStack(spacing: 4) {
                Text("Connect your first channel", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Let agents read and reply where your team already talks. Each guided setup ends with a live verification of an incoming message.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            }

            Button {
                activeSheet = .addChannel
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add Channel", bundle: .module)
                }
            }
            .buttonStyle(SettingsButtonStyle(isPrimary: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
        .settingsLandingAnchor("agentChannels.overview")
    }

    /// Channels that are set up: configured native providers first, then
    /// custom connections. This is the page's primary list.
    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(L("Connected"))

            VStack(spacing: 10) {
                ForEach(connectedNativeKinds, id: \.self) { kind in
                    nativeCard(for: kind)
                }

                VStack(spacing: 10) {
                    ForEach(connections) { connection in
                        AgentChannelCard(
                            icon: connection.kind.icon,
                            gradient: connection.kind.brandGradient,
                            title: connection.name.isEmpty ? connection.id : connection.name,
                            subtitle: connection.id,
                            subtitleIsMonospaced: true,
                            badge: Self.customBadge(for: connection)
                        ) {
                            activeSheet = .editCustom(connection)
                        }
                    }
                }
                .settingsLandingAnchor(connections.isEmpty ? nil : "agentChannels.customJSON")
            }
            .settingsLandingAnchor("agentChannels.overview")
        }
    }

    /// Native providers that are not configured yet, kept discoverable below
    /// the connected list without competing with it.
    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isFirstRun {
                sectionLabel(L("Available"))
            }

            VStack(spacing: 10) {
                ForEach(availableNativeKinds, id: \.self) { kind in
                    nativeCard(for: kind)
                }
            }
        }
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

    private func sectionLabel(_ title: String) -> some View {
        Text(LocalizedStringKey(title), bundle: .module)
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(theme.tertiaryText)
            .tracking(0.5)
    }

    /// Master write switch, humanized: on = agents may send where allowlisted,
    /// off = every channel is read-only regardless of per-channel settings.
    private var writeGateRow: some View {
        HStack(spacing: 12) {
            Image(systemName: globalWritesEnabled ? "shield.fill" : "shield.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(globalWritesEnabled ? theme.successColor : theme.warningColor)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(
                        (globalWritesEnabled ? theme.successColor : theme.warningColor).opacity(0.12)
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Allow Agents to Send Messages", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if !globalWritesEnabled {
                        Text("All channels read-only", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.warningColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.warningColor.opacity(0.12)))
                    }
                }
                Text(
                    globalWritesEnabled
                        ? L("Master switch for replies and new messages. Agents may send to write-allowlisted destinations.")
                        : L("Sending is paused everywhere — replies and new messages. Agents can still read allowlisted channels.")
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { globalWritesEnabled },
                    set: { setGlobalWritesEnabled($0) }
                )
            )
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            globalWritesEnabled ? theme.cardBorder : theme.warningColor.opacity(0.35),
                            lineWidth: 1
                        )
                )
        )
        .settingsLandingAnchor("agentChannels.globalWrites")
    }

    // MARK: - Activity Tab

    private var activityTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Authorized incoming messages are stored in a local inbox that agent read tools consult. A channel only replies automatically when an agent is chosen to reply there and automatic replies are turned on.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                activityScopeRow

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ChannelMetricTile(
                        title: L("Messages"),
                        value: "\(auditSnapshot?.summary.messageCount ?? 0)",
                        caption: L("stored in the inbox"),
                        icon: "tray.full",
                        color: theme.accentColor
                    )
                    ChannelMetricTile(
                        title: L("Accepted"),
                        value: "\(auditSnapshot?.summary.acceptedCount ?? 0)",
                        caption: L("authorized and stored"),
                        icon: "checkmark.shield.fill",
                        color: theme.successColor
                    )
                    ChannelMetricTile(
                        title: L("Denied"),
                        value: "\(auditSnapshot?.summary.deniedCount ?? 0)",
                        caption: L("blocked by allowlists"),
                        icon: "hand.raised.fill",
                        color: theme.warningColor
                    )
                    ChannelMetricTile(
                        title: L("Duplicates"),
                        value: "\(auditSnapshot?.summary.duplicateCount ?? 0)",
                        caption: L("seen more than once"),
                        icon: "arrow.triangle.2.circlepath",
                        color: theme.secondaryText
                    )
                }

                if let auditErrorMessage {
                    AgentChannelInlineStatusMessage(
                        message: auditErrorMessage,
                        isError: true
                    )
                }

                recentInboxMessages
                recentAuditEvents
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var activityScopeRow: some View {
        HStack(spacing: 12) {
            Picker(selection: $auditScopeId) {
                Text("All channels", bundle: .module)
                    .tag(String?.none)
                ForEach(auditScopeOptions, id: \.self) { connectionId in
                    Text(scopeDisplayName(for: connectionId))
                        .tag(String?.some(connectionId))
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220, alignment: .leading)
            .onChange(of: auditScopeId) {
                reloadAuditWorkbench()
            }

            Spacer(minLength: 0)

            HeaderIconButton(
                "arrow.clockwise",
                isLoading: isLoadingAudit,
                help: L("Refresh activity")
            ) {
                reloadAuditWorkbench()
            }

            HeaderIconButton(
                "doc.on.doc",
                help: L("Copy redacted export")
            ) {
                copyAuditExport()
            }
        }
    }

    private var recentInboxMessages: some View {
        let messages = auditSnapshot?.messages ?? []
        return activityListPanel(title: L("Recent Messages")) {
            if messages.isEmpty {
                activityEmptyState(
                    icon: "tray",
                    title: L("No messages yet"),
                    detail: L("Authorized incoming messages for this scope appear here.")
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(messages) { message in
                        AgentChannelInboxMessageRow(message: message)
                        if message.id != messages.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var recentAuditEvents: some View {
        let events = auditSnapshot?.auditEvents ?? []
        return activityListPanel(title: L("Receive Log")) {
            if events.isEmpty {
                activityEmptyState(
                    icon: "list.bullet.clipboard",
                    title: L("No receive decisions yet"),
                    detail: L("Accept and deny decisions for this scope appear here.")
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(events) { event in
                        AgentChannelAuditDecisionRow(event: event)
                        if event.id != events.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// Full-width bordered list panel, matching the Router usage center's
    /// stacked "Recent activity" list.
    private func activityListPanel<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)

            content()
                .frame(maxWidth: .infinity)
                .background(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Inline empty state matching the Router usage center: no nested card,
    /// just icon, headline, and one detail line inside the list panel.
    private func activityEmptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            if isLoadingAudit {
                ProgressView()
                    .scaleEffect(0.75)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            Text(LocalizedStringKey(isLoadingAudit ? L("Loading activity") : title), bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(LocalizedStringKey(detail), bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Channel Data

    private static let nativeProviderKinds: [AgentChannelKind] = [.discord, .slack, .telegram, .imessage]

    private static func nativeSubtitle(for kind: AgentChannelKind) -> String {
        switch kind {
        case .discord: return L("Bot access to allowlisted servers and channels")
        case .slack: return L("Bot access to allowlisted channels and DMs")
        case .telegram: return L("Bot access to allowlisted chats and groups")
        case .imessage: return L("This Mac's Messages app, allowlisted chats only")
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
        // iMessage has no remote credential; "configured" means a verified
        // helper is present AND allowlisted chats exist. Without the helper
        // check, a machine that lost its helper (failed download, tampered
        // digest) would still show Configured/Connected while every action
        // fails.
        let imessageConfig = IMessageConnectionService.shared.configuration()
        let imessageConfigured =
            IMessageConnectionService.shared.helperAvailable()
            && (!imessageConfig.readableChatIds.isEmpty || !imessageConfig.writableChatIds.isEmpty)
        let imessageReceiveExpected = imessageConfig.canStartReceive()
        let discordConfig = DiscordConnectionService.shared.configuration()
        let discordReceiveExpected = discordConfigured
            && !discordConfig.readableChannelIds.isEmpty
            && !discordConfig.senderAllowlist.isEmpty
        let telegramConfig = TelegramConnectionService.shared.configuration()
        let telegramReceiveExpected = telegramConfig.longPollingEnabled
        let slackDispatch = SlackConnectionService.shared.configuration().inboundDispatch

        anyNativeConfigured =
            discordConfigured || slackConfigured || telegramConfigured || imessageConfigured
        nativeConfigured[.discord] = discordConfigured
        nativeConfigured[.slack] = slackConfigured
        nativeConfigured[.telegram] = telegramConfigured
        nativeConfigured[.imessage] = imessageConfigured
        // Reply state only makes sense on configured channels; the
        // "Available" list would otherwise show a noisy "Replies off".
        nativeRoutingDetails[.discord] =
            discordConfigured ? Self.routingSummary(discordConfig.inboundDispatch) : nil
        nativeRoutingDetails[.slack] =
            slackConfigured ? Self.routingSummary(slackDispatch) : nil
        nativeRoutingDetails[.telegram] =
            telegramConfigured ? Self.routingSummary(telegramConfig.inboundDispatch) : nil
        nativeRoutingDetails[.imessage] =
            imessageConfigured ? Self.routingSummary(imessageConfig.inboundDispatch) : nil

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
            }
        }
    }

    /// One-line description of who replies on this channel, shown on the
    /// card. Always explicit — a configured channel that never replies says
    /// so instead of hiding the state.
    @MainActor
    static func routingSummary(
        _ dispatch: AgentChannelInboundDispatchConfiguration,
        agentName: (UUID) -> String? = { AgentManager.shared.agent(for: $0)?.name }
    ) -> String? {
        guard dispatch.enabled else { return L("Replies off") }
        let names = dispatch.referencedAgentIds.map { agentName($0) ?? L("Unknown agent") }
        switch names.count {
        case 0:
            return L("Replies on — choose an agent")
        case 1:
            return L("Replies: \(names[0])")
        default:
            return L("Replies: \(names.count) agents — \(names.joined(separator: ", "))")
        }
    }

    /// Honest custom-channel badge: enabled alone is not usable — a custom
    /// channel needs defined HTTP actions before agents can do anything.
    static func customBadge(for connection: AgentChannelConnection) -> AgentChannelStatusPresentation {
        guard connection.enabled else {
            return AgentChannelStatusPresentation(label: L("Disabled"), tone: .neutral)
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

    private func reloadConnections() {
        connections = manager.editableConnections()
        storedDestinationIds = Set(manager.bindings().map(\.id))
        destinationBindings = AgentChannelAutoDestinationResolver.effectiveConfiguration()
            .bindings
            .sorted { lhs, rhs in
                lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel)
                    == .orderedAscending
            }
        reloadPendingOutboxCount()
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
        } else if pending == "agentChannels.destinations", page != .connections {
            page = .connections
        }
    }

    private func reloadWriteGate() {
        globalWritesEnabled = writeKillSwitch.snapshot().writeEnabled
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

    // MARK: - Activity Data

    /// Explicit activity scope choices: native provider connections first,
    /// then custom connections.
    private var auditScopeOptions: [String] {
        var options = [
            AgentChannelConnection.nativeDiscordConnectionId,
            AgentChannelConnection.nativeSlackConnectionId,
            AgentChannelConnection.nativeTelegramConnectionId,
            AgentChannelConnection.nativeIMessageConnectionId,
        ]
        for connection in connections where !options.contains(connection.id) {
            options.append(connection.id)
        }
        return options
    }

    private func scopeDisplayName(for connectionId: String) -> String {
        switch connectionId {
        case AgentChannelConnection.nativeDiscordConnectionId:
            return AgentChannelKind.discord.displayName
        case AgentChannelConnection.nativeSlackConnectionId:
            return AgentChannelKind.slack.displayName
        case AgentChannelConnection.nativeTelegramConnectionId:
            return AgentChannelKind.telegram.displayName
        case AgentChannelConnection.nativeIMessageConnectionId:
            return AgentChannelKind.imessage.displayName
        default:
            if let match = connections.first(where: { $0.id == connectionId }), !match.name.isEmpty {
                return match.name
            }
            return connectionId
        }
    }

    private func reloadAuditWorkbench() {
        let loadID = UUID()
        auditLoadID = loadID
        isLoadingAudit = true
        let connectionId = auditScopeId
        Task {
            do {
                let snapshot = try auditWorkbench.snapshot(
                    connectionId: connectionId,
                    messageLimit: 8,
                    auditLimit: 10
                )
                await MainActor.run {
                    guard auditLoadID == loadID, auditScopeId == connectionId else { return }
                    auditSnapshot = snapshot
                    auditErrorMessage = nil
                    isLoadingAudit = false
                }
            } catch {
                await MainActor.run {
                    guard auditLoadID == loadID, auditScopeId == connectionId else { return }
                    auditErrorMessage = error.localizedDescription
                    isLoadingAudit = false
                }
            }
        }
    }

    private func copyAuditExport() {
        let connectionId = auditScopeId
        Task {
            do {
                let export = try auditWorkbench.exportRedactedJSON(
                    connectionId: connectionId,
                    messageLimit: 25,
                    auditLimit: 100
                )
                await MainActor.run {
                    #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(export, forType: .string)
                    #endif
                    _ = ToastManager.shared.success(L("Redacted activity export copied"))
                }
            } catch {
                await MainActor.run {
                    _ = ToastManager.shared.error(
                        L("Couldn't export activity"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

}

// MARK: - Metric Tile

/// Summary tile matching the Router usage center's metric tiles: tinted icon
/// circle, large rounded value, one-line caption, uniform height.
private struct ChannelMetricTile: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let value: String
    let caption: String
    let icon: String
    let color: Color

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.13)))

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text(verbatim: value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .monospacedDigit()
                Text(LocalizedStringKey(caption), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minHeight: 112, alignment: .topLeading)
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

// MARK: - Activity Rows

private struct AgentChannelAuditDecisionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let event: AgentChannelAuditRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor)
                    .frame(width: 18)
                Text(event.status.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                Text(event.action)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
                Spacer()
                Text(event.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            if !event.redactedSummary.isEmpty {
                Text(event.redactedSummary)
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Label(scopeLabel, systemImage: "app.connected.to.app.below.fill")
                if let roomId = event.roomId {
                    Label(roomId, systemImage: "number")
                }
                if let reason = event.reason {
                    Label(reason, systemImage: "info.circle")
                }
            }
            .font(.system(size: 10))
            .foregroundColor(themeManager.currentTheme.tertiaryText)
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.cardBackground)
    }

    private var scopeLabel: String {
        AgentChannelKind(rawValue: event.connectionId)?.displayName ?? event.connectionId
    }

    private var statusIcon: String {
        switch event.status {
        case .accepted: "checkmark.shield.fill"
        case .duplicate: "arrow.triangle.2.circlepath"
        case .denied: "hand.raised.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch event.status {
        case .accepted:
            themeManager.currentTheme.successColor
        case .duplicate:
            themeManager.currentTheme.accentColor
        case .denied, .failed:
            themeManager.currentTheme.warningColor
        }
    }
}

private struct AgentChannelInboxMessageRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let message: AgentChannelInboxMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: message.direction == .inbound ? "tray.and.arrow.down" : "paperplane")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)
                    .frame(width: 18)
                Text(message.direction == .inbound ? L("Received") : L("Sent"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                Text(message.roomId)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
                Spacer()
                Text(message.receivedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .lineLimit(1)
            }

            Text(message.preview.isEmpty ? L("Empty message") : message.preview)
                .font(.system(size: 12))
                .foregroundColor(themeManager.currentTheme.secondaryText)
                .lineLimit(2)

            HStack(spacing: 8) {
                Label(scopeLabel, systemImage: "app.connected.to.app.below.fill")
                if let authorDisplay = message.authorDisplay, !authorDisplay.isEmpty {
                    Label(authorDisplay, systemImage: "person")
                }
            }
            .font(.system(size: 10))
            .foregroundColor(themeManager.currentTheme.tertiaryText)
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.cardBackground)
    }

    private var scopeLabel: String {
        AgentChannelKind(rawValue: message.connectionId)?.displayName ?? message.connectionId
    }
}
