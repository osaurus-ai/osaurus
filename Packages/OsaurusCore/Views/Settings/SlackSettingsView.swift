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

    @State private var botToken: String = ""
    @State private var signingSecret: String = ""
    @State private var appToken: String = ""
    @State private var configuredTeamIdsText: String = ""
    @State private var readableChannelIdsText: String = ""
    @State private var writableChannelIdsText: String = ""
    @State private var senderAllowlistText: String = ""
    @State private var writeEnabled: Bool = false
    @State private var allowBroadcastMentions: Bool = false
    @State private var defaultReadLimit: String = "50"
    @State private var inboundDispatchEnabled = false
    @State private var inboundAgentId: UUID?
    @State private var inboundRoutes: [AgentChannelDispatchRoute] = []
    @State private var inboundRequireMention = true
    @State private var inboundContinueThreads = true
    @State private var inboundAutoReplyEnabled = false
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
    @State private var additionalBotToken = ""
    @State private var additionalAppToken = ""
    @State private var isAddingWorkspace = false
    @State private var pendingWorkspaceDiscovery: SlackConnectionDiscovery?
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
        var defaultReadLimit: String
        var inboundDispatchEnabled: Bool
        var inboundAgentId: UUID?
        var inboundRoutes: [AgentChannelDispatchRoute]
        var inboundRequireMention: Bool
        var inboundContinueThreads: Bool
        var inboundAutoReplyEnabled: Bool
    }

    private var currentDraft: DraftSnapshot {
        DraftSnapshot(
            configuredTeamIdsText: configuredTeamIdsText,
            readableChannelIdsText: readableChannelIdsText,
            writableChannelIdsText: writableChannelIdsText,
            senderAllowlistText: senderAllowlistText,
            writeEnabled: writeEnabled,
            allowBroadcastMentions: allowBroadcastMentions,
            defaultReadLimit: defaultReadLimit,
            inboundDispatchEnabled: inboundDispatchEnabled,
            inboundAgentId: inboundAgentId,
            inboundRoutes: inboundRoutes,
            inboundRequireMention: inboundRequireMention,
            inboundContinueThreads: inboundContinueThreads,
            inboundAutoReplyEnabled: inboundAutoReplyEnabled
        )
    }

    var body: some View {
        AgentChannelSetupScaffold(
            icon: AgentChannelKind.slack.icon,
            gradient: AgentChannelKind.slack.brandGradient,
            title: AgentChannelKind.slack.displayName,
            subtitle: L("Read and reply in allowlisted channels and DMs"),
            sections: AgentChannelProviderSetupSection.sections,
            selection: $selectedSectionId,
            sectionStatus: sectionStatus(for:),
            onBack: onBack
        ) { sectionId in
            VStack(alignment: .leading, spacing: 20) {
                switch AgentChannelProviderSetupSection(rawValue: sectionId) {
                case .connect:
                    connectSectionContent
                case .access:
                    accessSectionContent
                case .behavior:
                    behaviorSectionContent
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
        guard configurationValidationFailure() == nil else { return }
        guard (try? SlackConnectionService.shared.saveConfiguration(currentConfiguration())) != nil
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
        case .access:
            return !parseIds(readableChannelIdsText).isEmpty && !parseIds(senderAllowlistText).isEmpty
        case .behavior:
            return (inboundDispatchEnabled && (inboundAgentId != nil || !inboundRoutes.isEmpty)) || writeEnabled
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
            Text(
                "Osaurus connects out to Slack over Socket Mode — no webhook, public URL, or Request URL is needed.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            stepCreateAppSection
            SettingsDivider()
            stepBotTokenSection
            SettingsDivider()
            stepAppTokenSection
        }
    }

    private var accessSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            accessSection
            SettingsDivider()
            advancedSection
        }
    }

    private var behaviorSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepDispatchSection
            SettingsDivider()
            sendingSection
        }
    }

    // MARK: - Guided setup steps

    private var appConfigurationURL: URL {
        let appId = SlackConnectionConfigurationStore.load().apiAppId?
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())

            Text(
                "The manifest already enables Socket Mode and the message event subscriptions. You never enter a Request URL — Osaurus receives events over an outgoing connection.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "The manifest marks the bot as always online so it shows a green presence dot in Slack. For an existing app, reapply the manifest under “App Manifest” on api.slack.com/apps — the flag only takes effect after the manifest is saved again.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
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
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelSecretField(
                label: L("Bot Token"),
                requirementHint: L("Required"),
                placeholder: L("xoxb-..."),
                text: $botToken,
                saved: botTokenSaved,
                onRemove: removeBotToken
            )

            additionalWorkspaces

            Text(
                "Tokens are saved to the macOS Keychain when you load from Slack, test the connection, or press Done.",
                bundle: .module
            )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var stepAppTokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Generate the App-Level Token (receiving)"))

            Text(
                "Required to receive messages. In your Slack app, open “Basic Information” → “App-Level Tokens”, generate a token with the connections:write scope, and paste it here. This powers Socket Mode — no webhook is involved.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
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

    private var additionalWorkspaces: some View {
        VStack(alignment: .leading, spacing: 10) {
            let accounts = SlackConnectionConfigurationStore.load().workspaceAccounts
            if !accounts.isEmpty {
                Text("Additional Workspaces", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                ForEach(accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.teamName ?? account.teamId)
                                .font(.system(size: 11, weight: .medium))
                            Text(account.teamId)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                        }
                        Spacer()
                        Button(L("Remove")) { removeWorkspace(account.teamId) }
                            .buttonStyle(.plain)
                            .foregroundColor(theme.errorColor)
                    }
                }
            }

            if isAddingWorkspace {
                SecureField(L("Additional workspace bot token (xoxb-...)"), text: $additionalBotToken)
                    .textFieldStyle(.roundedBorder)
                SecureField(L("Additional workspace app token (optional xapp-...)"), text: $additionalAppToken)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L("Cancel")) {
                        isAddingWorkspace = false
                        additionalBotToken = ""
                        additionalAppToken = ""
                        pendingWorkspaceDiscovery = nil
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    AgentChannelSheetActionButton(
                        title: L("Load Workspace"),
                        busyTitle: L("Loading..."),
                        isBusy: isDiscovering,
                        action: loadAdditionalWorkspace
                    )
                    .disabled(additionalBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let pendingWorkspaceDiscovery {
                    Text(
                        "Loaded \(pendingWorkspaceDiscovery.identity.team ?? pendingWorkspaceDiscovery.identity.teamId). Choose its channels and authorized senders below, then press Done.",
                        bundle: .module
                    )
                    .font(.system(size: 10))
                    .foregroundColor(theme.accentColor)
                }
            } else {
                Button {
                    isAddingWorkspace = true
                } label: {
                    Label(L("Add another Slack workspace"), systemImage: "plus.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accentColor)
            }
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        Text(
                            discovery == nil
                                ? L("Add a bot token, then load channels and users from Slack.")
                                : L("Choose exactly where agents may read, write, and receive messages.")
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
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
                            .font(.system(size: 10))
                            .foregroundColor(theme.warningColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if botTokenSaved {
                    Text(
                        "Slack choices have not loaded yet. You can refresh or use Advanced manual IDs.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    private var sendingSection: some View {
        SettingsSubsection(label: L("Sending")) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: L("Allow Sending on Slack"),
                    description: L("Let agents post to write-allowlisted Slack channels. The global Sending switch in Channels must also be on."),
                    isOn: $writeEnabled.animation(.easeOut(duration: 0.2))
                )

                if writeEnabled {
                    SettingsToggle(
                        title: L("Allow Broadcast Mentions"),
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

    private var stepDispatchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Reply to incoming messages"))

            SettingsToggle(
                title: L("Reply with an Agent"),
                description: L(
                    "Choose which agent answers verified, allowlisted Slack messages. Replies run in a private channel session; external-surface tool restrictions still apply."
                ),
                isOn: $inboundDispatchEnabled.animation(.easeOut(duration: 0.2))
            )

            if inboundDispatchEnabled {
                AgentChannelDispatchRoutingEditor(
                    roomNoun: L("channel"),
                    rooms: routableRooms,
                    defaultAgentId: $inboundAgentId,
                    routes: $inboundRoutes
                )
                SettingsToggle(
                    title: L("Require an @mention"),
                    description: L("Start new Slack conversations only when the bot is mentioned."),
                    isOn: $inboundRequireMention
                )
                SettingsToggle(
                    title: L("Continue Participating Threads"),
                    description: L(
                        "Accept follow-ups without another mention only after Osaurus has replied in that Slack thread."
                    ),
                    isOn: $inboundContinueThreads
                )
                SettingsToggle(
                    title: L("Reply Automatically"),
                    description: L(
                        "Post the selected agent's sanitized response in the same thread. Slack and global writes plus the write allowlist still apply."
                    ),
                    isOn: $inboundAutoReplyEnabled
                )
            }
        }
    }

    private var stepVerifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Verify an incoming message"))

            Text(
                "Changes save automatically, and Socket Mode receive starts once Connect and Access are complete. Send the test message below in an allowlisted channel from an authorized sender, then watch each stage appear here.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            testPromptRow

            AgentChannelTransportHealthView(
                connectionId: AgentChannelConnection.nativeSlackConnectionId,
                transportId: SlackSocketModeTransportRuntime.transportId,
                title: L("Socket Mode receive"),
                notRunningHint: L(
                    "Socket Mode is not running. Add a bot token, an app-level token, readable channels, and authorized sender IDs to start it."
                ),
                refreshToken: healthRefreshToken
            )

            AgentChannelInboundActivityListView(
                connectionId: AgentChannelConnection.nativeSlackConnectionId,
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
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.inputBackground)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.inputBorder, lineWidth: 1))
                )
            Button {
                #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                #endif
                showStatus(L("Test message copied"), isError: false)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accentColor)
            .help(Text("Copy the test message", bundle: .module))

            Text(
                botName == nil
                    ? L("Mention the Slack bot user, not the Osaurus agent name. Load from Slack to fill in the bot name.")
                    : L("Mention the Slack bot user, not the Osaurus agent name.")
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Discovered conversations mapped into the shared routing editor's
    /// room shape, member channels first. DMs resolve to the person's name.
    private var routableRooms: [AgentChannelRoutableRoom] {
        guard let discovery else { return [] }
        let userNames = discoveredUserNames(discovery)
        return discovery.conversations
            .sorted { ($0.isMember ? 0 : 1, $0.name ?? $0.id) < ($1.isMember ? 0 : 1, $1.name ?? $1.id) }
            .map { conversation in
                let name = conversation.resolvedDisplayName(userNames: userNames)
                let kind = AgentChannelRoomKind.from(providerKind: conversation.kind)
                return AgentChannelRoutableRoom(
                    id: conversation.id,
                    name: name != conversation.id && kind.usesHashPrefix ? "#\(name)" : name
                )
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
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Manual IDs are a fallback for restricted Slack scopes or entries not returned by discovery.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

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
                StyledSettingsTextField(
                    label: L("Default Read Limit"),
                    text: $defaultReadLimit,
                    placeholder: "50",
                    help: L("Default recent-message count for Slack reads. Clamped to 1-100.")
                )
            }
        }
    }

    private func workspaceSummary(_ discovery: SlackConnectionDiscovery) -> some View {
        let selected = parseIds(configuredTeamIdsText).contains(discovery.identity.teamId)
        return HStack(spacing: 10) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.accentColor.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text(discovery.identity.team ?? discovery.identity.teamId)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(discovery.identity.teamId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
        )
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(discovery.conversations.count) found")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            Text(
                "Channels, private channels, and direct messages the bot can see. Read lets agents see a conversation, Write lets them post there.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
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
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(canUse ? theme.secondaryText : theme.tertiaryText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(nameIsResolved && kind.usesHashPrefix ? "#\(name)" : name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(canUse ? theme.primaryText : theme.tertiaryText)
                        .lineLimit(1)
                    if let badge = kind.badgeLabel {
                        Text(badge)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                    if !canUse {
                        Text("Invite bot", bundle: .module)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(theme.warningColor)
                    }
                }
                Text(channel.id)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(allowedCount) allowed · \(users.count) people", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
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
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func userSelectionRow(_ user: SlackUser, selected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(theme.secondaryText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(user.name.map { "@\($0) · \(user.id)" } ?? user.id)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
        let configuration = SlackConnectionConfigurationStore.load()
        configuredTeamIdsText = configuration.configuredTeamIds.joined(separator: "\n")
        readableChannelIdsText = configuration.readableChannelIds.joined(separator: "\n")
        writableChannelIdsText = configuration.writableChannelIds.joined(separator: "\n")
        senderAllowlistText = configuration.senderAllowlist.joined(separator: "\n")
        writeEnabled = configuration.writeEnabled
        allowBroadcastMentions = configuration.allowBroadcastMentions
        defaultReadLimit = "\(configuration.defaultReadLimit)"
        inboundDispatchEnabled = configuration.inboundDispatch.enabled
        inboundAgentId = configuration.inboundDispatch.targetAgentId
        inboundRoutes = configuration.inboundDispatch.routes
        inboundRequireMention = configuration.inboundDispatch.requireMention
        inboundContinueThreads = configuration.inboundDispatch.continueThreads
        inboundAutoReplyEnabled = configuration.inboundDispatch.autoReplyEnabled
        Task {
            let presence = await SlackConnectionService.shared.credentialPresenceOffMain()
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
                let loaded = try await SlackConnectionService.shared.discoverConfigurationOptions()
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
            try await SlackConnectionService.shared.saveCredentialsOffMain(
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

    private func loadAdditionalWorkspace() {
        let token = additionalBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        isDiscovering = true
        Task {
            do {
                let loaded = try await SlackConnectionService.shared
                    .discoverConfigurationOptions(botToken: token)
                await MainActor.run {
                    isDiscovering = false
                    pendingWorkspaceDiscovery = loaded
                    discovery = loaded
                    configuredTeamIdsText = updatedIdText(
                        configuredTeamIdsText,
                        id: loaded.identity.teamId,
                        selected: true
                    )
                    showStatus(
                        L("Workspace loaded. Choose channels and senders — changes save automatically."),
                        details: loaded.warnings,
                        isError: false
                    )
                }
            } catch {
                await MainActor.run {
                    isDiscovering = false
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func persistAdditionalWorkspace() -> Bool {
        guard let pendingWorkspaceDiscovery else { return true }
        let channelIds = Set(pendingWorkspaceDiscovery.conversations.map(\.id))
        let userIds = Set(pendingWorkspaceDiscovery.users.map(\.id))
        do {
            try SlackConnectionService.shared.saveWorkspaceAccount(
                discovery: pendingWorkspaceDiscovery,
                botToken: additionalBotToken,
                appToken: additionalAppToken,
                readableChannelIds: parseIds(readableChannelIdsText).filter(channelIds.contains),
                writableChannelIds: parseIds(writableChannelIdsText).filter(channelIds.contains),
                senderAllowlist: parseIds(senderAllowlistText).filter(userIds.contains)
            )
            additionalBotToken = ""
            additionalAppToken = ""
            self.pendingWorkspaceDiscovery = nil
            isAddingWorkspace = false
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func removeWorkspace(_ teamId: String) {
        let account = SlackConnectionConfigurationStore.load().workspaceAccounts.first { $0.teamId == teamId }
        do {
            try SlackConnectionService.shared.removeWorkspaceAccount(teamId: teamId)
            if let account {
                readableChannelIdsText = parseIds(readableChannelIdsText)
                    .filter { !account.readableChannelIds.contains($0) }.joined(separator: "\n")
                writableChannelIdsText = parseIds(writableChannelIdsText)
                    .filter { !account.writableChannelIds.contains($0) }.joined(separator: "\n")
                senderAllowlistText = parseIds(senderAllowlistText)
                    .filter { !account.senderAllowlist.contains($0) }.joined(separator: "\n")
            }
            configuredTeamIdsText = parseIds(configuredTeamIdsText)
                .filter { $0 != teamId }.joined(separator: "\n")
            refreshReceiveRuntime()
            showStatus(L("Slack workspace removed."), isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func removeBotToken() {
        botToken = ""
        botTokenSaved = false
        discovery = nil
        Task {
            await SlackConnectionService.shared.deleteBotTokenOffMain()
            refreshReceiveRuntime()
        }
        showStatus(L("Slack bot token removed"), isError: false)
    }

    private func removeSigningSecret() {
        signingSecret = ""
        signingSecretSaved = false
        Task { await SlackConnectionService.shared.deleteSigningSecretOffMain() }
        showStatus(L("Slack signing secret removed"), isError: false)
    }

    private func removeAppToken() {
        appToken = ""
        appTokenSaved = false
        Task {
            await SlackConnectionService.shared.deleteAppTokenOffMain()
            refreshReceiveRuntime()
        }
        showStatus(L("Slack Socket Mode app token removed"), isError: false)
    }

    @discardableResult
    private func currentConfiguration() -> SlackConnectionConfiguration {
        let previous = SlackConnectionConfigurationStore.load()
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
            inboundDispatch: AgentChannelInboundDispatchConfiguration(
                enabled: inboundDispatchEnabled,
                targetAgentId: inboundAgentId,
                routes: inboundRoutes,
                requireMention: inboundRequireMention,
                continueThreads: inboundContinueThreads,
                autoReplyEnabled: inboundAutoReplyEnabled
            ),
            workspaceAccounts: previous.workspaceAccounts
        )
    }

    private func saveConfiguration() -> Bool {
        if let failure = configurationValidationFailure() {
            showStatus(failure.message, isError: true, section: failure.section)
            return false
        }
        do {
            try SlackConnectionService.shared.saveConfiguration(currentConfiguration())
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
            guard await persistPendingSecrets(), saveConfiguration(), persistAdditionalWorkspace() else {
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
            let diagnostics = await SlackConnectionService.shared.diagnostics()
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
            guard await persistPendingSecrets(), saveConfiguration(), persistAdditionalWorkspace() else {
                isTesting = false
                return
            }
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            let discoveryResult: Result<SlackConnectionDiscovery, any Error>
            do {
                discoveryResult = .success(
                    try await SlackConnectionService.shared.discoverConfigurationOptions()
                )
            } catch {
                discoveryResult = .failure(error)
            }
            let diagnostics = await SlackConnectionService.shared.diagnostics()
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
                    connectionId: AgentChannelConnection.nativeSlackConnectionId,
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
            withAnimation(.easeOut(duration: 0.15)) {
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
                return ("\(group.label) contains invalid Slack ID `\(invalid)`.", .access)
            }
        }
        guard Int(defaultReadLimit) != nil else {
            return (L("Default Read Limit must be a number from 1 to 100."), .access)
        }
        if inboundDispatchEnabled, inboundAgentId == nil, inboundRoutes.isEmpty {
            return (
                L("Choose an agent to reply, or add a rule for incoming Slack messages."),
                .behavior
            )
        }
        if inboundDispatchEnabled, inboundAutoReplyEnabled {
            guard writeEnabled else {
                return (L("Enable Slack sending before automatic channel replies."), .behavior)
            }
            let readable = Set(parseIds(readableChannelIdsText))
            let writable = Set(parseIds(writableChannelIdsText))
            guard readable.isSubset(of: writable) else {
                return (
                    L("Every readable Slack channel must also be writable when automatic replies are enabled."),
                    .access
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
