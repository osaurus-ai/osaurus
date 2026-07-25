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

    private var theme: ThemeProtocol { themeManager.currentTheme }

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
        AgentChannelSheetScaffold(
            icon: AgentChannelKind.discord.icon,
            gradient: AgentChannelKind.discord.brandGradient,
            title: AgentChannelKind.discord.displayName,
            subtitle: L("Read and reply in allowlisted servers")
        ) {
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    "Osaurus polls Discord for new messages — no webhook or public URL is needed. Follow the numbered steps; each shows a checkmark when it is complete.",
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
                SettingsDivider()
                stepAccessSection
                SettingsDivider()
                stepDispatchSection
                SettingsDivider()
                sendingSection
                SettingsDivider()
                stepVerifySection
                SettingsDivider()
                advancedSection
            }
        } footer: {
            if let statusMessage {
                AgentChannelInlineStatusMessage(
                    message: statusMessage,
                    details: statusDetails,
                    isError: statusIsError,
                    onAutoClear: { clearStatus() }
                )
            }

            HStack(spacing: 10) {
                AgentChannelSheetActionButton(
                    title: L("Test Connection"),
                    busyTitle: L("Testing..."),
                    isBusy: isTesting,
                    action: testConnection
                )
                .disabled(isTesting || isSaving || (!tokenSaved && !hasPendingToken))

                Spacer()

                AgentChannelSheetActionButton(
                    title: L("Save"),
                    busyTitle: L("Saving..."),
                    isBusy: isSaving,
                    isPrimary: true,
                    action: saveAndDismiss
                )
                .disabled(isSaving)
            }
        }
        .onAppear {
            loadConfiguration()
            if tokenSaved {
                refreshDiscovery(showStatus: false)
            }
        }
    }

    // MARK: - Guided setup steps

    private func stepHeader(_ number: Int, _ title: String, done: Bool) -> some View {
        AgentChannelSetupStepHeader(number: number, title: title, done: done)
    }

    private var stepCreateBotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeader(1, L("Create the bot app"), done: tokenSaved || hasPendingToken)

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
            stepHeader(2, L("Paste the bot token"), done: tokenSaved)

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

            Text("Saved to the macOS Keychain when you press Save.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var stepInviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeader(
                3,
                L("Invite the bot to your server"),
                done: discovery.map { !$0.guilds.isEmpty } ?? false
            )

            if let inviteURL = botInviteURL {
                AgentChannelCopyableCommand(
                    command: inviteURL,
                    caption: L("Open this URL in a browser and pick your server."),
                    onCopied: { showStatus(L("Invite URL copied"), isError: false) }
                )
            } else {
                Text(
                    "Save the bot token and press “Load from Discord” below, then an invite URL appears here. (You can also use OAuth2 → URL Generator in the Developer Portal with the bot scope.)",
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
            stepHeader(
                4,
                L("Choose channels and senders"),
                done: !parseIds(readableChannelIdsText).isEmpty && !parseIds(senderAllowlistText).isEmpty
            )

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
                Picker(L("Server"), selection: $selectedGuildId) {
                    ForEach(discovery.guilds, id: \.id) { guild in
                        Text(guild.name).tag(guild.id)
                    }
                }
                TextField(L("Search channels"), text: $channelSearch)
                    .textFieldStyle(.roundedBorder)
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
                    description: L("Let agents post to write-allowlisted Discord destinations. Channel writes must also be on globally."),
                    isOn: $writeEnabled.animation(.easeOut(duration: 0.2))
                )

                if writeEnabled, parseIds(writableChannelIdsText).isEmpty {
                    Text(
                        "No channels are marked Write yet. Mark them in step 4 or add IDs under Advanced.",
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
            stepHeader(
                5,
                L("Send incoming messages to an agent"),
                done: inboundDispatchEnabled && (inboundAgentId != nil || !inboundRoutes.isEmpty)
            )

            SettingsToggle(
                title: L("Dispatch Discord Messages to an Agent"),
                description: L("Run verified messages from allowed channels and senders through a selected agent."),
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
            stepHeader(6, L("Verify an incoming message"), done: false)

            Text(
                "Receive polling starts automatically after Save once steps 2–4 are complete. The first poll only arms the cursor — it does not replay old messages. Send a fresh message mentioning the bot in a readable channel, then watch each stage appear here.",
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
                notRunningHint: L("Polling is not running. Save a bot token, readable channels, and authorized sender IDs to start it."),
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
                    help: L("Required for inbound dispatch. Use Discord user IDs.")
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
        let channels = (discovery.channelsByGuildId[selectedGuildId] ?? []).filter { channel in
            let needle = channelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return needle.isEmpty
                || channel.displayName.lowercased().contains(needle)
                || channel.id.contains(needle)
        }
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(channels, id: \.id) { channel in
                    HStack(spacing: 8) {
                        Image(systemName: "number")
                            .foregroundColor(theme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text(channel.id)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                        }
                        Spacer()
                        selectionButton(
                            L("Read"),
                            selected: parseIds(readableChannelIdsText).contains(channel.id)
                        ) {
                            toggleChannel(channel.id, in: &readableChannelIdsText)
                        }
                        selectionButton(
                            L("Write"),
                            selected: parseIds(writableChannelIdsText).contains(channel.id)
                        ) {
                            toggleChannel(channel.id, in: &writableChannelIdsText)
                        }
                    }
                    .padding(.vertical, 8)
                    Divider().foregroundColor(theme.cardBorder)
                }
            }
        }
        .frame(maxHeight: 240)
    }

    private func selectionButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(selected ? theme.accentColor : theme.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private func discordMemberSelector(_ discovery: DiscordConnectionDiscovery) -> some View {
        let members = discovery.membersByGuildId[selectedGuildId] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Text("Authorized Senders", bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.primaryText)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(members) { member in
                        let selected = parseIds(senderAllowlistText).contains(member.id)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                Text(member.id)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            Spacer()
                            selectionButton(L("Allow"), selected: selected) {
                                senderAllowlistText = toggledIdText(senderAllowlistText, id: member.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
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
        tokenSaved = DiscordConnectionService.shared.hasBotToken()
    }

    private var hasPendingToken: Bool {
        !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Persist a pasted bot token to Keychain before the configuration save.
    private func persistPendingSecrets() -> Bool {
        guard hasPendingToken else { return true }
        do {
            try DiscordConnectionService.shared.saveBotToken(botToken)
            botToken = ""
            tokenSaved = true
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func removeToken() {
        _ = DiscordConnectionService.shared.deleteBotToken()
        botToken = ""
        tokenSaved = false
        showStatus(L("Discord bot token removed"), isError: false)
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
        if inboundDispatchEnabled && inboundAgentId == nil && inboundRoutes.isEmpty {
            showStatus(
                L("Select a default agent or add a routing rule for inbound Discord messages."),
                isError: true
            )
            return false
        }
        if inboundDispatchEnabled && parseIds(senderAllowlistText).isEmpty {
            showStatus(L("Add at least one authorized Discord sender for inbound dispatch."), isError: true)
            return false
        }
        if inboundAutoReplyEnabled && (!writeEnabled || parseIds(writableChannelIdsText).isEmpty) {
            showStatus(L("Automatic replies require Discord sending and a writable channel."), isError: true)
            return false
        }
        let configuration = DiscordConnectionConfiguration(
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
        do {
            try DiscordConnectionService.shared.saveConfiguration(configuration)
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
        guard persistPendingSecrets(), saveConfiguration() else { return }
        isSaving = true
        Task {
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
                        isError: true
                    )
                }
            }
        }
    }

    /// Persist the current draft first so diagnostics always test what the
    /// user sees in the form, not a stale save.
    private func testConnection() {
        guard persistPendingSecrets(), saveConfiguration() else { return }
        isTesting = true
        Task {
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
        guard persistPendingSecrets() else { return }
        isDiscovering = true
        Task {
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

    private func showStatus(_ message: String, details: [String] = [], isError: Bool) {
        statusMessage = message
        statusDetails = details
        statusIsError = isError
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
