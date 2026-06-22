//
//  DiscordSettingsView.swift
//  osaurus
//
//  Manual configuration for the native Discord connection.
//

import SwiftUI

struct DiscordSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var botToken: String = ""
    @State private var guildIdsText: String = ""
    @State private var readableChannelIdsText: String = ""
    @State private var writableChannelIdsText: String = ""
    @State private var writeEnabled: Bool = false
    @State private var defaultReadLimit: String = "50"
    @State private var tokenSaved: Bool = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isTesting = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        SettingsSubsection(label: "Discord") {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Connect a Discord bot so Osaurus can read allowlisted channels and post only to write-allowlisted destinations.",
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
                HStack(spacing: 10) {
                    SecureField("Discord bot token", text: $botToken)
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

                HStack(spacing: 6) {
                    Image(systemName: tokenSaved ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                    Text(tokenSaved ? "Bot token saved in Keychain" : "No bot token saved", bundle: .module)
                        .font(.system(size: 11))
                }
                .foregroundColor(tokenSaved ? theme.successColor : theme.tertiaryText)

                Text(
                    "The token is stored in Keychain and is never written to the Discord configuration file.",
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
                multilineField(
                    title: "Server IDs",
                    text: $guildIdsText,
                    help: "Numeric Discord server IDs Osaurus may inspect for channel discovery."
                )
                multilineField(
                    title: "Readable Channel IDs",
                    text: $readableChannelIdsText,
                    help: "Numeric channel or thread IDs Osaurus may read. Recent reads are bounded."
                )
                SettingsToggle(
                    title: "Enable Discord Writes",
                    description:
                        "Allow send/reply tools for write-allowlisted destinations. Tool calls still require approval.",
                    isOn: $writeEnabled
                )
                multilineField(
                    title: "Writable Channel IDs",
                    text: $writableChannelIdsText,
                    help: "Numeric channel or thread IDs Osaurus may post to when writes are enabled."
                )
                StyledSettingsTextField(
                    label: "Default Read Limit",
                    text: $defaultReadLimit,
                    placeholder: "50",
                    help: "Default recent-message count for channel/thread reads. Clamped to 1-100."
                )
            }
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button(action: saveConfiguration) {
                Text("Save Discord Settings", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle(isPrimary: true))

            Button {
                testConnection()
            } label: {
                Text(isTesting ? "Testing..." : "Test Connection", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(isTesting || !tokenSaved)

            if let statusMessage {
                HStack(spacing: 6) {
                    Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .lineLimit(3)
                }
                .foregroundColor(statusIsError ? theme.warningColor : theme.successColor)
            }
        }
    }
    private func multilineField(
        title: String,
        text: Binding<String>,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 58)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            Text(LocalizedStringKey(help), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private func loadConfiguration() {
        let configuration = DiscordConnectionConfigurationStore.load()
        guildIdsText = configuration.configuredGuildIds.joined(separator: "\n")
        readableChannelIdsText = configuration.readableChannelIds.joined(separator: "\n")
        writableChannelIdsText = configuration.writableChannelIds.joined(separator: "\n")
        writeEnabled = configuration.writeEnabled
        defaultReadLimit = "\(configuration.defaultReadLimit)"
        tokenSaved = DiscordCredentialStore.hasBotToken()
    }

    private func saveToken() {
        do {
            try DiscordConnectionService.shared.saveBotToken(botToken)
            botToken = ""
            tokenSaved = true
            showStatus("Discord bot token saved", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func removeToken() {
        _ = DiscordConnectionService.shared.deleteBotToken()
        botToken = ""
        tokenSaved = false
        showStatus("Discord bot token removed", isError: false)
    }

    private func saveConfiguration() {
        let configuration = DiscordConnectionConfiguration(
            configuredGuildIds: parseIds(guildIdsText),
            readableChannelIds: parseIds(readableChannelIdsText),
            writableChannelIds: parseIds(writableChannelIdsText),
            writeEnabled: writeEnabled,
            defaultReadLimit: Int(defaultReadLimit) ?? 50
        )
        do {
            try DiscordConnectionService.shared.saveConfiguration(configuration)
            loadConfiguration()
            showStatus("Discord settings saved", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func testConnection() {
        isTesting = true
        Task {
            let diagnostics = await DiscordConnectionService.shared.diagnostics()
            await MainActor.run {
                isTesting = false
                if diagnostics.failures.isEmpty {
                    showStatus("Discord connection status: \(diagnostics.status)", isError: false)
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
        return DiscordConnectionConfiguration.normalizedIds(
            text.components(separatedBy: separators)
        )
    }
}
