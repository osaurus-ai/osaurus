//
//  SlackSettingsView.swift
//  osaurus
//
//  Configuration sheet for the native Slack channel.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct SlackSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Set when this sheet is hosted inside the unified Add Channel picker;
    /// shows a back chevron that returns to the catalog.
    var onBack: (() -> Void)? = nil
    /// The workspace's connection: `slack`, or `slack-<team>` for an extra
    /// one. Empty for a new workspace until its tokens check out.
    @State private var connectionId: String

    init(
        onBack: (() -> Void)? = nil, connectionId: String = AgentChannelConnection.nativeSlackConnectionId,
        newAccount: Bool = false
    ) {
        self.onBack = onBack
        _connectionId = State(initialValue: newAccount ? "" : connectionId)
    }

    private var isPendingAccount: Bool { connectionId.isEmpty }

    private var service: SlackConnectionService { ChannelAccountServices.slack(connectionId) ?? .shared }
    @State private var isConnectingAccount = false

    @State private var botToken: String = ""
    @State private var signingSecret: String = ""
    @State private var appToken: String = ""
    @State private var configuredTeamIdsText: String = ""
    @State private var readableChannelIdsText: String = ""
    @State private var writableChannelIdsText: String = ""
    @State private var senderAllowlistText: String = ""
    @State private var writeEnabled: Bool = false
    @State private var allowBroadcastMentions: Bool = false
    @State private var acceptAppPostsFromAllowlistedSenders = false
    @State private var pendingAcceptAppPostsConfirm = false
    @State private var defaultReadLimit: String = "50"
    /// Incoming messages are handled by the events that listen to this
    /// channel; these read them so readiness checks stay honest.
    private var channelEvents: [OsaurusEvent] {
        EventManager.shared.events(kind: .slack, connectionId: connectionId).filter(\.isEnabled)
    }
    private var inboundDispatchEnabled: Bool { !channelEvents.isEmpty }
    private var inboundAutoReplyEnabled: Bool {
        channelEvents.contains { $0.reply.replies(for: $0.action.kind) }
    }
    @State private var botTokenSaved: Bool = false
    @State private var signingSecretSaved: Bool = false
    @State private var appTokenSaved: Bool = false
    @State private var statusMessage: String?
    @State private var statusDetails: [String] = []
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isDiscovering = false
    @State private var discovery: SlackConnectionDiscovery?
    @State private var channelSearch = ""
    @State private var userSearch = ""
    @State private var healthRefreshToken = 0
    @State private var isVerifying = false
    @State private var activityRefreshToken = 0
    @State private var selectedSectionId: String = AgentChannelProviderSetupSection.connect.rawValue
    @State private var attentionSectionId: String?
    @State private var verifySucceeded = false
    @State private var lastSavedDraft: DraftSnapshot?
    @State private var autosaveTask: Task<Void, Never>?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// Everything the configuration save persists, as one Equatable value —
    /// a single `onChange` on this drives autosave.
    private struct DraftSnapshot: Equatable {
        var configuredTeamIdsText: String
        var readableChannelIdsText: String
        var writableChannelIdsText: String
        var senderAllowlistText: String
        var writeEnabled: Bool
        var allowBroadcastMentions: Bool
        var acceptAppPostsFromAllowlistedSenders: Bool
        var defaultReadLimit: String
    }

    private var currentDraft: DraftSnapshot {
        DraftSnapshot(
            configuredTeamIdsText: configuredTeamIdsText,
            readableChannelIdsText: readableChannelIdsText,
            writableChannelIdsText: writableChannelIdsText,
            senderAllowlistText: senderAllowlistText,
            writeEnabled: writeEnabled,
            allowBroadcastMentions: allowBroadcastMentions,
            acceptAppPostsFromAllowlistedSenders: acceptAppPostsFromAllowlistedSenders,
            defaultReadLimit: defaultReadLimit
        )
    }

    var body: some View {
        AgentChannelSetupScaffold(
            icon: AgentChannelKind.slack.icon,
            gradient: AgentChannelKind.slack.brandGradient,
            title: isPendingAccount
                ? ChannelAccounts.newTitle(.slack)
                : ChannelAccounts.displayName(connectionId: connectionId) ?? AgentChannelKind.slack.displayName,
            subtitle: L("Read and reply in allowlisted channels and DMs"),
            sections: AgentChannelProviderSetupSection.sections,
            selection: $selectedSectionId,
            sectionStatus: sectionStatus(for:),
            onBack: onBack,
            pendingAccount: isPendingAccount
                ? AgentChannelPendingAccount(
                    actionTitle: L("Connect"), isWorking: isConnectingAccount,
                    canConnect: hasPendingBotToken && !appToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    connect: connectNewAccount)
                : nil
        ) { sectionId in
            VStack(alignment: .leading, spacing: 20) {
                switch AgentChannelProviderSetupSection(rawValue: sectionId) {
                case .connect:
                    connectSectionContent
                case .receiving:
                    accessSectionContent
                case .routing:
                    routingSectionContent
                case .sending:
                    sendingSectionContent
                case .verify, nil:
                    stepVerifySection
                }
            }
        } statusBar: {
            if let statusMessage {
                AgentChannelInlineStatusMessage(
                    message: statusMessage,
                    details: statusDetails,
                    isError: statusIsError,
                    onAutoClear: { clearStatus() }
                )
            }
        } footerLeading: {
            AgentChannelSheetActionButton(
                title: L("Test Connection"),
                busyTitle: L("Testing..."),
                isBusy: isTesting,
                action: testConnection
            )
            .disabled(isTesting || isSaving || isDiscovering || (!botTokenSaved && !hasPendingBotToken))
        } footerTrailing: {
            AgentChannelSheetActionButton(
                title: L("Done"),
                busyTitle: L("Saving..."),
                isBusy: isSaving,
                isPrimary: true,
                action: saveAndDismiss
            )
            .disabled(isSaving)
        }
        .onAppear {
            guard !isPendingAccount else { return }
            loadConfiguration()
            selectedSectionId = AgentChannelSetupFlow.initialSection(
                in: AgentChannelProviderSetupSection.sections,
                required: AgentChannelProviderSetupSection.requiredSectionIds,
                isComplete: { sectionCompleted($0) },
                fallback: AgentChannelProviderSetupSection.verify.rawValue
            )
            if botTokenSaved {
                refreshDiscovery(showStatus: false)
            }
        }
        .onChange(of: currentDraft) { _, _ in
            scheduleAutosave()
        }
        // Contained in the sheet itself: a `.window` alert goes to the settings
        // window's host, which sits under this sheet, so it was invisible
        // until the sheet closed and then dismissed with it.
        .themedAlert(
            L("Accept messages sent through apps?"),
            isPresented: $pendingAcceptAppPostsConfirm,
            message: L(
                "Any Slack app an allowlisted person has authorized to post as them, such as Zapier or a workflow, will be able to message this agent. Other bots stay blocked."
            ),
            primaryButton: .primary(L("Turn On")) { acceptAppPostsFromAllowlistedSenders = true },
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
        .onDisappear {
            // Flush a pending debounce so a toggle made just before closing
            // the sheet isn't lost.
            autosaveTask?.cancel()
            autosaveNow()
        }
    }

    // MARK: - Autosave

    /// Debounced autosave: changes persist and re-arm the receive runtime
    /// without pressing Done, so Refresh/Verify always act on what's on
    /// screen. Drafts the explicit save would reject are skipped silently —
    /// Done still surfaces those errors.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard lastSavedDraft != nil, currentDraft != lastSavedDraft else { return }
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            autosaveNow()
        }
    }

    private func autosaveNow() {
        guard lastSavedDraft != nil, currentDraft != lastSavedDraft else { return }
        // A removed account stays removed.
        guard ChannelAccounts.account(connectionId: connectionId) != nil else { return }
        guard configurationValidationFailure() == nil else { return }
        guard (try? service.saveConfiguration(currentConfiguration())) != nil
        else { return }
        lastSavedDraft = currentDraft
        Task {
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            await MainActor.run { healthRefreshToken += 1 }
        }
    }

    // MARK: - Section state

    private func sectionCompleted(_ sectionId: String) -> Bool {
        switch AgentChannelProviderSetupSection(rawValue: sectionId) {
        case .connect:
            return botTokenSaved && appTokenSaved
        case .receiving:
            return !parseIds(readableChannelIdsText).isEmpty && !parseIds(senderAllowlistText).isEmpty
        case .routing:
            return inboundDispatchEnabled
        case .sending:
            return writeEnabled
        case .verify:
            return verifySucceeded
        case nil:
            return false
        }
    }

    private func sectionStatus(for sectionId: String) -> AgentChannelSetupSectionStatus {
        if attentionSectionId == sectionId { return .attention }
        return sectionCompleted(sectionId) ? .complete : .pending
    }

    // MARK: - Section content

    private var connectSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !isPendingAccount {
                ChannelAccountNameField(connectionId: connectionId, kind: .slack)
            }

            Text(
                "Osaurus connects out to Slack over Socket Mode — no webhook, public URL, or Request URL is needed.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            stepCreateAppSection
            stepBotTokenSection
            stepAppTokenSection
            if !isPendingAccount {
                ChannelAccountRemoveSection(connectionId: connectionId, kind: .slack) { dismiss() }
            }
        }
    }

    /// Checks the pasted tokens with Slack, then keeps the workspace as its
    /// own connection and opens the rest of its setup.
    private func connectNewAccount() {
        isConnectingAccount = true
        clearStatus()
        Task {
            do {
                let id = try await ChannelAccountCreation.addWorkspace(botToken: botToken, appToken: appToken)
                botToken = ""
                appToken = ""
                connectionId = id
                loadConfiguration()
                isConnectingAccount = false
                withAnimation(theme.motion.quick) {
                    selectedSectionId = AgentChannelProviderSetupSection.receiving.rawValue
                }
                refreshDiscovery(showStatus: false)
                await AgentChannelTransportSupervisor.shared.refreshAccountRuntimes()
            } catch {
                isConnectingAccount = false
                showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private var accessSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            accessSection
            appPostsSection
            advancedSection
        }
    }

    private var routingSectionContent: some View {
        ChannelRoutingSection(kind: .slack, connectionId: connectionId)
    }

    private var sendingSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            sendingSection
            ChannelPostingSection(kind: .slack, connectionId: connectionId)
        }
    }

    // MARK: - Guided setup steps

    private var appConfigurationURL: URL {
        let appId = SlackConnectionConfigurationStore.load(connectionId: connectionId).apiAppId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let appId, !appId.isEmpty, appId.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return URL(string: "https://api.slack.com/apps/\(appId)")!
        }
        return URL(string: "https://api.slack.com/apps")!
    }

    private var stepCreateAppSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Create the Slack app"))

            AgentChannelSetupLink(
                title: L("Open api.slack.com/apps and choose “Create New App” → “From a manifest”"),
                url: URL(string: "https://api.slack.com/apps")!
            )

            Button(action: copyRecommendedManifest) {
                Label(L("Copy the recommended app manifest"), systemImage: "doc.on.doc")
                    .textStyle(.footnote, weight: 500)
                    .foregroundColor(theme.text.link)
            }
            .buttonStyle(PlainButtonStyle())

            Text(
                "The manifest already enables Socket Mode and the message event subscriptions. You never enter a Request URL — Osaurus receives events over an outgoing connection.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "The manifest marks the bot as always online so it shows a green presence dot in Slack. For an existing app, reapply the manifest under “App Manifest” on api.slack.com/apps — the flag only takes effect after the manifest is saved again.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepBotTokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Install the app and paste the Bot Token"))

            Text(
                "In your Slack app, open “Install App”, install it to the workspace, then copy the Bot User OAuth Token.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelSecretField(
                label: L("Bot Token"),
                requirementHint: L("Required"),
                placeholder: L("xoxb-..."),
                text: $botToken,
                saved: botTokenSaved,
                onRemove: removeBotToken
            )

            Text(
                "Tokens are saved to the macOS Keychain when you load from Slack, test the connection, or press Done.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
        }
    }

    private var stepAppTokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Generate the App-Level Token (receiving)"))

            Text(
                "Required to receive messages. In your Slack app, open “Basic Information” → “App-Level Tokens”, generate a token with the connections:write scope, and paste it here. This powers Socket Mode — no webhook is involved.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelSetupLink(
                title: L("Open your Slack app settings"),
                url: appConfigurationURL
            )

            AgentChannelSecretField(
                label: L("App Token"),
                requirementHint: L("Required to receive messages"),
                placeholder: L("xapp-..."),
                text: $appToken,
                saved: appTokenSaved,
                onRemove: removeAppToken
            )
        }
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Choose conversations and people"))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            discovery == nil ? L("Connect to load workspace choices") : L("Slack workspace loaded")
                        )
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        Text(
                            discovery == nil
                                ? L("Add a bot token, then load channels and users from Slack.")
                                : L("Choose exactly where agents may read, write, and receive messages.")
                        )
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                    }

                    Spacer(minLength: 8)

                    AgentChannelSheetActionButton(
                        title: discovery == nil ? L("Load from Slack") : L("Refresh"),
                        busyTitle: L("Loading..."),
                        isBusy: isDiscovering,
                        action: { refreshDiscovery(showStatus: true) }
                    )
                    .disabled(isDiscovering || isTesting || isSaving || (!botTokenSaved && !hasPendingBotToken))
                }

                if let discovery {
                    workspaceSummary(discovery)
                    channelSelector(discovery)
                    senderSelector(discovery)

                    ForEach(discovery.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .textStyle(.micro)
                            .foregroundColor(theme.status.warning.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if botTokenSaved {
                    Text(
                        "Slack choices have not loaded yet. You can refresh or use Advanced manual IDs.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                }
            }
        }
    }

    private var sendingSection: some View {
        SettingsFieldRow(label: "Sending") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: "Allow Sending on Slack",
                    description: "Let agents post to write-allowlisted Slack channels. The global Sending switch in Channels must also be on.",
                    isOn: $writeEnabled.animation(theme.motion.quick)
                )

                if writeEnabled {
                    SettingsToggle(
                        title: "Allow Broadcast Mentions",
                        description: L(
                            "Permit @channel, @here, and <!subteam> mentions in outgoing Slack messages. Leave off unless the workspace expects that behavior."
                        ),
                        isOn: $allowBroadcastMentions
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// Messages an allowlisted person posts through an app with their own
    /// token carry the app's bot_id; they are ignored unless this is on.
    private var appPostsSection: some View {
        SettingsToggle(
            title: L("Accept Messages Sent Through Apps"),
            description: L(
                "Answer messages an allowlisted person posts through a Slack app or API with their own token, such as a phone shortcut. Slack marks these as app messages, so they are ignored by default."
            ),
            isOn: Binding(
                get: { acceptAppPostsFromAllowlistedSenders },
                set: { enabled in
                    // Turning this on widens who can start a run, so confirm first.
                    if enabled {
                        pendingAcceptAppPostsConfirm = true
                    } else {
                        acceptAppPostsFromAllowlistedSenders = false
                    }
                }
            )
        )
    }

    private var stepVerifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Verify an incoming message"))

            Text(
                "Changes save automatically, and Socket Mode receive starts once Connect and Receiving are complete. Send the test message below in an allowlisted channel from an authorized sender, then watch each stage appear here.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            testPromptRow

            AgentChannelTransportHealthView(
                connectionId: connectionId,
                transportId: SlackSocketModeTransportRuntime.transportId,
                title: L("Socket Mode receive"),
                notRunningHint: L(
                    "Socket Mode is not running. Add a bot token, an app-level token, readable channels, and authorized sender IDs to start it."
                ),
                refreshToken: healthRefreshToken
            )

            AgentChannelInboundActivityListView(
                connectionId: connectionId,
                emptyHint: L(
                    "No incoming Slack events yet this session. Send the test message and press “Verify incoming message”."
                ),
                refreshToken: activityRefreshToken
            )

            AgentChannelSheetActionButton(
                title: L("Verify incoming message"),
                busyTitle: L("Waiting for a Slack message..."),
                isBusy: isVerifying,
                action: verifyIncomingMessage
            )
            .disabled(isVerifying || isSaving || isTesting)
        }
    }

    /// Exact test message the user should send, mentioning the Slack bot user
    /// (a frequent failure is mentioning the Osaurus agent name instead).
    private var testPromptRow: some View {
        let botName = discovery?.identity.user
        let prompt = "@\(botName ?? "your-slack-bot") hello"
        return HStack(spacing: 8) {
            Text(prompt)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s6)
                .settingsChrome(.control)
            Button {
                #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                #endif
                showStatus(L("Test message copied"), isError: false)
            } label: {
                Image(systemName: "doc.on.doc")
                    .glyphSize(10, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.text.link)
            .help(Text("Copy the test message", bundle: .module))

            Text(
                botName == nil
                    ? L("Mention the Slack bot user, not the Osaurus agent name. Load from Slack to fill in the bot name.")
                    : L("Mention the Slack bot user, not the Osaurus agent name.")
            )
            .textStyle(.micro)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }


    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelSecretField(
                    label: L("Signing Secret"),
                    requirementHint: L("Not used by Socket Mode receive"),
                    placeholder: L("Paste your signing secret"),
                    text: $signingSecret,
                    saved: signingSecretSaved,
                    onRemove: removeSigningSecret
                )

                Text(
                    "The signing secret only verifies Slack HTTP (Events API) requests. Native Slack receive uses Socket Mode and never needs it; keep it only for future webhook compatibility.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Manual IDs are a fallback for restricted Slack scopes or entries not returned by discovery.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)

                AgentChannelMultilineSettingsField(
                    title: L("Workspace IDs"),
                    text: $configuredTeamIdsText,
                    placeholder: L("T0123ABC — one per line"),
                    help: L("Optional. Leave empty to allow only the bot token's own workspace.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Readable Channel IDs"),
                    text: $readableChannelIdsText,
                    placeholder: L("C0123ABC — one per line"),
                    help: L("Channels agents may list, read, and search.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Writable Channel IDs"),
                    text: $writableChannelIdsText,
                    placeholder: L("C0123ABC — one per line"),
                    help: L("Channels agents may post to when Slack sending and the global Sending switch are on.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Authorized Sender IDs"),
                    text: $senderAllowlistText,
                    placeholder: L("U0123ABC — one per line"),
                    help: L("Only these Slack users can trigger inbound handling.")
                )
                SettingsTextFieldRow(
                    label: "Default Read Limit",
                    text: $defaultReadLimit,
                    placeholder: "50",
                    help: "Default recent-message count for Slack reads. Clamped to 1-100."
                )
            }
        }
    }

    private func workspaceSummary(_ discovery: SlackConnectionDiscovery) -> some View {
        let selected = parseIds(configuredTeamIdsText).contains(discovery.identity.teamId)
        return HStack(spacing: 10) {
            Image(systemName: "building.2.fill")
                .glyphSize(13, weight: .semibold)
                .foregroundColor(theme.text.link)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.status.info.background))

            VStack(alignment: .leading, spacing: 2) {
                Text(discovery.identity.team ?? discovery.identity.teamId)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(discovery.identity.teamId)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer(minLength: 8)

            AgentChannelSelectorToggle(title: L("Workspace"), selected: selected) {
                configuredTeamIdsText = updatedIdText(
                    configuredTeamIdsText,
                    id: discovery.identity.teamId,
                    selected: !selected
                )
            }
        }
        .padding(theme.space.s8)
        .settingsChrome(.surface)
    }

    /// Names for DM conversations, resolved from the discovered user list.
    private func discoveredUserNames(_ discovery: SlackConnectionDiscovery) -> [String: String] {
        var names: [String: String] = [:]
        for user in discovery.users {
            names[user.id] = user.displayName
        }
        return names
    }

    private func channelSelector(_ discovery: SlackConnectionDiscovery) -> some View {
        let readableIds = Set(parseIds(readableChannelIdsText))
        let writableIds = Set(parseIds(writableChannelIdsText))
        let userNames = discoveredUserNames(discovery)
        let shaped = AgentChannelSelectorList.shape(
            discovery.conversations,
            query: channelSearch,
            fields: { [$0.resolvedDisplayName(userNames: userNames), $0.id, $0.kind] },
            state: {
                AgentChannelReadWriteSelection(
                    read: readableIds.contains($0.id),
                    write: writableIds.contains($0.id)
                )
            },
            isSelected: { $0.isSelected }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conversations", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Text("\(discovery.conversations.count) found")
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }

            Text(
                "Channels, private channels, and direct messages the bot can see. Read lets agents see a conversation, Write lets them post there.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelSelectorSearchField(
                placeholder: L("Search conversations by name or ID"),
                text: $channelSearch
            )

            AgentChannelSelectorListCard(
                shaped: shaped,
                emptyText: L("No matching Slack conversations")
            ) { item in
                channelSelectionRow(item.entry, access: item.state, userNames: userNames)
            }

            Text(
                "Channels stay unavailable until the bot is invited; direct messages work right away.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func channelSelectionRow(
        _ channel: SlackConversation,
        access: AgentChannelReadWriteSelection,
        userNames: [String: String]
    ) -> some View {
        let canUse = channel.isMember || channel.isIM || channel.isMPIM
        let readSelected = access.read
        let writeSelected = access.write
        let kind = AgentChannelRoomKind.from(providerKind: channel.kind)
        let name = channel.resolvedDisplayName(userNames: userNames)
        let nameIsResolved = name != channel.id
        return HStack(spacing: 9) {
            Image(systemName: kind.icon)
                .glyphSize(11, weight: .semibold)
                .foregroundColor(canUse ? theme.text.secondary : theme.text.tertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(nameIsResolved && kind.usesHashPrefix ? "#\(name)" : name)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(canUse ? theme.text.primary : theme.text.tertiary)
                        .lineLimit(1)
                    if let badge = kind.badgeLabel {
                        StatusChip(badge, tone: .neutral)
                    }
                    if !canUse {
                        Text("Invite bot", bundle: .module)
                            .font(SettingsFont.chip)
                            .foregroundColor(theme.status.warning.foreground)
                    }
                }
                Text(channel.id)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer(minLength: 6)

            AgentChannelSelectorToggle(title: L("Read"), selected: readSelected, enabled: canUse) {
                readableChannelIdsText = updatedIdText(
                    readableChannelIdsText,
                    id: channel.id,
                    selected: !readSelected
                )
            }
            AgentChannelSelectorToggle(title: L("Write"), selected: writeSelected, enabled: canUse) {
                writableChannelIdsText = updatedIdText(
                    writableChannelIdsText,
                    id: channel.id,
                    selected: !writeSelected
                )
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
    }

    private func senderSelector(_ discovery: SlackConnectionDiscovery) -> some View {
        let users = eligibleUsers(discovery)
        let allowedIds = Set(parseIds(senderAllowlistText))
        let allowedCount = users.filter { allowedIds.contains($0.id) }.count
        let shaped = AgentChannelSelectorList.shape(
            users,
            query: userSearch,
            fields: { [$0.displayName, $0.id, $0.name ?? ""] },
            state: { allowedIds.contains($0.id) },
            isSelected: { $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Authorized Senders", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Text("\(allowedCount) allowed · \(users.count) people", bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }

            AgentChannelSelectorSearchField(
                placeholder: L("Search people by name or ID"),
                text: $userSearch
            )

            AgentChannelSelectorListCard(
                shaped: shaped,
                emptyText: L("No matching Slack users"),
                maxHeight: 200
            ) { item in
                userSelectionRow(item.entry, selected: item.state)
            }

            Text(
                "Only selected people may trigger inbound handling. An empty sender list keeps Slack receive disabled.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func userSelectionRow(_ user: SlackUser, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "person.crop.circle.fill")
                .glyphSize(15)
                .foregroundColor(theme.text.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Text(user.name.map { "@\($0) · \(user.id)" } ?? user.id)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            AgentChannelSelectorToggle(title: L("Allow"), selected: selected) {
                senderAllowlistText = updatedIdText(
                    senderAllowlistText,
                    id: user.id,
                    selected: !selected
                )
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
    }

    private func eligibleUsers(_ discovery: SlackConnectionDiscovery) -> [SlackUser] {
        discovery.users.filter { user in
            !user.deleted
                && !user.isBot
                && !user.isAppUser
                && user.id != discovery.identity.userId
        }
    }

    private func loadConfiguration() {
        let configuration = SlackConnectionConfigurationStore.load(connectionId: connectionId)
        configuredTeamIdsText = configuration.configuredTeamIds.joined(separator: "\n")
        readableChannelIdsText = configuration.readableChannelIds.joined(separator: "\n")
        writableChannelIdsText = configuration.writableChannelIds.joined(separator: "\n")
        senderAllowlistText = configuration.senderAllowlist.joined(separator: "\n")
        writeEnabled = configuration.writeEnabled
        allowBroadcastMentions = configuration.allowBroadcastMentions
        acceptAppPostsFromAllowlistedSenders = configuration.acceptAppPostsFromAllowlistedSenders
        defaultReadLimit = "\(configuration.defaultReadLimit)"
        Task {
            let presence = await service.credentialPresenceOffMain()
            botTokenSaved = presence.botToken
            signingSecretSaved = presence.signingSecret
            appTokenSaved = presence.appToken
        }
        // Arm autosave only after the stored configuration has hydrated the
        // draft, so hydration itself is never mistaken for an edit.
        lastSavedDraft = currentDraft
    }

    private var hasPendingBotToken: Bool {
        !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshDiscovery(showStatus announce: Bool) {
        isDiscovering = true
        Task {
            guard await persistPendingSecrets() else {
                isDiscovering = false
                return
            }
            do {
                let loaded = try await service.discoverConfigurationOptions()
                await MainActor.run {
                    applyDiscovery(loaded)
                    isDiscovering = false
                    if announce {
                        showStatus(
                            L("Slack workspace loaded"),
                            details: loaded.warnings,
                            isError: false
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    isDiscovering = false
                    if announce {
                        showStatus(error.localizedDescription, isError: true)
                    }
                }
            }
        }
    }

    private func applyDiscovery(_ loaded: SlackConnectionDiscovery) {
        discovery = loaded
        ChannelAccountNaming.adopt(loaded.identity.team, connectionId: connectionId)
        if parseIds(configuredTeamIdsText).isEmpty {
            configuredTeamIdsText = loaded.identity.teamId
        }
    }

    private func copyRecommendedManifest() {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.recommendedManifest, forType: .string)
        #endif
        showStatus(L("Recommended Slack manifest copied"), isError: false)
    }

    /// Persist any pasted secrets to Keychain before the configuration save.
    /// Awaited off the main thread so a slow securityd never beachballs the
    /// Save/Test buttons.
    private func persistPendingSecrets() async -> Bool {
        let pendingBot = hasPendingBotToken ? botToken : nil
        let trimmedSigning = signingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingSigning = trimmedSigning.isEmpty ? nil : signingSecret
        let trimmedApp = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingApp = trimmedApp.isEmpty ? nil : appToken
        do {
            try await service.saveCredentialsOffMain(
                botToken: pendingBot,
                signingSecret: pendingSigning,
                appToken: pendingApp
            )
            if pendingBot != nil {
                botToken = ""
                botTokenSaved = true
            }
            if pendingSigning != nil {
                signingSecret = ""
                signingSecretSaved = true
            }
            if pendingApp != nil {
                appToken = ""
                appTokenSaved = true
            }
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func removeBotToken() {
        botToken = ""
        botTokenSaved = false
        discovery = nil
        Task {
            await service.deleteBotTokenOffMain()
            refreshReceiveRuntime()
        }
        showStatus(L("Slack bot token removed"), isError: false)
    }

    private func removeSigningSecret() {
        signingSecret = ""
        signingSecretSaved = false
        Task { await service.deleteSigningSecretOffMain() }
        showStatus(L("Slack signing secret removed"), isError: false)
    }

    private func removeAppToken() {
        appToken = ""
        appTokenSaved = false
        Task {
            await service.deleteAppTokenOffMain()
            refreshReceiveRuntime()
        }
        showStatus(L("Slack Socket Mode app token removed"), isError: false)
    }

    @discardableResult
    private func currentConfiguration() -> SlackConnectionConfiguration {
        let previous = SlackConnectionConfigurationStore.load(connectionId: connectionId)
        return SlackConnectionConfiguration(
            configuredTeamIds: parseIds(configuredTeamIdsText),
            readableChannelIds: parseIds(readableChannelIdsText),
            writableChannelIds: parseIds(writableChannelIdsText),
            senderAllowlist: parseIds(senderAllowlistText),
            writeEnabled: writeEnabled,
            defaultReadLimit: Int(defaultReadLimit) ?? 50,
            allowBroadcastMentions: allowBroadcastMentions,
            botUserId: previous.botUserId,
            botId: previous.botId,
            apiAppId: previous.apiAppId,
            workspaceName: previous.workspaceName,
            acceptAppPostsFromAllowlistedSenders: acceptAppPostsFromAllowlistedSenders
        )
    }

    private func saveConfiguration() -> Bool {
        if let failure = configurationValidationFailure() {
            showStatus(failure.message, isError: true, section: failure.section)
            return false
        }
        do {
            try service.saveConfiguration(currentConfiguration())
            lastSavedDraft = currentDraft
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    /// Persist the configuration, hold the Save button busy until the receive
    /// supervisor has re-evaluated the runtime, then close the sheet — unless
    /// the user wants receive (dispatch is on) and receive cannot actually
    /// run. In that case the sheet stays open with the exact blockers rather
    /// than dismissing on a superficially successful save.
    private func saveAndDismiss() {
        autosaveTask?.cancel()
        isSaving = true
        Task {
            guard await persistPendingSecrets(), saveConfiguration() else {
                isSaving = false
                return
            }
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            guard inboundDispatchEnabled else {
                await MainActor.run {
                    isSaving = false
                    _ = ToastManager.shared.success(L("Slack settings saved"))
                    dismiss()
                }
                return
            }
            let diagnostics = await service.diagnostics()
            let report = AgentChannelLiveProofReadiness.slack(diagnostics)
            await MainActor.run {
                isSaving = false
                healthRefreshToken += 1
                if report.isReadyForLiveProof {
                    _ = ToastManager.shared.success(L("Slack settings saved — receive is ready"))
                    dismiss()
                } else {
                    showStatus(
                        L("Saved, but Slack receive is not ready yet"),
                        details: report.blockers + report.notes,
                        isError: true,
                        section: .verify
                    )
                }
            }
        }
    }

    /// Persist the current draft first so diagnostics always test what the
    /// user sees in the form, not a stale save.
    private func testConnection() {
        autosaveTask?.cancel()
        isTesting = true
        Task {
            guard await persistPendingSecrets(), saveConfiguration() else {
                isTesting = false
                return
            }
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            let discoveryResult: Result<SlackConnectionDiscovery, any Error>
            do {
                discoveryResult = .success(
                    try await service.discoverConfigurationOptions()
                )
            } catch {
                discoveryResult = .failure(error)
            }
            let diagnostics = await service.diagnostics()
            let report = AgentChannelLiveProofReadiness.slack(diagnostics)
            await MainActor.run {
                isTesting = false
                healthRefreshToken += 1
                let presentation = AgentChannelStatusPresentation.diagnostics(
                    status: diagnostics.status
                )
                // The readiness report is the single checklist source: it
                // folds diagnostics failures, allowlist gaps, app-token
                // validation, and environment warnings into ordered blockers.
                var details = report.blockers + report.notes
                switch discoveryResult {
                case .success(let loaded):
                    applyDiscovery(loaded)
                    details.append(contentsOf: loaded.warnings)
                case .failure(let error):
                    details.append(error.localizedDescription)
                }
                showStatus(
                    presentation.label,
                    details: details,
                    isError: !report.blockers.isEmpty
                )
            }
        }
    }

    /// Wait for a fresh inbound Slack event and report the exact stage it
    /// reached (received, stored, dispatched, replied) or the boundary that
    /// stopped it, instead of a generic "connected" result.
    private func verifyIncomingMessage() {
        isVerifying = true
        showStatus(
            L("Waiting for a Slack message. Send the test message now from an authorized sender in a readable channel."),
            isError: false
        )
        let start = Date()
        Task {
            let deadline = start.addingTimeInterval(90)
            var observed: [AgentChannelInboundActivityEvent] = []
            while Date() < deadline {
                observed = await AgentChannelInboundActivityCenter.shared.events(
                    connectionId: connectionId,
                    since: start
                )
                if !observed.isEmpty {
                    await MainActor.run {
                        activityRefreshToken += 1
                        healthRefreshToken += 1
                    }
                    if let terminal = terminalVerifyEvent(in: observed) {
                        await MainActor.run {
                            isVerifying = false
                            presentVerifyOutcome(terminal)
                        }
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            await MainActor.run {
                isVerifying = false
                activityRefreshToken += 1
                if let latest = observed.last {
                    presentVerifyOutcome(latest, timedOutWaitingForMore: true)
                } else {
                    showStatus(
                        L("No Slack event arrived within 90 seconds."),
                        details: verifyNoEventGuidance(),
                        isError: true
                    )
                }
            }
        }
    }

    /// Stages that end the verification wait. `dispatched` is terminal only
    /// when auto-reply is off, since a reply confirmation will never come.
    private func terminalVerifyEvent(
        in events: [AgentChannelInboundActivityEvent]
    ) -> AgentChannelInboundActivityEvent? {
        events.last { event in
            switch event.stage {
            case .rejected, .dispatchSuppressed, .failed, .replySent, .agentReplied:
                return true
            case .dispatched:
                return !inboundAutoReplyEnabled
            case .received, .stored:
                return false
            }
        }
    }

    private func presentVerifyOutcome(
        _ event: AgentChannelInboundActivityEvent,
        timedOutWaitingForMore: Bool = false
    ) {
        let label = AgentChannelInboundActivityPresentation.label(for: event.stage)
        var details: [String] = []
        if let guidance = AgentChannelInboundActivityPresentation.guidance(
            stage: event.stage,
            reason: event.reason
        ) {
            details.append(guidance)
        }
        let isError: Bool
        switch event.stage {
        case .rejected, .dispatchSuppressed, .failed:
            isError = true
        case .received, .stored, .dispatched, .agentReplied, .replySent:
            isError = timedOutWaitingForMore
        }
        if timedOutWaitingForMore {
            details.append(
                L("The event stopped at this stage before the wait expired; check the recent events list above.")
            )
        }
        if !isError {
            verifySucceeded = true
        }
        showStatus(label, details: details, isError: isError)
    }

    private func verifyNoEventGuidance() -> [String] {
        var guidance = [
            L("Confirm the message was sent in a channel selected as readable, by a person in Authorized Senders."),
            L("Confirm the Slack app has Socket Mode on and the app_mention/message event subscriptions (the recommended manifest includes them)."),
            L("Confirm the bot has been invited to the channel (/invite @your-bot)."),
            L("Mention the Slack bot user, not the Osaurus agent name."),
        ]
        if let warning = OsaurusRunningInstanceInspector.duplicateInstanceWarning(
            instanceCount: OsaurusRunningInstanceInspector.runningInstanceCount()
        ) {
            guidance.append(warning)
        }
        return guidance
    }

    /// Restart the Socket Mode runtime after a config change, then refresh the
    /// inline health card once the supervisor has re-evaluated.
    private func refreshReceiveRuntime() {
        Task {
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            await MainActor.run { healthRefreshToken += 1 }
        }
    }

    /// Show an inline status message. Passing a `section` with an error also
    /// flags that section in the rail and moves focus to it, so validation
    /// failures land the user on the fields that need fixing.
    private func showStatus(
        _ message: String,
        details: [String] = [],
        isError: Bool,
        section: AgentChannelProviderSetupSection? = nil
    ) {
        statusMessage = message
        statusDetails = details
        statusIsError = isError
        if isError, let section {
            attentionSectionId = section.rawValue
            withAnimation(theme.motion.quick) {
                selectedSectionId = section.rawValue
            }
        } else if !isError {
            attentionSectionId = nil
        }
    }

    private func clearStatus() {
        statusMessage = nil
        statusDetails = []
    }

    private func parseIds(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ", \n\t")
        return SlackConnectionConfiguration.normalizedIds(
            text.components(separatedBy: separators)
        )
    }

    private func updatedIdText(_ text: String, id: String, selected: Bool) -> String {
        var ids = parseIds(text)
        if selected {
            if !ids.contains(id) {
                ids.append(id)
            }
        } else {
            ids.removeAll { $0 == id }
        }
        return ids.joined(separator: "\n")
    }

    /// Pre-save validation, with the setup section each failure belongs to so
    /// the sheet can move focus to the fields that need fixing.
    private func configurationValidationFailure()
        -> (message: String, section: AgentChannelProviderSetupSection)?
    {
        let groups: [(label: String, ids: [String], prefixes: Set<Character>)] = [
            (L("Workspace IDs"), parseIds(configuredTeamIdsText), ["T"]),
            (L("Readable Channel IDs"), parseIds(readableChannelIdsText), ["C", "G", "D"]),
            (L("Writable Channel IDs"), parseIds(writableChannelIdsText), ["C", "G", "D"]),
            (L("Authorized Sender IDs"), parseIds(senderAllowlistText), ["U", "W"]),
        ]
        for group in groups {
            if let invalid = group.ids.first(where: {
                !SlackConnectionConfiguration.isValidSlackId(
                    $0,
                    allowedPrefixes: group.prefixes
                )
            }) {
                return ("\(group.label) contains invalid Slack ID `\(invalid)`.", .receiving)
            }
        }
        guard Int(defaultReadLimit) != nil else {
            return (L("Default Read Limit must be a number from 1 to 100."), .receiving)
        }
        if inboundDispatchEnabled, inboundAutoReplyEnabled {
            guard writeEnabled else {
                return (L("Enable Slack sending before automatic channel replies."), .sending)
            }
            let missing = ChannelAgentRoster.autoReplyRoomsNotWritable(
                ChannelAgentRoster.replyingRules(channelEvents),
                readable: parseIds(readableChannelIdsText), writable: parseIds(writableChannelIdsText))
            guard missing.isEmpty else {
                return (
                    L(
                        "Automatic replies need these Slack channels to be writable: \(missing.joined(separator: ", ")). Make them writable, or set their routing rules to After approval."
                    ),
                    .receiving
                )
            }
        }
        return nil
    }

    /// Slack has no runtime presence API for bot tokens: the only supported
    /// way to show the bot with a green presence dot is the static
    /// `always_online` manifest flag. Existing apps must reapply the manifest
    /// (App Manifest page) for the change to take effect.
    static let recommendedManifest = """
    display_information:
      name: Osaurus
    features:
      bot_user:
        display_name: Osaurus
        always_online: true
    oauth_config:
      scopes:
        bot:
          - app_mentions:read
          - channels:history
          - channels:read
          - chat:write
          - groups:history
          - groups:read
          - im:history
          - im:read
          - mpim:history
          - mpim:read
          - users:read
    settings:
      event_subscriptions:
        bot_events:
          - app_mention
          - message.channels
          - message.groups
          - message.im
          - message.mpim
      interactivity:
        is_enabled: false
      org_deploy_enabled: false
      socket_mode_enabled: true
    """
}
