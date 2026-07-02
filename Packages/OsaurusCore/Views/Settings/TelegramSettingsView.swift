//
//  TelegramSettingsView.swift
//  osaurus
//
//  Manual configuration for the native Telegram connection.
//

import SwiftUI

struct TelegramSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var botToken: String = ""
    @State private var readableChatIdsText: String = ""
    @State private var writableChatIdsText: String = ""
    @State private var senderAllowlistText: String = ""
    @State private var writeEnabled: Bool = false
    @State private var defaultReadLimit: String = "50"
    @State private var ignoreSelfMessages: Bool = true
    @State private var ignoreBotMessages: Bool = true
    @State private var receiveStorageEnabled: Bool = true
    @State private var longPollingEnabled: Bool = false
    @State private var longPollingLimit: String = "100"
    @State private var longPollingTimeoutSeconds: String = "20"
    @State private var tokenSaved: Bool = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isTesting = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        SettingsSubsection(label: "Telegram") {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Connect a Telegram bot so Osaurus can read allowlisted chats and post only to write-allowlisted destinations.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

                credentialsSection
                SettingsDivider()
                allowlistSection
                SettingsDivider()
                receiveSection
                SettingsDivider()
                actionsSection
            }
        }
        .onAppear(perform: loadConfiguration)
    }

    private var credentialsSection: some View {
        SettingsSubsection(label: "Credentials") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    SecureField("Telegram bot token", text: $botToken)
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

                    Button(action: saveToken) {
                        Text("Save Token", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle(isPrimary: true))
                    .disabled(botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(action: removeToken) {
                        Text("Remove", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle(isDestructive: true))
                    .disabled(!tokenSaved)
                }

                AgentChannelSecretStatusRow(
                    saved: tokenSaved,
                    savedMessage: "Bot token saved in Keychain",
                    missingMessage: "No Telegram bot token saved"
                )

                Text(
                    "The token is stored in Keychain and is never written to the Telegram configuration file.",
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
                    title: "Readable Chat IDs",
                    text: $readableChatIdsText,
                    help:
                        "Telegram chat IDs, supergroup IDs, or public @channel usernames Osaurus may read. Example: -1001234567890 or @release_notes."
                )
                AgentChannelMultilineSettingsField(
                    title: "Sender Allowlist",
                    text: $senderAllowlistText,
                    help:
                        "Telegram user IDs allowed to trigger inbound handling. Required for inbound receive when message storage or long polling is enabled."
                )
                SettingsToggle(
                    title: "Enable Telegram Writes",
                    description:
                        "Allow send tools for write-allowlisted Telegram chats. The global channel write switch must also be on.",
                    isOn: $writeEnabled
                )
                AgentChannelMultilineSettingsField(
                    title: "Writable Chat IDs",
                    text: $writableChatIdsText,
                    help: "Telegram chats Osaurus may post to when Telegram writes are enabled."
                )
                StyledSettingsTextField(
                    label: "Default Read Limit",
                    text: $defaultReadLimit,
                    placeholder: "50",
                    help: "Default recent-message count for Telegram reads. Clamped to 1-100."
                )
                SettingsToggle(
                    title: "Ignore Self Messages",
                    description: "Ignore updates sent by this bot identity when inbound updates are handled.",
                    isOn: $ignoreSelfMessages
                )
                SettingsToggle(
                    title: "Ignore Bot Messages",
                    description: "Ignore Telegram updates from bot accounts unless you explicitly trust bot senders.",
                    isOn: $ignoreBotMessages
                )
            }
        }
    }

    private var receiveSection: some View {
        SettingsSubsection(label: "Receive") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: "Store Incoming Messages",
                    description:
                        "Persist authorized Telegram updates in the local Agent Channel inbox for read/search and audit proof.",
                    isOn: $receiveStorageEnabled
                )
                SettingsToggle(
                    title: "Enable Long Polling",
                    description:
                        "Use Telegram getUpdates as the local desktop receive path. Only enable this when no other consumer is polling the same bot.",
                    isOn: $longPollingEnabled
                )
                HStack(alignment: .top, spacing: 12) {
                    StyledSettingsTextField(
                        label: "Long Poll Limit",
                        text: $longPollingLimit,
                        placeholder: "100",
                        help: "Maximum updates per poll. Clamped to 1-100."
                    )
                    StyledSettingsTextField(
                        label: "Long Poll Timeout Seconds",
                        text: $longPollingTimeoutSeconds,
                        placeholder: "20",
                        help: "Telegram long-poll timeout. Clamped to 1-50 seconds."
                    )
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: saveConfiguration) {
                    Text("Save Telegram Settings", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle(isPrimary: true))

                Button(action: testConnection) {
                    Text(isTesting ? "Testing..." : "Test Connection", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(isTesting || !tokenSaved)

                Spacer(minLength: 0)
            }

            if let statusMessage {
                AgentChannelInlineStatusMessage(message: statusMessage, isError: statusIsError)
            }
        }
    }

    private func loadConfiguration() {
        let configuration = TelegramConnectionConfigurationStore.load()
        readableChatIdsText = configuration.readableChatIds.joined(separator: "\n")
        writableChatIdsText = configuration.writableChatIds.joined(separator: "\n")
        senderAllowlistText = configuration.senderAllowlist.joined(separator: "\n")
        writeEnabled = configuration.writeEnabled
        defaultReadLimit = "\(configuration.defaultReadLimit)"
        ignoreSelfMessages = configuration.ignoreSelfMessages
        ignoreBotMessages = configuration.ignoreBotMessages
        receiveStorageEnabled = configuration.receiveStorageEnabled
        longPollingEnabled = configuration.longPollingEnabled
        longPollingLimit = "\(configuration.longPollingLimit)"
        longPollingTimeoutSeconds = "\(configuration.longPollingTimeoutSeconds)"
        tokenSaved = TelegramConnectionService.shared.hasBotToken()
    }

    private func saveToken() {
        do {
            try TelegramConnectionService.shared.saveBotToken(botToken)
            botToken = ""
            tokenSaved = true
            Task {
                await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
            }
            showStatus("Telegram bot token saved", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func removeToken() {
        _ = TelegramConnectionService.shared.deleteBotToken()
        botToken = ""
        tokenSaved = false
        Task {
            await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
        }
        showStatus("Telegram bot token removed", isError: false)
    }

    private func saveConfiguration() {
        let configuration = TelegramConnectionConfiguration(
            readableChatIds: parseIds(readableChatIdsText),
            writableChatIds: parseIds(writableChatIdsText),
            senderAllowlist: parseIds(senderAllowlistText),
            writeEnabled: writeEnabled,
            defaultReadLimit: Int(defaultReadLimit) ?? 50,
            ignoreSelfMessages: ignoreSelfMessages,
            ignoreBotMessages: ignoreBotMessages,
            receiveStorageEnabled: receiveStorageEnabled,
            longPollingEnabled: longPollingEnabled,
            longPollingLimit: Int(longPollingLimit) ?? 100,
            longPollingTimeoutSeconds: Int(longPollingTimeoutSeconds) ?? 20
        )
        do {
            try TelegramConnectionService.shared.saveConfiguration(configuration)
            loadConfiguration()
            Task {
                await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
            }
            showStatus("Telegram settings saved", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func testConnection() {
        isTesting = true
        Task {
            let diagnostics = await TelegramConnectionService.shared.diagnostics()
            await MainActor.run {
                isTesting = false
                if diagnostics.failures.isEmpty {
                    showStatus("Telegram connection status: \(diagnostics.status)", isError: false)
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
        return TelegramConnectionConfiguration.normalizedIds(
            text.components(separatedBy: separators)
        )
    }
}
