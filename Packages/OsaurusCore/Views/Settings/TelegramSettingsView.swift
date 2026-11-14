//
//  TelegramSettingsView.swift
//  osaurus
//
//  Configuration sheet for the native Telegram channel.
//

import SwiftUI

struct TelegramSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Set when this sheet is hosted inside the unified Add Channel picker;
    /// shows a back chevron that returns to the catalog.
    var onBack: (() -> Void)? = nil
    /// The bot's connection: `telegram`, or `telegram-<session>` for an extra
    /// bot. Empty for a new bot until its token checks out.
    @State private var connectionId: String

    init(
        onBack: (() -> Void)? = nil, connectionId: String = TelegramConnectionService.nativeConnectionId,
        newAccount: Bool = false
    ) {
        self.onBack = onBack
        _connectionId = State(initialValue: newAccount ? "" : connectionId)
    }

    private var isPendingAccount: Bool { connectionId.isEmpty }

    private var service: TelegramConnectionService { ChannelAccountServices.telegram(connectionId) ?? .shared }
    @State private var isConnectingAccount = false

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
    /// Incoming messages are handled by the events that listen to this
    /// channel; these read them so readiness checks stay honest.
    private var channelEvents: [OsaurusEvent] {
        EventManager.shared.events(kind: .telegram, connectionId: connectionId).filter(\.isEnabled)
    }
    private var inboundDispatchEnabled: Bool { !channelEvents.isEmpty }
    private var inboundAutoReplyEnabled: Bool {
        channelEvents.contains { $0.reply.replies(for: $0.action.kind) }
    }
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
    @State private var isDiscovering = false
    @State private var discovery: TelegramConnectionDiscovery?
    @State private var chatSearch = ""
    @State private var senderSearch = ""
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
        var readableChatIdsText: String
        var writableChatIdsText: String
        var senderAllowlistText: String
        var writeEnabled: Bool
        var defaultReadLimit: String
        var ignoreSelfMessages: Bool
        var ignoreBotMessages: Bool
        var receiveStorageEnabled: Bool
        var longPollingEnabled: Bool
        var longPollingLimit: String
        var longPollingTimeoutSeconds: String
    }

    private var currentDraft: DraftSnapshot {
        DraftSnapshot(
            readableChatIdsText: readableChatIdsText,
            writableChatIdsText: writableChatIdsText,
            senderAllowlistText: senderAllowlistText,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            ignoreSelfMessages: ignoreSelfMessages,
            ignoreBotMessages: ignoreBotMessages,
            receiveStorageEnabled: receiveStorageEnabled,
            longPollingEnabled: longPollingEnabled,
            longPollingLimit: longPollingLimit,
            longPollingTimeoutSeconds: longPollingTimeoutSeconds
        )
    }

    private var isWebhookBusy: Bool { isCheckingWebhook || isRemovingWebhook }

    var body: some View {
        AgentChannelSetupScaffold(
            icon: AgentChannelKind.telegram.icon,
            gradient: AgentChannelKind.telegram.brandGradient,
            title: isPendingAccount
                ? ChannelAccounts.newTitle(.telegram)
                : ChannelAccounts.displayName(connectionId: connectionId) ?? AgentChannelKind.telegram.displayName,
            subtitle: L("Read and reply in allowlisted chats"),
            sections: AgentChannelProviderSetupSection.sections,
            selection: $selectedSectionId,
            sectionStatus: sectionStatus(for:),
            onBack: onBack,
            pendingAccount: isPendingAccount
                ? AgentChannelPendingAccount(
                    actionTitle: L("Connect"), isWorking: isConnectingAccount, canConnect: hasPendingToken,
                    connect: connectNewAccount)
                : nil
        ) { sectionId in
            VStack(alignment: .leading, spacing: theme.space.s20) {
                switch AgentChannelProviderSetupSection(rawValue: sectionId) {
                case .connect:
                    connectSectionContent
                case .receiving:
                    accessSectionContent
                case .routing:
                    routingSectionContent
                case .sending:
                    sendingSectionContent
                case .verify, nil:
                    stepVerifySection
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
            guard !isPendingAccount else { return }
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
        // A removed account stays removed.
        guard ChannelAccounts.account(connectionId: connectionId) != nil else { return }
        guard validationFailure() == nil else { return }
        guard (try? service.saveConfiguration(currentConfiguration())) != nil
        else { return }
        lastSavedDraft = currentDraft
        Task {
            await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
            await MainActor.run { healthRefreshToken += 1 }
        }
    }

    // MARK: - Section state

    private func sectionCompleted(_ sectionId: String) -> Bool {
        switch AgentChannelProviderSetupSection(rawValue: sectionId) {
        case .connect:
            return tokenSaved && longPollingEnabled && receiveStorageEnabled
        case .receiving:
            return !parseIds(readableChatIdsText).isEmpty && !parseIds(senderAllowlistText).isEmpty
        case .routing:
            return inboundDispatchEnabled
        case .sending:
            return writeEnabled
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

    // MARK: - Section content

    private var connectSectionContent: some View {
        VStack(alignment: .leading, spacing: theme.space.s20) {
            if !isPendingAccount {
                ChannelAccountNameField(connectionId: connectionId, kind: .telegram)
            }

            Text(
                "Osaurus polls Telegram for new messages — no webhook or public URL is needed.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            stepCreateBotSection
            stepTokenSection
            if !isPendingAccount {
                stepReceiveSection
                ChannelAccountRemoveSection(connectionId: connectionId, kind: .telegram) { dismiss() }
            }
        }
    }

    /// Checks the pasted token with Telegram, then keeps the bot as its own
    /// connection and opens the rest of its setup.
    private func connectNewAccount() {
        isConnectingAccount = true
        clearStatus()
        Task {
            do {
                let id = try await ChannelAccountCreation.addBot(kind: .telegram, token: botToken)
                botToken = ""
                connectionId = id
                loadConfiguration()
                isConnectingAccount = false
                withAnimation(theme.motion.quick) {
                    selectedSectionId = AgentChannelProviderSetupSection.receiving.rawValue
                }
                refreshDiscovery(showStatus: false)
            } catch {
                isConnectingAccount = false
                showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private var accessSectionContent: some View {
        VStack(alignment: .leading, spacing: theme.space.s20) {
            stepAccessSection
            advancedSection
        }
    }

    private var routingSectionContent: some View {
        ChannelRoutingSection(kind: .telegram, connectionId: connectionId)
    }

    private var sendingSectionContent: some View {
        VStack(alignment: .leading, spacing: theme.space.s20) {
            sendingSection
            ChannelPostingSection(kind: .telegram, connectionId: connectionId)
        }
    }

    // MARK: - Guided setup steps

    private var stepCreateBotSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            AgentChannelSectionHeading(L("Create the bot with @BotFather"))

            AgentChannelSetupLink(
                title: L("Open @BotFather in Telegram"),
                url: URL(string: "https://t.me/botfather")!
            )

            AgentChannelCopyableCommand(
                command: "/newbot",
                caption: L("Creates the bot and prints its token."),
                onCopied: { showStatus(L("Command copied"), isError: false) }
            )
            AgentChannelCopyableCommand(
                command: "/setprivacy",
                caption: L("Choose your bot, then Disable — otherwise the bot cannot see group messages."),
                onCopied: { showStatus(L("Command copied"), isError: false) }
            )
        }
    }

    private var stepTokenSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            AgentChannelSectionHeading(L("Paste the bot token"))

            AgentChannelSecretField(
                label: L("Bot Token"),
                requirementHint: L("Required"),
                placeholder: L("123456789:ABC..."),
                text: $botToken,
                saved: tokenSaved,
                onRemove: removeToken
            )

            Text(
                "Saved to the macOS Keychain when you load from Telegram, test the connection, or press Done.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
        }
    }

    private var stepAccessSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            AgentChannelSectionHeading(L("Choose chats and people"))

            HStack {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(discovery == nil ? L("Load recent Telegram choices") : L("Telegram choices loaded"))
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    Text(
                        "Send the bot a message (or add it to a group and post there), then load pending chats and senders.",
                        bundle: .module
                    )
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                AgentChannelSheetActionButton(
                    title: discovery == nil ? L("Load from Telegram") : L("Refresh"),
                    busyTitle: L("Loading..."),
                    isBusy: isDiscovering,
                    action: { refreshDiscovery(showStatus: true) }
                )
                .disabled(isDiscovering || (!tokenSaved && !hasPendingToken))
            }
            if let discovery {
                telegramChatSelector(discovery)
                telegramSenderSelector(discovery)
                ForEach(discovery.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .textStyle(.micro)
                        .foregroundColor(theme.status.warning.foreground)
                }
            }

            Text(
                "Read lets agents see a chat, Write lets them post there, and Allow marks whose messages are handled. Manual ID fields are under Advanced.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Identifiable wrappers so discovered chats/users fit the shared
    /// selector list shaping.
    private struct TelegramChatRow: Identifiable, Equatable {
        let chat: TelegramChat
        var id: String { chat.stableId }
    }

    private struct TelegramSenderRow: Identifiable, Equatable {
        let user: TelegramUser
        var id: String { "\(user.id)" }
    }

    private func telegramChatSelector(_ discovery: TelegramConnectionDiscovery) -> some View {
        let readableIds = Set(parseIds(readableChatIdsText))
        let writableIds = Set(parseIds(writableChatIdsText))
        let shaped = AgentChannelSelectorList.shape(
            discovery.chats.map { TelegramChatRow(chat: $0) },
            query: chatSearch,
            fields: { [$0.chat.displayName, $0.id, $0.chat.type] },
            state: {
                AgentChannelReadWriteSelection(
                    read: readableIds.contains($0.id),
                    write: writableIds.contains($0.id)
                )
            },
            isSelected: { $0.isSelected }
        )
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack {
                Text("Recent Chats", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Text("\(discovery.chats.count) found")
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }

            AgentChannelSelectorSearchField(
                placeholder: L("Search chats by name or ID"),
                text: $chatSearch
            )

            AgentChannelSelectorListCard(
                shaped: shaped,
                emptyText: L("No matching Telegram chats")
            ) { item in
                telegramChatRow(item.entry.chat, access: item.state)
            }
        }
    }

    private func telegramChatRow(
        _ chat: TelegramChat,
        access: AgentChannelReadWriteSelection
    ) -> some View {
        let kind = AgentChannelRoomKind.from(providerKind: chat.type)
        return HStack(spacing: theme.space.s8) {
            Image(systemName: kind.icon)
                .glyphSize(.footnote, weight: .semibold)
                .foregroundColor(theme.text.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s4) {
                    Text(chat.displayName)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    if let badge = kind.badgeLabel {
                        StatusChip(badge, tone: .neutral)
                    }
                }
                Text(chat.stableId)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer(minLength: 6)

            AgentChannelSelectorToggle(title: L("Read"), selected: access.read) {
                readableChatIdsText = toggledIdText(readableChatIdsText, id: chat.stableId)
            }
            AgentChannelSelectorToggle(title: L("Write"), selected: access.write) {
                writableChatIdsText = toggledIdText(writableChatIdsText, id: chat.stableId)
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
    }

    private func telegramSenderSelector(_ discovery: TelegramConnectionDiscovery) -> some View {
        let allowedIds = Set(parseIds(senderAllowlistText))
        let allowedCount = discovery.users.filter { allowedIds.contains("\($0.id)") }.count
        let shaped = AgentChannelSelectorList.shape(
            discovery.users.map { TelegramSenderRow(user: $0) },
            query: senderSearch,
            fields: { [$0.user.displayName, $0.id] },
            state: { allowedIds.contains($0.id) },
            isSelected: { $0 }
        )
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack {
                Text("Authorized Senders", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Text("\(allowedCount) allowed · \(discovery.users.count) people", bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }

            AgentChannelSelectorSearchField(
                placeholder: L("Search people by name or ID"),
                text: $senderSearch
            )

            AgentChannelSelectorListCard(
                shaped: shaped,
                emptyText: L("No matching Telegram senders"),
                maxHeight: 200
            ) { item in
                telegramSenderSelectionRow(item.entry.user, selected: item.state)
            }
        }
    }

    private func telegramSenderSelectionRow(_ user: TelegramUser, selected: Bool) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "person.crop.circle.fill")
                .glyphSize(.medium)
                .foregroundColor(theme.text.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(user.displayName)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Text("\(user.id)")
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer(minLength: 6)

            AgentChannelSelectorToggle(title: L("Allow"), selected: selected) {
                senderAllowlistText = toggledIdText(senderAllowlistText, id: "\(user.id)")
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
    }

    private var sendingSection: some View {
        SettingsFieldRow(label: "Sending") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                SettingsToggle(
                    title: "Allow Sending on Telegram",
                    description: "Let agents post to write-allowlisted Telegram chats. The global Sending switch in Channels must also be on.",
                    isOn: $writeEnabled.animation(theme.motion.quick)
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

    private var stepReceiveSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            AgentChannelSectionHeading(L("Turn on receiving"))

            SettingsToggle(
                title: "Receive Messages",
                description: L(
                    "Osaurus continuously asks Telegram for new messages while the app runs (long polling). Turn this off only if another program polls the same bot."
                ),
                isOn: $longPollingEnabled.animation(theme.motion.quick)
            )
            SettingsToggle(
                title: "Store Incoming Messages",
                description: "Keep authorized Telegram updates in the local inbox so agents can read and search them.",
                isOn: $receiveStorageEnabled
            )

            if !longPollingEnabled {
                Text(
                    "Receiving is off: agents will not see new Telegram messages and no agent can reply.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.status.warning.foreground)
                .fixedSize(horizontal: false, vertical: true)
            }

            webhookTools
        }
    }


    private var stepVerifySection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            AgentChannelSectionHeading(L("Verify an incoming message"))

            Text(
                "Changes save automatically, and receiving starts once Connect and Receiving are complete. Send the bot any message from an authorized sender in a readable chat, then watch each stage appear here.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelTransportHealthView(
                connectionId: connectionId,
                transportId: TelegramLongPollTransportRuntime.transportId,
                title: L("Telegram receive"),
                notRunningHint: L(
                    "Receiving is not running. Add a bot token, turn on Receive Messages, then add readable chats and authorized senders to start it."
                ),
                refreshToken: healthRefreshToken
            )

            AgentChannelInboundActivityListView(
                connectionId: connectionId,
                emptyHint: L(
                    "No incoming Telegram messages yet this session. Send the bot a message and press “Verify incoming message”."
                ),
                refreshToken: activityRefreshToken
            )

            AgentChannelSheetActionButton(
                title: L("Verify incoming message"),
                busyTitle: L("Waiting for a Telegram message..."),
                isBusy: isVerifying,
                action: verifyIncomingMessage
            )
            .disabled(isVerifying || isSaving || isTesting)
        }
    }


    private var webhookTools: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s10) {
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
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                Text(
                    "Manual IDs are a fallback for chats or senders not returned by discovery.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)

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
                HStack(alignment: .top, spacing: theme.space.s12) {
                    SettingsTextFieldRow(
                        label: "Long Poll Limit",
                        text: $longPollingLimit,
                        placeholder: "100",
                        help: "Maximum updates per poll. Clamped to 1-100."
                    )
                    SettingsTextFieldRow(
                        label: "Long Poll Timeout Seconds",
                        text: $longPollingTimeoutSeconds,
                        placeholder: "20",
                        help: "Telegram long-poll timeout. Clamped to 1-50 seconds."
                    )
                }
                SettingsTextFieldRow(
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

    private func loadConfiguration() {
        let configuration = TelegramConnectionConfigurationStore.load(connectionId: connectionId)
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
        Task { tokenSaved = await service.hasBotTokenOffMain() }
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
            try await service.saveBotTokenOffMain(botToken)
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
        webhookRegistered = false
        Task {
            await service.deleteBotTokenOffMain()
            refreshReceiveRuntime()
        }
        showStatus(L("Telegram bot token removed"), isError: false)
    }

    /// First cross-field problem the save would reject, or nil when the
    /// draft is persistable. Shared by autosave (skip silently) and the
    /// explicit save (show and navigate to the section).
    private func validationFailure() -> (message: String, section: AgentChannelProviderSetupSection)? {
        if inboundDispatchEnabled, inboundAutoReplyEnabled {
            guard writeEnabled else {
                return (L("Enable Telegram sending before automatic channel replies."), .sending)
            }
            let missing = ChannelAgentRoster.autoReplyRoomsNotWritable(
                ChannelAgentRoster.replyingRules(channelEvents),
                readable: parseIds(readableChatIdsText), writable: parseIds(writableChatIdsText))
            guard missing.isEmpty else {
                return (
                    L(
                        "Automatic replies need these Telegram chats to be writable: \(missing.joined(separator: ", ")). Make them writable, or set their routing rules to After approval."
                    ),
                    .receiving
                )
            }
        }
        return nil
    }

    private func currentConfiguration() -> TelegramConnectionConfiguration {
        TelegramConnectionConfiguration(
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
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
        if let failure = validationFailure() {
            showStatus(failure.message, isError: true, section: failure.section)
            return false
        }
        do {
            try service.saveConfiguration(currentConfiguration())
            lastSavedDraft = currentDraft
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    /// Persist the configuration, hold the Save button busy until diagnostics
    /// prove whether receive is active, then either close or show next steps.
    /// When the user wants receive (dispatch is on) and receive cannot
    /// actually run, the sheet stays open with the exact readiness blockers
    /// rather than dismissing on a superficially successful save.
    private func saveAndDismiss() {
        autosaveTask?.cancel()
        isSaving = true
        Task {
            guard await persistPendingSecrets(), saveConfiguration() else {
                isSaving = false
                return
            }
            await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
            let diagnostics = await service.diagnostics()
            let report = AgentChannelLiveProofReadiness.telegram(diagnostics)
            await MainActor.run {
                isSaving = false
                healthRefreshToken += 1
                webhookRegistered = diagnostics.webhook?.registered ?? webhookRegistered

                if inboundDispatchEnabled {
                    if report.isReadyForLiveProof {
                        _ = ToastManager.shared.success(
                            L("Telegram settings saved — receive is ready")
                        )
                        clearStatus()
                        dismiss()
                    } else {
                        showStatus(
                            L("Saved, but Telegram receive is not ready yet"),
                            details: report.blockers + report.notes,
                            isError: true,
                            section: .verify
                        )
                    }
                    return
                }

                let presentation = AgentChannelStatusPresentation.diagnostics(
                    status: diagnostics.status
                )
                if TelegramSettingsSavePolicy.shouldDismissAfterSave(diagnostics) {
                    if diagnostics.receiveReady,
                        diagnostics.failures.isEmpty,
                        presentation.tone == .success {
                        _ = ToastManager.shared.success(L("Telegram settings saved"))
                    } else {
                        _ = ToastManager.shared.warning(
                            presentation.label,
                            message: diagnostics.failures.first,
                            timeout: 8
                        )
                    }
                    clearStatus()
                    dismiss()
                } else {
                    showDiagnostics(diagnostics, presentation: presentation)
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
            await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
            let diagnostics = await service.diagnostics()
            await MainActor.run {
                isTesting = false
                healthRefreshToken += 1
                webhookRegistered = diagnostics.webhook?.registered ?? webhookRegistered
                showDiagnostics(diagnostics)
            }
        }
    }

    private func checkWebhook() {
        isCheckingWebhook = true
        Task {
            do {
                let info = try await service.webhookInfo()
                let redactedURL = service.redactSecrets(in: info.url)
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
                let info = try await service.clearWebhook()
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
            withAnimation(theme.motion.quick) {
                selectedSectionId = section.rawValue
            }
        } else if !isError {
            attentionSectionId = nil
        }
    }

    /// Discovery issues its own getUpdates call, which conflicts with an
    /// active long-poll runtime (Telegram allows one consumer). Pause the
    /// runtime around discovery and resume it afterwards.
    private func refreshDiscovery(showStatus announce: Bool) {
        isDiscovering = true
        Task {
            guard await persistPendingSecrets() else {
                isDiscovering = false
                return
            }
            await AgentChannelTransportSupervisor.shared.suspendTelegramRuntime(connectionId: connectionId)
            defer {
                Task {
                    await AgentChannelTransportSupervisor.shared.refreshTelegramRuntime()
                    await MainActor.run { healthRefreshToken += 1 }
                }
            }
            do {
                let loaded = try await service.discoverConfigurationOptions()
                await MainActor.run {
                    discovery = loaded
                    ChannelAccountNaming.adopt(ChannelAccountNaming.botName(loaded.bot), connectionId: connectionId)
                    isDiscovering = false
                    if announce {
                        showStatus(
                            L("Loaded recent Telegram chats and senders."),
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

    private func verifyIncomingMessage() {
        isVerifying = true
        showStatus(
            L("Waiting for a Telegram message. Send the bot a message now from an authorized sender in a readable chat."),
            isError: false
        )
        let start = Date()
        let autoReply = inboundAutoReplyEnabled
        Task {
            let outcome = await AgentChannelInboundVerifier.waitForTerminalEvent(
                connectionId: connectionId,
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
                        L("No Telegram message arrived within 90 seconds."),
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
            L("Confirm the message was sent in a chat selected as readable, by a person in Authorized Senders."),
            L("Confirm Receive Messages is on and the settings were saved."),
            L("Confirm no webhook is registered for the bot (use Check Webhook in the Connect section)."),
            L("Confirm bot privacy is disabled via @BotFather /setprivacy if the message was sent in a group."),
        ]
        if let warning = OsaurusRunningInstanceInspector.duplicateInstanceWarning(
            instanceCount: OsaurusRunningInstanceInspector.runningInstanceCount()
        ) {
            guidance.append(warning)
        }
        return guidance
    }

    private func showDiagnostics(
        _ diagnostics: TelegramConnectionDiagnostics,
        presentation suppliedPresentation: AgentChannelStatusPresentation? = nil
    ) {
        let presentation = suppliedPresentation
            ?? AgentChannelStatusPresentation.diagnostics(status: diagnostics.status)
        showStatus(
            presentation.label,
            details: diagnostics.failures + diagnostics.notes,
            isError: !diagnostics.failures.isEmpty || presentation.tone == .error
        )
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

    private func toggledIdText(_ text: String, id: String) -> String {
        var ids = parseIds(text)
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        return ids.joined(separator: "\n")
    }
}
