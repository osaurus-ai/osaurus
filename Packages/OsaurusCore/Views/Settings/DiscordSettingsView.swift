//
//  DiscordSettingsView.swift
//  osaurus
//
//  Configuration sheet for the native Discord channel.
//

import SwiftUI

struct DiscordSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Set when this sheet is hosted inside the unified Add Channel picker;
    /// shows a back chevron that returns to the catalog.
    var onBack: (() -> Void)? = nil

    @State private var botToken: String = ""
    @State private var guildIdsText: String = ""
    @State private var readableChannelIdsText: String = ""
    @State private var writableChannelIdsText: String = ""
    @State private var senderAllowlistText: String = ""
    @State private var writeEnabled: Bool = false
    @State private var defaultReadLimit: String = "50"
    @State private var tokenSaved: Bool = false
    @State private var statusMessage: String?
    @State private var statusDetails: [String] = []
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var isDiscovering = false
    @State private var discovery: DiscordConnectionDiscovery?
    @State private var selectedGuildId: String = ""
    @State private var channelSearch = ""
    @State private var memberSearch = ""
    @State private var inboundDispatchEnabled = false
    @State private var inboundAgentId: UUID?
    @State private var inboundRoutes: [AgentChannelDispatchRoute] = []
    @State private var inboundRequireMention = true
    @State private var inboundContinueThreads = true
    @State private var inboundAutoReplyEnabled = false
    @State private var healthRefreshToken = 0
    @State private var isSaving = false
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
        var guildIdsText: String
        var readableChannelIdsText: String
        var writableChannelIdsText: String
        var senderAllowlistText: String
        var writeEnabled: Bool
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
            guildIdsText: guildIdsText,
            readableChannelIdsText: readableChannelIdsText,
            writableChannelIdsText: writableChannelIdsText,
            senderAllowlistText: senderAllowlistText,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            inboundDispatchEnabled: inboundDispatchEnabled,
            inboundAgentId: inboundAgentId,
            inboundRoutes: inboundRoutes,
            inboundRequireMention: inboundRequireMention,
            inboundContinueThreads: inboundContinueThreads,
            inboundAutoReplyEnabled: inboundAutoReplyEnabled
        )
    }

    /// Discovered channels across every server, mapped into the shared
    /// routing editor's room shape.
    private var routableRooms: [AgentChannelRoutableRoom] {
        guard let discovery else { return [] }
        return discovery.guilds.flatMap { guild in
            (discovery.channelsByGuildId[guild.id] ?? []).map { channel in
                AgentChannelRoutableRoom(
                    id: channel.id,
                    name: "#\(channel.name ?? channel.id) (\(guild.name))"
                )
            }
        }
    }

    var body: some View {
        AgentChannelSetupScaffold(
            icon: AgentChannelKind.discord.icon,
            gradient: AgentChannelKind.discord.brandGradient,
            title: AgentChannelKind.discord.displayName,
            subtitle: L("Read and reply in allowlisted servers"),
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
                    verifySectionContent
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
            .disabled(isTesting || isSaving || (!tokenSaved && !hasPendingToken))
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
            if tokenSaved {
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
        guard validationFailure() == nil else { return }
        guard (try? DiscordConnectionService.shared.saveConfiguration(currentConfiguration())) != nil
        else { return }
        lastSavedDraft = currentDraft
        Task {
            await AgentChannelTransportSupervisor.shared.refreshDiscordRuntime()
            await MainActor.run { healthRefreshToken += 1 }
        }
    }

    // MARK: - Section state

    private func sectionCompleted(_ sectionId: String) -> Bool {
        switch AgentChannelProviderSetupSection(rawValue: sectionId) {
        case .connect:
            return tokenSaved
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

    // MARK: - Connect section

    private var connectSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                "Osaurus polls Discord for new messages — no webhook or public URL is needed.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            stepCreateBotSection
            SettingsDivider()
            stepTokenSection
            SettingsDivider()
            stepInviteSection
        }
    }

    private var accessSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepAccessSection
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

    private var verifySectionContent: some View {
        stepVerifySection
    }

    // MARK: - Guided setup steps

    private var stepCreateBotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Create the bot app"))

            AgentChannelSetupLink(
                title: L("Open the Discord Developer Portal and choose “New Application”"),
                url: URL(string: "https://discord.com/developers/applications")!
            )

            Text(
                "In the app, open the Bot page and turn on both privileged intents under “Privileged Gateway Intents”: Message Content Intent (required to read messages) and Server Members Intent (used to list senders).",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepTokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Paste the bot token"))

            Text(
                "On the same Bot page, press “Reset Token” and copy the token it shows.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelSecretField(
                label: L("Bot Token"),
                requirementHint: L("Required"),
                placeholder: L("Paste your bot token"),
                text: $botToken,
                saved: tokenSaved,
                onRemove: removeToken
            )

            Text(
                "Saved to the macOS Keychain when you press “Load from Discord”, Test Connection, or Done.",
                bundle: .module
            )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var stepInviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Invite the bot to your server"))

            if let inviteURL = botInviteURL {
                AgentChannelCopyableCommand(
                    command: inviteURL,
                    caption: L("Open this URL in a browser and pick your server."),
                    onCopied: { showStatus(L("Invite URL copied"), isError: false) }
                )
            } else {
                Text(
                    "Paste the bot token above and press “Load from Discord” in the Access section, then an invite URL appears here. (You can also use OAuth2 → URL Generator in the Developer Portal with the bot scope.)",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// OAuth2 invite URL built from the bot identity (the bot user id equals
    /// the application client id). Permissions 274877975552 = View Channels,
    /// Send Messages, Read Message History and thread send variants.
    private var botInviteURL: String? {
        guard let botId = discovery?.bot.id, !botId.isEmpty else { return nil }
        return "https://discord.com/oauth2/authorize?client_id=\(botId)&scope=bot&permissions=274877975552"
    }

    private var stepAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Choose channels and senders"))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(discovery == nil ? L("Connect to load servers and channels") : L("Discord choices loaded"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text("Mark channels as Read and people as Allow — no copying numeric IDs.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                AgentChannelSheetActionButton(
                    title: discovery == nil ? L("Load from Discord") : L("Refresh"),
                    busyTitle: L("Loading..."),
                    isBusy: isDiscovering,
                    action: { refreshDiscovery(showStatus: true) }
                )
                .disabled(isDiscovering || (!tokenSaved && !hasPendingToken))
            }

            if let discovery {
                Picker(L("discord.guild.picker"), selection: $selectedGuildId) {
                    ForEach(discovery.guilds, id: \.id) { guild in
                        Text(guild.name).tag(guild.id)
                    }
                }
                discordChannelSelector(discovery)
                discordMemberSelector(discovery)
                ForEach(discovery.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(theme.warningColor)
                }
            }

            Text(
                "Manual ID fields are under Advanced for entries discovery cannot see.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        }
    }

    private var sendingSection: some View {
        SettingsSubsection(label: L("Sending")) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: L("Allow Sending on Discord"),
                    description: L("Let agents post to write-allowlisted Discord destinations. The global Sending switch in Channels must also be on."),
                    isOn: $writeEnabled.animation(.easeOut(duration: 0.2))
                )

                if writeEnabled, parseIds(writableChannelIdsText).isEmpty {
                    Text(
                        "No channels are marked Write yet. Mark them in the Access section or add IDs under its Advanced options.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
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
                description: L("Choose which agent answers verified messages from allowed channels and senders."),
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
                    description: L("Start new conversations only when the bot is mentioned."),
                    isOn: $inboundRequireMention
                )
                SettingsToggle(
                    title: L("Continue Participating Threads"),
                    description: L("Accept follow-ups after Osaurus has replied in a channel or thread."),
                    isOn: $inboundContinueThreads
                )
                SettingsToggle(
                    title: L("Reply Automatically"),
                    description: L("Post sanitized agent responses back to Discord when write gates allow it."),
                    isOn: $inboundAutoReplyEnabled
                )
            }
        }
    }

    private var stepVerifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Verify an incoming message"))

            Text(
                "Changes save automatically, and receive polling starts once Connect and Access are complete. The first poll only arms the cursor — it does not replay old messages. Send a fresh message mentioning the bot in a readable channel, then watch each stage appear here.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            testPromptRow

            AgentChannelTransportHealthView(
                connectionId: DiscordConnectionService.nativeConnectionId,
                transportId: DiscordPollingTransportRuntime.transportId,
                title: L("Discord receive polling"),
                notRunningHint: L("Polling is not running. Add a bot token, readable channels, and authorized sender IDs to start it."),
                refreshToken: healthRefreshToken
            )

            AgentChannelInboundActivityListView(
                connectionId: DiscordConnectionService.nativeConnectionId,
                emptyHint: L(
                    "No incoming Discord messages yet this session. Send the test message and press “Verify incoming message”."
                ),
                refreshToken: activityRefreshToken
            )

            AgentChannelSheetActionButton(
                title: L("Verify incoming message"),
                busyTitle: L("Waiting for a Discord message..."),
                isBusy: isVerifying,
                action: verifyIncomingMessage
            )
            .disabled(isVerifying || isSaving || isTesting)
        }
    }

    /// Exact test message the user should send, mentioning the Discord bot
    /// user (mentioning the Osaurus agent name is a frequent failure).
    private var testPromptRow: some View {
        let botName = discovery?.bot.username
        return AgentChannelCopyableCommand(
            command: "@\(botName ?? "your-discord-bot") hello",
            caption: botName == nil
                ? L("Mention the Discord bot user, not the Osaurus agent name. Load from Discord to fill in the bot name.")
                : L("Mention the Discord bot user, not the Osaurus agent name."),
            onCopied: { showStatus(L("Test message copied"), isError: false) }
        )
    }

    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelMultilineSettingsField(
                    title: L("Server IDs"),
                    text: $guildIdsText,
                    placeholder: L("123456789012345678 — one per line"),
                    help: L("Manual fallback for servers not returned by discovery.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Readable Channel IDs"),
                    text: $readableChannelIdsText,
                    placeholder: L("987654321098765432 — one per line"),
                    help: L("Channels or threads agents may read and search.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Writable Channel IDs"),
                    text: $writableChannelIdsText,
                    placeholder: L("987654321098765432 — one per line"),
                    help: L("Channels or threads agents may post to.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Authorized Sender IDs"),
                    text: $senderAllowlistText,
                    placeholder: L("123456789012345678 — one per line"),
                    help: L("Required before an agent can reply. Use Discord user IDs.")
                )
                StyledSettingsTextField(
                    label: L("Default Read Limit"),
                    text: $defaultReadLimit,
                    placeholder: "50",
                    help: L("Default recent-message count for channel/thread reads. Clamped to 1-100.")
                )
            }
        }
    }

    private func discordChannelSelector(_ discovery: DiscordConnectionDiscovery) -> some View {
        let channels = discovery.channelsByGuildId[selectedGuildId] ?? []
        let readableIds = Set(parseIds(readableChannelIdsText))
        let writableIds = Set(parseIds(writableChannelIdsText))
        let shaped = AgentChannelSelectorList.shape(
            channels,
            query: channelSearch,
            fields: { [$0.displayName, $0.id] },
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
                Text("Channels", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(channels.count) found", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            Text(
                "Read lets agents see a channel, Write lets them post there.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelSelectorSearchField(
                placeholder: L("Search channels by name or ID"),
                text: $channelSearch
            )

            AgentChannelSelectorListCard(
                shaped: shaped,
                emptyText: L("No matching channels")
            ) { item in
                discordChannelRow(item.entry, access: item.state)
            }
        }
    }

    private func discordChannelRow(
        _ channel: DiscordChannel,
        access: AgentChannelReadWriteSelection
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .foregroundColor(theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(channel.id)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            AgentChannelSelectorToggle(title: L("Read"), selected: access.read) {
                toggleChannel(channel.id, in: &readableChannelIdsText)
            }
            AgentChannelSelectorToggle(title: L("Write"), selected: access.write) {
                toggleChannel(channel.id, in: &writableChannelIdsText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func discordMemberSelector(_ discovery: DiscordConnectionDiscovery) -> some View {
        let members = discovery.membersByGuildId[selectedGuildId] ?? []
        let allowedIds = Set(parseIds(senderAllowlistText))
        let allowedCount = members.filter { allowedIds.contains($0.id) }.count
        let shaped = AgentChannelSelectorList.shape(
            members,
            query: memberSearch,
            fields: { [$0.displayName, $0.user.username, $0.id] },
            state: { allowedIds.contains($0.id) },
            isSelected: { $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Authorized Senders", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(allowedCount) allowed · \(members.count) people", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            AgentChannelSelectorSearchField(
                placeholder: L("Search people by name or ID"),
                text: $memberSearch
            )

            AgentChannelSelectorListCard(
                shaped: shaped,
                emptyText: L("No matching people"),
                maxHeight: 200
            ) { item in
                discordMemberRow(item.entry, allowed: item.state)
            }
        }
    }

    private func discordMemberRow(_ member: DiscordGuildMember, allowed: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(member.id)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            AgentChannelSelectorToggle(title: L("Allow"), selected: allowed) {
                senderAllowlistText = toggledIdText(senderAllowlistText, id: member.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func toggleChannel(_ id: String, in text: inout String) {
        var ids = parseIds(text)
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        text = ids.joined(separator: "\n")
        if !selectedGuildId.isEmpty {
            var guildIds = parseIds(guildIdsText)
            if !guildIds.contains(selectedGuildId) {
                guildIds.append(selectedGuildId)
                guildIdsText = guildIds.joined(separator: "\n")
            }
        }
    }

    private func toggledIdText(_ text: String, id: String) -> String {
        var ids = parseIds(text)
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        return ids.joined(separator: "\n")
    }

    private func loadConfiguration() {
        let configuration = DiscordConnectionConfigurationStore.load()
        guildIdsText = configuration.configuredGuildIds.joined(separator: "\n")
        readableChannelIdsText = configuration.readableChannelIds.joined(separator: "\n")
        writableChannelIdsText = configuration.writableChannelIds.joined(separator: "\n")
        senderAllowlistText = configuration.senderAllowlist.joined(separator: "\n")
        writeEnabled = configuration.writeEnabled
        defaultReadLimit = "\(configuration.defaultReadLimit)"
        inboundDispatchEnabled = configuration.inboundDispatch.enabled
        inboundAgentId = configuration.inboundDispatch.targetAgentId
        inboundRoutes = configuration.inboundDispatch.routes
        inboundRequireMention = configuration.inboundDispatch.requireMention
        inboundContinueThreads = configuration.inboundDispatch.continueThreads
        inboundAutoReplyEnabled = configuration.inboundDispatch.autoReplyEnabled
        Task { tokenSaved = await DiscordConnectionService.shared.hasBotTokenOffMain() }
        // Arm autosave only after the stored configuration has hydrated the
        // draft, so hydration itself is never mistaken for an edit.
        lastSavedDraft = currentDraft
    }

    private var hasPendingToken: Bool {
        !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Persist a pasted bot token to Keychain before the configuration save.
    /// Awaited off the main thread so a slow securityd never beachballs the
    /// Save/Test buttons.
    private func persistPendingSecrets() async -> Bool {
        guard hasPendingToken else { return true }
        do {
            try await DiscordConnectionService.shared.saveBotTokenOffMain(botToken)
            botToken = ""
            tokenSaved = true
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func removeToken() {
        botToken = ""
        tokenSaved = false
        Task { await DiscordConnectionService.shared.deleteBotTokenOffMain() }
        showStatus(L("Discord bot token removed"), isError: false)
    }

    /// First cross-field problem the save would reject, or nil when the
    /// draft is persistable. Shared by autosave (skip silently) and the
    /// explicit save (show and navigate to the section).
    private func validationFailure() -> (message: String, section: AgentChannelProviderSetupSection)? {
        if inboundDispatchEnabled && inboundAgentId == nil && inboundRoutes.isEmpty {
            return (
                L("Choose an agent to reply, or add a rule for incoming Discord messages."),
                .behavior
            )
        }
        if inboundDispatchEnabled && parseIds(senderAllowlistText).isEmpty {
            return (
                L("Add at least one authorized Discord sender before an agent can reply."),
                .access
            )
        }
        if inboundAutoReplyEnabled && (!writeEnabled || parseIds(writableChannelIdsText).isEmpty) {
            return (
                L("Automatic replies require Discord sending and a writable channel."),
                .behavior
            )
        }
        return nil
    }

    private func currentConfiguration() -> DiscordConnectionConfiguration {
        DiscordConnectionConfiguration(
            configuredGuildIds: parseIds(guildIdsText),
            readableChannelIds: parseIds(readableChannelIdsText),
            writableChannelIds: parseIds(writableChannelIdsText),
            senderAllowlist: parseIds(senderAllowlistText),
            writeEnabled: writeEnabled,
            defaultReadLimit: Int(defaultReadLimit) ?? 50,
            inboundDispatch: AgentChannelInboundDispatchConfiguration(
                enabled: inboundDispatchEnabled,
                targetAgentId: inboundAgentId,
                routes: inboundRoutes,
                requireMention: inboundRequireMention,
                continueThreads: inboundContinueThreads,
                autoReplyEnabled: inboundAutoReplyEnabled
            )
        )
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
        if let failure = validationFailure() {
            showStatus(failure.message, isError: true, section: failure.section)
            return false
        }
        do {
            try DiscordConnectionService.shared.saveConfiguration(currentConfiguration())
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
            await AgentChannelTransportSupervisor.shared.refreshDiscordRuntime()
            guard inboundDispatchEnabled else {
                await MainActor.run {
                    isSaving = false
                    _ = ToastManager.shared.success(L("Discord settings saved"))
                    dismiss()
                }
                return
            }
            let diagnostics = await DiscordConnectionService.shared.diagnostics()
            let report = AgentChannelLiveProofReadiness.discord(diagnostics)
            await MainActor.run {
                isSaving = false
                healthRefreshToken += 1
                if report.isReadyForLiveProof {
                    _ = ToastManager.shared.success(L("Discord settings saved — receive is ready"))
                    dismiss()
                } else {
                    showStatus(
                        L("Saved, but Discord receive is not ready yet"),
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
            await AgentChannelTransportSupervisor.shared.refreshDiscordRuntime()
            let diagnostics = await DiscordConnectionService.shared.diagnostics()
            await MainActor.run {
                isTesting = false
                healthRefreshToken += 1
                let presentation = AgentChannelStatusPresentation.diagnostics(
                    status: diagnostics.status
                )
                if diagnostics.failures.isEmpty {
                    showStatus(presentation.label, isError: false)
                } else {
                    showStatus(presentation.label, details: diagnostics.failures, isError: true)
                }
            }
        }
    }

    private func refreshDiscovery(showStatus announce: Bool) {
        isDiscovering = true
        Task {
            guard await persistPendingSecrets() else {
                isDiscovering = false
                return
            }
            do {
                let loaded = try await DiscordConnectionService.shared.discoverConfigurationOptions()
                await MainActor.run {
                    discovery = loaded
                    if selectedGuildId.isEmpty || !loaded.guilds.contains(where: { $0.id == selectedGuildId }) {
                        selectedGuildId = loaded.guilds.first?.id ?? ""
                    }
                    isDiscovering = false
                    if announce {
                        showStatus(L("Loaded Discord servers and channels."), details: loaded.warnings, isError: false)
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

    private func verifyIncomingMessage() {
        isVerifying = true
        showStatus(
            L("Waiting for a Discord message. Send the test message now from an authorized sender in a readable channel."),
            isError: false
        )
        let start = Date()
        let autoReply = inboundAutoReplyEnabled
        Task {
            let outcome = await AgentChannelInboundVerifier.waitForTerminalEvent(
                connectionId: DiscordConnectionService.nativeConnectionId,
                since: start,
                autoReplyEnabled: autoReply,
                onActivity: {
                    activityRefreshToken += 1
                    healthRefreshToken += 1
                }
            )
            await MainActor.run {
                isVerifying = false
                activityRefreshToken += 1
                if let event = outcome.event {
                    presentVerifyOutcome(event, timedOutWaitingForMore: outcome.timedOutWaitingForMore)
                } else {
                    showStatus(
                        L("No Discord message arrived within 90 seconds."),
                        details: verifyNoEventGuidance(),
                        isError: true
                    )
                }
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
                L("The message stopped at this stage before the wait expired; check the recent events list above.")
            )
        }
        if !isError {
            verifySucceeded = true
        }
        showStatus(label, details: details, isError: isError)
    }

    private func verifyNoEventGuidance() -> [String] {
        var guidance = [
            L("Confirm the message was sent in a channel selected as Read, by a person in Authorized Senders."),
            L("Confirm the Message Content Intent is enabled on the bot's Developer Portal page."),
            L("Confirm the bot is a member of the server and can see the channel."),
            L("Mention the Discord bot user, not the Osaurus agent name."),
            L("Remember the first poll after setup only arms the cursor; send a fresh message after saving."),
        ]
        if let warning = OsaurusRunningInstanceInspector.duplicateInstanceWarning(
            instanceCount: OsaurusRunningInstanceInspector.runningInstanceCount()
        ) {
            guidance.append(warning)
        }
        return guidance
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
        return DiscordConnectionConfiguration.normalizedIds(
            text.components(separatedBy: separators)
        )
    }
}
