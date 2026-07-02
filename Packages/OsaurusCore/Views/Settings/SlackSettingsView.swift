//
//  SlackSettingsView.swift
//  osaurus
//
//  Manual configuration for the native Slack connection.
//

import SwiftUI

struct SlackSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

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
    @State private var statusIsError = false
    @State private var isTesting = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        SettingsSubsection(label: "Slack") {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Connect a Slack bot so Osaurus can inspect allowlisted channels and post only to write-allowlisted destinations.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

                credentialsSection
                SettingsDivider()
                allowlistSection
                SettingsDivider()
                actionsSection
            }
        }
        .onAppear(perform: loadConfiguration)
    }

    private var credentialsSection: some View {
        SettingsSubsection(label: "Credentials") {
            VStack(alignment: .leading, spacing: 12) {
                secretRow(
                    title: "Slack bot token",
                    text: $botToken,
                    saved: botTokenSaved,
                    savedMessage: "Bot token saved in Keychain",
                    missingMessage: "No Slack bot token saved",
                    saveTitle: "Save Bot Token",
                    saveAction: saveBotToken,
                    removeAction: removeBotToken
                )

                secretRow(
                    title: "Slack signing secret",
                    text: $signingSecret,
                    saved: signingSecretSaved,
                    savedMessage: "Signing secret saved in Keychain",
                    missingMessage: "No Slack signing secret saved",
                    saveTitle: "Save Signing Secret",
                    saveAction: saveSigningSecret,
                    removeAction: removeSigningSecret
                )

                secretRow(
                    title: "Socket Mode app token",
                    text: $appToken,
                    saved: appTokenSaved,
                    savedMessage: "Socket Mode app token saved in Keychain",
                    missingMessage: "No Slack Socket Mode app token saved",
                    saveTitle: "Save App Token",
                    saveAction: saveAppToken,
                    removeAction: removeAppToken
                )

                Text(
                    "Slack secrets are stored in Keychain and are never written to the Slack configuration file.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
        }
    }

    private var allowlistSection: some View {
        SettingsSubsection(label: "Access") {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelMultilineSettingsField(
                    title: "Workspace IDs",
                    text: $configuredTeamIdsText,
                    help:
                        "Optional Slack team IDs, such as T0123ABC. Leave empty only when the saved bot token's workspace is the entire allowed space."
                )
                AgentChannelMultilineSettingsField(
                    title: "Readable Channel IDs",
                    text: $readableChannelIdsText,
                    help: "Slack channel IDs Osaurus may list, read, or search, such as C0123ABC."
                )
                AgentChannelMultilineSettingsField(
                    title: "Authorized Sender IDs",
                    text: $senderAllowlistText,
                    help:
                        "Slack user IDs allowed to trigger inbound Agent Channel handling. Keep this explicit for group channels."
                )
                SettingsToggle(
                    title: "Enable Slack Writes",
                    description:
                        "Allow send/reply tools for write-allowlisted Slack channels. The global channel write switch must also be on.",
                    isOn: $writeEnabled
                )
                AgentChannelMultilineSettingsField(
                    title: "Writable Channel IDs",
                    text: $writableChannelIdsText,
                    help: "Slack channel IDs Osaurus may post to when Slack writes are enabled."
                )
                SettingsToggle(
                    title: "Allow Broadcast Mentions",
                    description:
                        "Permit @channel, @here, and <!subteam> mentions in outgoing Slack messages. Leave off unless the workspace expects that behavior.",
                    isOn: $allowBroadcastMentions
                )
                StyledSettingsTextField(
                    label: "Default Read Limit",
                    text: $defaultReadLimit,
                    placeholder: "50",
                    help: "Default recent-message count for Slack reads. Clamped to 1-100."
                )
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: saveConfiguration) {
                    Text("Save Slack Settings", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle(isPrimary: true))

                Button(action: testConnection) {
                    Text(isTesting ? "Testing..." : "Test Connection", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(isTesting || !botTokenSaved)

                Spacer(minLength: 0)
            }

            if let statusMessage {
                AgentChannelInlineStatusMessage(message: statusMessage, isError: statusIsError)
            }
        }
    }

    private func secretRow(
        title: String,
        text: Binding<String>,
        saved: Bool,
        savedMessage: String,
        missingMessage: String,
        saveTitle: String,
        saveAction: @escaping () -> Void,
        removeAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SecureField(title, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )

                Button(action: saveAction) {
                    Text(LocalizedStringKey(saveTitle), bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle(isPrimary: true))
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: removeAction) {
                    Text("Remove", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle(isDestructive: true))
                .disabled(!saved)
            }

            AgentChannelSecretStatusRow(
                saved: saved,
                savedMessage: savedMessage,
                missingMessage: missingMessage
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

    private func saveBotToken() {
        do {
            try SlackConnectionService.shared.saveBotToken(botToken)
            botToken = ""
            botTokenSaved = true
            Task {
                await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            }
            showStatus("Slack bot token saved", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func removeBotToken() {
        _ = SlackConnectionService.shared.deleteBotToken()
        botToken = ""
        botTokenSaved = false
        Task {
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
        }
        showStatus("Slack bot token removed", isError: false)
    }

    private func saveSigningSecret() {
        do {
            try SlackConnectionService.shared.saveSigningSecret(signingSecret)
            signingSecret = ""
            signingSecretSaved = true
            showStatus("Slack signing secret saved", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func removeSigningSecret() {
        _ = SlackConnectionService.shared.deleteSigningSecret()
        signingSecret = ""
        signingSecretSaved = false
        showStatus("Slack signing secret removed", isError: false)
    }

    private func saveAppToken() {
        do {
            try SlackConnectionService.shared.saveAppToken(appToken)
            appToken = ""
            appTokenSaved = true
            Task {
                await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            }
            showStatus("Slack Socket Mode app token saved", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func removeAppToken() {
        _ = SlackConnectionService.shared.deleteAppToken()
        appToken = ""
        appTokenSaved = false
        Task {
            await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
        }
        showStatus("Slack Socket Mode app token removed", isError: false)
    }

    private func saveConfiguration() {
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
            loadConfiguration()
            Task {
                await AgentChannelTransportSupervisor.shared.refreshSlackRuntime()
            }
            showStatus("Slack settings saved", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func testConnection() {
        isTesting = true
        Task {
            let diagnostics = await SlackConnectionService.shared.diagnostics()
            await MainActor.run {
                isTesting = false
                if diagnostics.failures.isEmpty {
                    showStatus("Slack connection status: \(diagnostics.status)", isError: false)
                } else {
                    showStatus(diagnostics.failures.joined(separator: " "), isError: true)
                }
            }
        }
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func parseIds(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ", \n\t")
        return SlackConnectionConfiguration.normalizedIds(
            text.components(separatedBy: separators)
        )
    }
}

struct AgentChannelMultilineSettingsField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    @Binding var text: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 58)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(themeManager.currentTheme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                        )
                )
            Text(LocalizedStringKey(help), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AgentChannelSecretStatusRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let saved: Bool
    let savedMessage: String
    let missingMessage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: saved ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
            Text(LocalizedStringKey(saved ? savedMessage : missingMessage), bundle: .module)
                .font(.system(size: 11))
        }
        .foregroundColor(saved ? themeManager.currentTheme.successColor : themeManager.currentTheme.tertiaryText)
    }
}

struct AgentChannelInlineStatusMessage: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let message: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(isError ? themeManager.currentTheme.warningColor : themeManager.currentTheme.successColor)
    }
}
