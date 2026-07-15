//
//  DiscordSettingsView.swift
//  osaurus
//
//  Configuration sheet for the native Discord channel.
//

import SwiftUI

struct DiscordSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var botToken: String = ""
    @State private var guildIdsText: String = ""
    @State private var readableChannelIdsText: String = ""
    @State private var writableChannelIdsText: String = ""
    @State private var writeEnabled: Bool = false
    @State private var defaultReadLimit: String = "50"
    @State private var tokenSaved: Bool = false
    @State private var statusMessage: String?
    @State private var statusDetails: [String] = []
    @State private var statusIsError = false
    @State private var isTesting = false

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
                AgentChannelMultilineSettingsField(
                    title: L("Server IDs"),
                    text: $guildIdsText,
                    placeholder: L("123456789012345678 — one per line"),
                    help: L("Numeric server IDs Osaurus may inspect. At least one is required.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Readable Channel IDs"),
                    text: $readableChannelIdsText,
                    placeholder: L("987654321098765432 — one per line"),
                    help: L("Channels or threads agents may read and search.")
                )
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

    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            StyledSettingsTextField(
                label: L("Default Read Limit"),
                text: $defaultReadLimit,
                placeholder: "50",
                help: L("Default recent-message count for channel/thread reads. Clamped to 1-100.")
            )
        }
    }

    private func loadConfiguration() {
        let configuration = DiscordConnectionConfigurationStore.load()
        guildIdsText = configuration.configuredGuildIds.joined(separator: "\n")
        readableChannelIdsText = configuration.readableChannelIds.joined(separator: "\n")
        writableChannelIdsText = configuration.writableChannelIds.joined(separator: "\n")
        writeEnabled = configuration.writeEnabled
        defaultReadLimit = "\(configuration.defaultReadLimit)"
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
        let configuration = DiscordConnectionConfiguration(
            configuredGuildIds: parseIds(guildIdsText),
            readableChannelIds: parseIds(readableChannelIdsText),
            writableChannelIds: parseIds(writableChannelIdsText),
            writeEnabled: writeEnabled,
            defaultReadLimit: Int(defaultReadLimit) ?? 50
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
        _ = ToastManager.shared.success(L("Discord settings saved"))
        dismiss()
    }

    /// Persist the current draft first so diagnostics always test what the
    /// user sees in the form, not a stale save.
    private func testConnection() {
        guard persistPendingSecrets(), saveConfiguration() else { return }
        isTesting = true
        Task {
            let diagnostics = await DiscordConnectionService.shared.diagnostics()
            await MainActor.run {
                isTesting = false
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
