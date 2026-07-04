//
//  TelegramSettingsView.swift
//  osaurus
//
//  Configuration sheet for the native Telegram channel.
//

import SwiftUI

struct TelegramSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

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
    @State private var statusDetails: [String] = []
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var healthRefreshToken = 0
    @State private var isCheckingWebhook = false
    @State private var isRemovingWebhook = false
    @State private var webhookRegistered = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isWebhookBusy: Bool { isCheckingWebhook || isRemovingWebhook }

    var body: some View {
        AgentChannelSheetScaffold(
            icon: AgentChannelKind.telegram.icon,
            gradient: AgentChannelKind.telegram.brandGradient,
            title: AgentChannelKind.telegram.displayName,
            subtitle: L("Read and reply in allowlisted chats")
        ) {
            VStack(alignment: .leading, spacing: 20) {
                Text(
                    "Connect a Telegram bot so agents can read allowlisted chats and post only to write-allowlisted destinations.",
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
        .onAppear(perform: loadConfiguration)
    }

    private var credentialsSection: some View {
        SettingsSubsection(label: L("Credentials")) {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelSetupLink(
                    title: L("Create a bot with @BotFather, then paste its token"),
                    url: URL(string: "https://t.me/botfather")!
                )

                AgentChannelSecretField(
                    label: L("Bot Token"),
                    requirementHint: L("Required"),
                    placeholder: L("123456789:ABC..."),
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
                    title: L("Readable Chat IDs"),
                    text: $readableChatIdsText,
                    placeholder: L("-1001234567890 or @channelname — one per line"),
                    help: L("Chats, supergroups, or public channels agents may read.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Authorized Sender IDs"),
                    text: $senderAllowlistText,
                    placeholder: L("123456789 — one per line"),
                    help: L("Only these Telegram users can trigger inbound handling; required for receive.")
                )
            }
        }
    }

    private var sendingSection: some View {
        SettingsSubsection(label: L("Sending")) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: L("Allow Sending on Telegram"),
                    description: L("Let agents post to write-allowlisted Telegram chats. Channel writes must also be on globally."),
                    isOn: $writeEnabled.animation(.easeOut(duration: 0.2))
                )

                if writeEnabled {
                    AgentChannelMultilineSettingsField(
                        title: L("Writable Chat IDs"),
                        text: $writableChatIdsText,
                        placeholder: L("-1001234567890 — one per line"),
                        help: L("Chats agents may post to.")
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var receiveSection: some View {
        SettingsSubsection(label: L("Receive")) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: L("Store Incoming Messages"),
                    description: L("Keep authorized Telegram updates in the local inbox so agents can read and search them."),
                    isOn: $receiveStorageEnabled
                )
                SettingsToggle(
                    title: L("Enable Long Polling"),
                    description: L(
                        "Use Telegram getUpdates as the local desktop receive path. Only enable this when no other consumer is polling the same bot."
                    ),
                    isOn: $longPollingEnabled.animation(.easeOut(duration: 0.2))
                )

                if longPollingEnabled {
                    HStack(alignment: .top, spacing: 12) {
                        StyledSettingsTextField(
                            label: L("Long Poll Limit"),
                            text: $longPollingLimit,
                            placeholder: "100",
                            help: L("Maximum updates per poll. Clamped to 1-100.")
                        )
                        StyledSettingsTextField(
                            label: L("Long Poll Timeout Seconds"),
                            text: $longPollingTimeoutSeconds,
                            placeholder: "20",
                            help: L("Telegram long-poll timeout. Clamped to 1-50 seconds.")
                        )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Text(
                    "Reads serve messages from the local inbox; without long polling, new activity is not fetched.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                AgentChannelTransportHealthView(
                    connectionId: TelegramConnectionService.nativeConnectionId,
                    transportId: TelegramLongPollTransportRuntime.transportId,
                    title: L("Long polling receive"),
                    notRunningHint: L(
                        "Long polling is not running. Save a bot token, enable long polling, and add authorized sender IDs to start it."
                    ),
                    refreshToken: healthRefreshToken
                )

                webhookTools
            }
        }
    }

    private var webhookTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentChannelSheetActionButton(
                    title: L("Check Webhook"),
                    busyTitle: L("Checking..."),
                    isBusy: isCheckingWebhook,
                    action: checkWebhook
                )
                .disabled(isWebhookBusy || !tokenSaved)

                if webhookRegistered {
                    AgentChannelSheetActionButton(
                        title: L("Remove Webhook"),
                        busyTitle: L("Removing..."),
                        isBusy: isRemovingWebhook,
                        isDestructive: true,
                        action: removeWebhook
                    )
                    .disabled(isWebhookBusy)
                }

                Spacer(minLength: 0)
            }

            Text(
                "A registered webhook blocks long polling; removing it hands receive back to long polling.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            VStack(alignment: .leading, spacing: 12) {
                StyledSettingsTextField(
                    label: L("Default Read Limit"),
                    text: $defaultReadLimit,
                    placeholder: "50",
                    help: L("Default recent-message count for Telegram reads. Clamped to 1-100.")
                )
                SettingsToggle(
                    title: L("Ignore Self Messages"),
                    description: L("Ignore updates sent by this bot identity when inbound updates are handled."),
                    isOn: $ignoreSelfMessages
                )
                SettingsToggle(
                    title: L("Ignore Bot Messages"),
                    description: L("Ignore Telegram updates from bot accounts unless you explicitly trust bot senders."),
                    isOn: $ignoreBotMessages
                )
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

    private var hasPendingToken: Bool {
        !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Persist a pasted bot token to Keychain before the configuration save.
    private func persistPendingSecrets() -> Bool {
        guard hasPendingToken else { return true }
        do {
            try TelegramConnectionService.shared.saveBotToken(botToken)
            botToken = ""
            tokenSaved = true
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func removeToken() {
        _ = TelegramConnectionService.shared.deleteBotToken()
        botToken = ""
        tokenSaved = false
        webhookRegistered = false
        refreshReceiveRuntime()
        showStatus(L("Telegram bot token removed"), isError: false)
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
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
            await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
            await MainActor.run {
                isSaving = false
                _ = ToastManager.shared.success(L("Telegram settings saved"))
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
            await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
            let diagnostics = await TelegramConnectionService.shared.diagnostics()
            await MainActor.run {
                isTesting = false
                healthRefreshToken += 1
                webhookRegistered = diagnostics.webhook?.registered ?? webhookRegistered
                let presentation = AgentChannelStatusPresentation.diagnostics(
                    status: diagnostics.status
                )
                if diagnostics.failures.isEmpty {
                    showStatus(presentation.label, details: diagnostics.notes, isError: false)
                } else {
                    showStatus(
                        presentation.label,
                        details: diagnostics.failures + diagnostics.notes,
                        isError: true
                    )
                }
            }
        }
    }

    private func checkWebhook() {
        isCheckingWebhook = true
        Task {
            do {
                let info = try await TelegramConnectionService.shared.webhookInfo()
                let redactedURL = TelegramConnectionService.shared.redactSecrets(in: info.url)
                await MainActor.run {
                    isCheckingWebhook = false
                    webhookRegistered = info.isRegistered
                    if info.isRegistered {
                        var details = [
                            L("Registered webhook: \(redactedURL)")
                        ]
                        if let pending = info.pendingUpdateCount {
                            details.append(L("Pending updates: \(pending)"))
                        }
                        showStatus(
                            L("A webhook is registered. Long polling conflicts with it (409) until the webhook is removed."),
                            details: details,
                            isError: true
                        )
                    } else {
                        showStatus(
                            L("No webhook is registered for this bot. Long polling is safe to enable."),
                            isError: false
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    isCheckingWebhook = false
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func removeWebhook() {
        isRemovingWebhook = true
        Task {
            do {
                let info = try await TelegramConnectionService.shared.clearWebhook()
                await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
                await MainActor.run {
                    isRemovingWebhook = false
                    webhookRegistered = info.isRegistered
                    healthRefreshToken += 1
                    if info.isRegistered {
                        showStatus(
                            L("Telegram still reports a registered webhook. Wait a moment and check again."),
                            isError: true
                        )
                    } else {
                        showStatus(
                            L("Webhook removed. Long polling can receive updates now."),
                            isError: false
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    isRemovingWebhook = false
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    /// Restart the long-poll runtime after a config change, then refresh the
    /// inline health card once the supervisor has re-evaluated.
    private func refreshReceiveRuntime() {
        Task {
            await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
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
        return TelegramConnectionConfiguration.normalizedIds(
            text.components(separatedBy: separators)
        )
    }
}
