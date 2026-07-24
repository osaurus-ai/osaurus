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
    @Environment(\.dismiss) private var dismiss

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

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        AgentChannelSheetScaffold(
            icon: AgentChannelKind.slack.icon,
            gradient: AgentChannelKind.slack.brandGradient,
            title: AgentChannelKind.slack.displayName,
            subtitle: L("Read and reply in allowlisted workspace channels")
        ) {
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    "Connect a Slack bot so agents can inspect allowlisted channels and post only to write-allowlisted destinations.",
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
                receiveSection
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
                .disabled(isTesting || isSaving || isDiscovering || (!botTokenSaved && !hasPendingBotToken))

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
            if botTokenSaved {
                refreshDiscovery(showStatus: false)
            }
        }
    }

    private var credentialsSection: some View {
        SettingsSubsection(label: L("Credentials")) {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelSetupLink(
                    title: L("Create a Slack app at api.slack.com/apps"),
                    url: URL(string: "https://api.slack.com/apps")!
                )

                Button(action: copyRecommendedManifest) {
                    Label(L("Copy recommended Slack app manifest"), systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())

                AgentChannelSecretField(
                    label: L("Bot Token"),
                    requirementHint: L("Required"),
                    placeholder: L("xoxb-..."),
                    text: $botToken,
                    saved: botTokenSaved,
                    onRemove: removeBotToken
                )

                AgentChannelSecretField(
                    label: L("Signing Secret"),
                    requirementHint: L("Optional — webhook receive"),
                    placeholder: L("Paste your signing secret"),
                    text: $signingSecret,
                    saved: signingSecretSaved,
                    onRemove: removeSigningSecret
                )

                AgentChannelSecretField(
                    label: L("App Token"),
                    requirementHint: L("Optional — enables Socket Mode receive"),
                    placeholder: L("xapp-..."),
                    text: $appToken,
                    saved: appTokenSaved,
                    onRemove: removeAppToken
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
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            discovery == nil ? L("Connect to load workspace choices") : L("Slack workspace loaded")
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        Text(
                            discovery == nil
                                ? L("Save a bot token, then load channels and users from Slack.")
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
                    description: L("Let agents post to write-allowlisted Slack channels. Channel writes must also be on globally."),
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

    private var receiveSection: some View {
        SettingsSubsection(label: L("Receive")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Socket Mode receive starts automatically once a bot token, app token, readable channels, and authorized senders are configured.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                AgentChannelTransportHealthView(
                    connectionId: AgentChannelConnection.nativeSlackConnectionId,
                    transportId: SlackSocketModeTransportRuntime.transportId,
                    title: L("Socket Mode receive"),
                    notRunningHint: L(
                        "Socket Mode is not running. Save a bot token, a Socket Mode app token, readable channels, and authorized sender IDs to start it."
                    ),
                    refreshToken: healthRefreshToken
                )
            }
        }
    }

    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            VStack(alignment: .leading, spacing: 12) {
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
                    help: L("Channels agents may post to when Slack and global channel writes are enabled.")
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

            accessButton(title: L("Workspace"), selected: selected, enabled: true) {
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

    private func channelSelector(_ discovery: SlackConnectionDiscovery) -> some View {
        let rows = filteredConversations(discovery)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Channels", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(discovery.conversations.count) found")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            compactSearchField(
                text: $channelSearch,
                placeholder: L("Search channels by name or ID")
            )

            VStack(spacing: 0) {
                if rows.isEmpty {
                    selectorEmptyState(L("No matching Slack channels"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows, id: \.id) { channel in
                                channelSelectionRow(channel)
                                if channel.id != rows.last?.id {
                                    Divider().foregroundColor(theme.cardBorder)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
            )

            Text(
                "Read and Write are independent allowlists. Unjoined channels stay unavailable until the bot is invited.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func channelSelectionRow(_ channel: SlackConversation) -> some View {
        let canUse = channel.isMember || channel.isIM || channel.isMPIM
        let readSelected = parseIds(readableChannelIdsText).contains(channel.id)
        let writeSelected = parseIds(writableChannelIdsText).contains(channel.id)
        return HStack(spacing: 9) {
            Image(systemName: channelIcon(channel))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(canUse ? theme.secondaryText : theme.tertiaryText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(channel.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(canUse ? theme.primaryText : theme.tertiaryText)
                        .lineLimit(1)
                    if channel.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundColor(theme.tertiaryText)
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

            accessButton(title: L("Read"), selected: readSelected, enabled: canUse) {
                readableChannelIdsText = updatedIdText(
                    readableChannelIdsText,
                    id: channel.id,
                    selected: !readSelected
                )
            }
            accessButton(title: L("Write"), selected: writeSelected, enabled: canUse) {
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
        let rows = filteredUsers(discovery)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Authorized Senders", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(eligibleUsers(discovery).count) people")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            compactSearchField(
                text: $userSearch,
                placeholder: L("Search people by name or ID")
            )

            VStack(spacing: 0) {
                if rows.isEmpty {
                    selectorEmptyState(L("No matching Slack users"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { user in
                                userSelectionRow(user)
                                if user.id != rows.last?.id {
                                    Divider().foregroundColor(theme.cardBorder)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
            )

            Text(
                "Only selected people may trigger inbound handling. An empty sender list keeps Slack receive disabled.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func userSelectionRow(_ user: SlackUser) -> some View {
        let selected = parseIds(senderAllowlistText).contains(user.id)
        return HStack(spacing: 9) {
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

            accessButton(title: L("Allow"), selected: selected, enabled: true) {
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

    private func compactSearchField(text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
        )
    }

    private func accessButton(
        title: String,
        selected: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(selected ? theme.accentColor : theme.tertiaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(selected ? theme.accentColor.opacity(0.1) : theme.tertiaryBackground)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private func selectorEmptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }

    private func filteredConversations(_ discovery: SlackConnectionDiscovery) -> [SlackConversation] {
        let query = channelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = discovery.conversations.filter { channel in
            query.isEmpty
                || channel.displayName.lowercased().contains(query)
                || channel.id.lowercased().contains(query)
                || channel.kind.lowercased().contains(query)
        }
        return Array(matches.prefix(100))
    }

    private func eligibleUsers(_ discovery: SlackConnectionDiscovery) -> [SlackUser] {
        discovery.users.filter { user in
            !user.deleted
                && !user.isBot
                && !user.isAppUser
                && user.id != discovery.identity.userId
        }
    }

    private func filteredUsers(_ discovery: SlackConnectionDiscovery) -> [SlackUser] {
        let query = userSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = eligibleUsers(discovery).filter { user in
            query.isEmpty
                || user.displayName.lowercased().contains(query)
                || user.id.lowercased().contains(query)
                || (user.name?.lowercased().contains(query) ?? false)
        }
        return Array(matches.prefix(100))
    }

    private func channelIcon(_ channel: SlackConversation) -> String {
        if channel.isIM { return "person.fill" }
        if channel.isMPIM { return "person.2.fill" }
        if channel.isPrivate { return "number.square.fill" }
        return "number"
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
        botTokenSaved = SlackConnectionService.shared.hasBotToken()
        signingSecretSaved = SlackConnectionService.shared.hasSigningSecret()
        appTokenSaved = SlackConnectionService.shared.hasAppToken()
    }

    private var hasPendingBotToken: Bool {
        !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshDiscovery(showStatus announce: Bool) {
        guard persistPendingSecrets() else { return }
        isDiscovering = true
        Task {
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
    private func persistPendingSecrets() -> Bool {
        do {
            if hasPendingBotToken {
                try SlackConnectionService.shared.saveBotToken(botToken)
                botToken = ""
                botTokenSaved = true
            }
            if !signingSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try SlackConnectionService.shared.saveSigningSecret(signingSecret)
                signingSecret = ""
                signingSecretSaved = true
            }
            if !appToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try SlackConnectionService.shared.saveAppToken(appToken)
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
        _ = SlackConnectionService.shared.deleteBotToken()
        botToken = ""
        botTokenSaved = false
        discovery = nil
        refreshReceiveRuntime()
        showStatus(L("Slack bot token removed"), isError: false)
    }

    private func removeSigningSecret() {
        _ = SlackConnectionService.shared.deleteSigningSecret()
        signingSecret = ""
        signingSecretSaved = false
        showStatus(L("Slack signing secret removed"), isError: false)
    }

    private func removeAppToken() {
        _ = SlackConnectionService.shared.deleteAppToken()
        appToken = ""
        appTokenSaved = false
        refreshReceiveRuntime()
        showStatus(L("Slack Socket Mode app token removed"), isError: false)
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
        if let validationFailure = configurationValidationFailure() {
            showStatus(validationFailure, isError: true)
            return false
        }
        let configuration = SlackConnectionConfiguration(
            configuredTeamIds: parseIds(configuredTeamIdsText),
            readableChannelIds: parseIds(readableChannelIdsText),
            writableChannelIds: parseIds(writableChannelIdsText),
            senderAllowlist: parseIds(senderAllowlistText),
            writeEnabled: writeEnabled,
            defaultReadLimit: Int(defaultReadLimit) ?? 50,
            allowBroadcastMentions: allowBroadcastMentions
        )
        do {
            try SlackConnectionService.shared.saveConfiguration(configuration)
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    /// Persist the configuration, hold the Save button busy until the receive
    /// supervisor has re-evaluated the runtime, then close the sheet.
    private func saveAndDismiss() {
        guard persistPendingSecrets(), saveConfiguration() else { return }
        isSaving = true
        Task {
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            await MainActor.run {
                isSaving = false
                _ = ToastManager.shared.success(L("Slack settings saved"))
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
            await MainActor.run {
                isTesting = false
                healthRefreshToken += 1
                let presentation = AgentChannelStatusPresentation.diagnostics(
                    status: diagnostics.status
                )
                var details = diagnostics.failures
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
                    isError: !diagnostics.failures.isEmpty
                )
            }
        }
    }

    /// Restart the Socket Mode runtime after a config change, then refresh the
    /// inline health card once the supervisor has re-evaluated.
    private func refreshReceiveRuntime() {
        Task {
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            await MainActor.run { healthRefreshToken += 1 }
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

    private func configurationValidationFailure() -> String? {
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
                return "\(group.label) contains invalid Slack ID `\(invalid)`."
            }
        }
        guard Int(defaultReadLimit) != nil else {
            return L("Default Read Limit must be a number from 1 to 100.")
        }
        return nil
    }

    private static let recommendedManifest = """
    display_information:
      name: Osaurus
    features:
      bot_user:
        display_name: Osaurus
        always_online: false
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
