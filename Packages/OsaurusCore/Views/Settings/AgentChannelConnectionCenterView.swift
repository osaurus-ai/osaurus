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

/// Sub-tabs for the Agent Channels management pane.
enum AgentChannelsTab: String, CaseIterable, AnimatedTabItem {
    case channels
    case activity

    var title: String {
        switch self {
        case .channels: return L("Connections")
        case .activity: return L("Activity")
        }
    }
}

/// Which channel's configuration sheet is open.
private enum AgentChannelSheetTarget: Identifiable {
    case native(AgentChannelKind)
    case editCustom(AgentChannelConnection)
    case newCustom

    var id: String {
        switch self {
        case .native(let kind): return "native-\(kind.rawValue)"
        case .editCustom(let connection): return "custom-\(connection.id)"
        case .newCustom: return "new-custom"
        }
    }
}

struct AgentChannelConnectionCenterView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var hasAppeared = false
    @State private var selectedTab: AgentChannelsTab = .channels
    @State private var activeSheet: AgentChannelSheetTarget?
    @State private var nativeBadges: [AgentChannelKind: AgentChannelStatusPresentation] = [:]
    @State private var connections: [AgentChannelConnection] = []

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
                switch selectedTab {
                case .channels:
                    channelsTab
                case .activity:
                    activityTab
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
        .onChange(of: selectedTab) {
            if selectedTab == .channels {
                refreshNativeBadges()
            } else {
                reloadAuditWorkbench()
            }
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { target in
            switch target {
            case .native(.discord):
                DiscordSettingsView()
            case .native(.slack):
                SlackSettingsView()
            case .native(.telegram):
                TelegramSettingsView()
            case .native(.customHTTP):
                // Custom HTTP is never presented as a native channel.
                EmptyView()
            case .editCustom(let connection):
                AgentChannelCustomConnectionSheet(connection: connection) {
                    reloadConnections()
                }
            case .newCustom:
                AgentChannelCustomConnectionSheet(connection: nil) {
                    reloadConnections()
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Channels"),
            subtitle: L("Let agents read and reply on Discord, Slack, and Telegram")
        ) {
            HeaderPrimaryButton(L("Add Custom Channel"), icon: "plus") {
                activeSheet = .newCustom
            }
        } tabsRow: {
            HeaderTabsRow(selection: $selectedTab)
        }
    }

    // MARK: - Channels Tab

    private var channelsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                writeGateRow

                VStack(spacing: 10) {
                    ForEach(Self.nativeProviderKinds, id: \.self) { kind in
                        AgentChannelCard(
                            icon: kind.icon,
                            gradient: kind.brandGradient,
                            title: kind.displayName,
                            subtitle: Self.nativeSubtitle(for: kind),
                            badge: nativeBadges[kind],
                            anchorId: "agentChannels.\(kind.rawValue)"
                        ) {
                            activeSheet = .native(kind)
                        }
                    }
                }
                .settingsLandingAnchor("agentChannels.overview")

                if !connections.isEmpty {
                    customSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
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
                    Text("Channel Writes", bundle: .module)
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
                        ? L("Agents may send messages to write-allowlisted destinations.")
                        : L("Sending is paused everywhere. Agents can still read allowlisted channels.")
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

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom", bundle: .module)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)
                .padding(.top, 6)

            VStack(spacing: 10) {
                ForEach(connections) { connection in
                    AgentChannelCard(
                        icon: connection.kind.icon,
                        gradient: connection.kind.brandGradient,
                        title: connection.name.isEmpty ? connection.id : connection.name,
                        subtitle: connection.id,
                        subtitleIsMonospaced: true,
                        badge: AgentChannelStatusPresentation(
                            label: connection.enabled ? L("Enabled") : L("Disabled"),
                            tone: connection.enabled ? .success : .neutral
                        )
                    ) {
                        activeSheet = .editCustom(connection)
                    }
                }
            }
        }
        .settingsLandingAnchor("agentChannels.customJSON")
    }

    // MARK: - Activity Tab

    private var activityTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Authorized incoming messages are stored in a local inbox that agent read tools consult. Nothing is ever answered automatically.",
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

    private static let nativeProviderKinds: [AgentChannelKind] = [.discord, .slack, .telegram]

    private static func nativeSubtitle(for kind: AgentChannelKind) -> String {
        switch kind {
        case .discord: return L("Bot access to allowlisted servers and channels")
        case .slack: return L("Bot access to allowlisted workspace channels")
        case .telegram: return L("Bot access to allowlisted chats and groups")
        case .customHTTP: return L("JSON-defined HTTP channel")
        }
    }

    private func handleSheetDismiss() {
        reloadConnections()
        refreshNativeBadges()
    }

    /// Derive channel badges for native providers from saved-credential
    /// presence plus (for Slack/Telegram) live receive-transport health.
    private func refreshNativeBadges() {
        let discordConfigured = DiscordConnectionService.shared.hasBotToken()
        let slackConfigured = SlackConnectionService.shared.hasBotToken()
        let telegramConfigured = TelegramConnectionService.shared.hasBotToken()
        Task {
            let slackHealth = await AgentChannelTransportHealthCenter.shared.state(
                connectionId: AgentChannelConnection.nativeSlackConnectionId,
                transportId: SlackSocketModeTransportRuntime.transportId
            )
            let telegramHealth = await AgentChannelTransportHealthCenter.shared.state(
                connectionId: AgentChannelConnection.nativeTelegramConnectionId,
                transportId: TelegramLongPollTransportRuntime.transportId
            )
            await MainActor.run {
                nativeBadges[.discord] = Self.nativeBadge(configured: discordConfigured, health: nil)
                nativeBadges[.slack] = Self.nativeBadge(configured: slackConfigured, health: slackHealth)
                nativeBadges[.telegram] = Self.nativeBadge(
                    configured: telegramConfigured,
                    health: telegramHealth
                )
            }
        }
    }

    private static func nativeBadge(
        configured: Bool,
        health: AgentChannelTransportHealthState?
    ) -> AgentChannelStatusPresentation {
        guard configured else {
            return .diagnostics(status: "not_configured")
        }
        if let health, health.status != .disabled {
            return .transport(status: health.status)
        }
        return .diagnostics(status: "configured")
    }

    private func reloadConnections() {
        connections = manager.editableConnections()
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
                L("Couldn't update channel writes"),
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
