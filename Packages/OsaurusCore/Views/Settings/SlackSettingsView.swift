//
//  SlackSettingsView.swift
//  osaurus
//
//  Configuration sheet for the native Slack channel.
//

import SwiftUI

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
                .disabled(isTesting || isSaving || (!botTokenSaved && !hasPendingBotToken))

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
        .onAppear(perform: loadConfiguration)
    }

    private var credentialsSection: some View {
        SettingsSubsection(label: L("Credentials")) {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelSetupLink(
                    title: L("Create a Slack app at api.slack.com/apps"),
                    url: URL(string: "https://api.slack.com/apps")!
                )

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
                    title: L("Authorized Sender IDs"),
                    text: $senderAllowlistText,
                    placeholder: L("U0123ABC — one per line"),
                    help: L("Only these Slack users can trigger inbound handling.")
                )
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
                    AgentChannelMultilineSettingsField(
                        title: L("Writable Channel IDs"),
                        text: $writableChannelIdsText,
                        placeholder: L("C0123ABC — one per line"),
                        help: L("Channels agents may post to.")
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))

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
            StyledSettingsTextField(
                label: L("Default Read Limit"),
                text: $defaultReadLimit,
                placeholder: "50",
                help: L("Default recent-message count for Slack reads. Clamped to 1-100.")
            )
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
        botTokenSaved = SlackConnectionService.shared.hasBotToken()
        signingSecretSaved = SlackConnectionService.shared.hasSigningSecret()
        appTokenSaved = SlackConnectionService.shared.hasAppToken()
    }

    private var hasPendingBotToken: Bool {
        !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            let diagnostics = await SlackConnectionService.shared.diagnostics()
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
}
