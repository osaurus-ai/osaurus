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
    @State private var inboundRequireMention = true
    @State private var inboundContinueThreads = true
    @State private var inboundAutoReplyEnabled = false
    @State private var healthRefreshToken = 0

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        AgentChannelSheetScaffold(
            icon: AgentChannelKind.discord.icon,
            gradient: AgentChannelKind.discord.brandGradient,
            title: AgentChannelKind.discord.displayName,
            subtitle: L("Read and reply in allowlisted servers")
        ) {
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    "Connect a Discord bot so agents can read allowlisted channels and post only to write-allowlisted destinations.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                credentialsSection
                SettingsDivider()
                accessSection
                SettingsDivider()
                sendingSection
                SettingsDivider()
                inboundDispatchSection
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
                .disabled(isTesting || (!tokenSaved && !hasPendingToken))

                Spacer()

                AgentChannelSheetActionButton(
                    title: L("Save"),
                    busyTitle: L("Saving..."),
                    isBusy: false,
                    isPrimary: true,
                    action: saveAndDismiss
                )
            }
        }
        .onAppear(perform: loadConfiguration)
    }

    private var credentialsSection: some View {
        SettingsSubsection(label: L("Credentials")) {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelSetupLink(
                    title: L("Create a bot in the Discord Developer Portal"),
                    url: URL(string: "https://discord.com/developers/applications")!
                )

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
    }

    private var accessSection: some View {
        SettingsSubsection(label: L("Access")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(discovery == nil ? L("Connect to load servers and channels") : L("Discord choices loaded"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text("Select read and write access without copying numeric IDs.", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                    Spacer()
                    AgentChannelSheetActionButton(
                        title: discovery == nil ? L("Load from Discord") : L("Refresh"),
                        busyTitle: L("Loading..."),
                        isBusy: isDiscovering,
                        action: refreshDiscovery
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
            }
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

                if writeEnabled {
                    AgentChannelMultilineSettingsField(
                        title: L("Writable Channel IDs"),
                        text: $writableChannelIdsText,
                        placeholder: L("987654321098765432 — one per line"),
                        help: L("Channels or threads agents may post to.")
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var inboundDispatchSection: some View {
        SettingsSubsection(label: L("Inbound Agent")) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: L("Dispatch Discord Messages to an Agent"),
                    description: L("Run verified messages from allowed channels and senders through a selected agent."),
                    isOn: $inboundDispatchEnabled.animation(.easeOut(duration: 0.2))
                )
                if inboundDispatchEnabled {
                    Picker(L("Agent"), selection: $inboundAgentId) {
                        Text("Select an agent", bundle: .module).tag(UUID?.none)
                        ForEach(agentManager.agents.filter { !$0.isBuiltIn }) { agent in
                            Text(agent.name).tag(Optional(agent.id))
                        }
                    }
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
                AgentChannelTransportHealthView(
                    connectionId: DiscordConnectionService.nativeConnectionId,
                    transportId: DiscordPollingTransportRuntime.transportId,
                    title: L("Discord receive polling"),
                    notRunningHint: L("Add a token, readable channels, and authorized sender IDs to start receiving."),
                    refreshToken: healthRefreshToken
                )
            }
        }
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
        if inboundDispatchEnabled && inboundAgentId == nil {
            showStatus(L("Select an agent for inbound Discord messages."), isError: true)
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

    private func saveAndDismiss() {
        guard persistPendingSecrets(), saveConfiguration() else { return }
        Task {
            await AgentChannelTransportSupervisor.shared.refreshDiscordRuntime()
            await MainActor.run {
                _ = ToastManager.shared.success(L("Discord settings saved"))
                dismiss()
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

    private func refreshDiscovery() {
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
                    showStatus(L("Loaded Discord servers and channels."), details: loaded.warnings, isError: false)
                }
            } catch {
                await MainActor.run {
                    isDiscovering = false
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
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
