//
//  IMessageSettingsView.swift
//  osaurus
//
//  Configuration sheet for the native iMessage channel.
//
//  Unlike the token-based providers, iMessage is entirely local: the
//  "connection" is this Mac's Messages.app plus the downloaded, digest-verified
//  `imsg` helper. Connect therefore verifies helper integrity and macOS
//  permissions (Full Disk Access, Messages Automation, Messages sign-in)
//  instead of credentials. Advanced private-API actions carry an explicit
//  security warning: they require SIP and Library Validation to be disabled
//  by the operator, and Osaurus never changes either protection itself.
//

import SwiftUI

struct IMessageSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var helperInstallState = IMessageHelperInstallState.shared
    @Environment(\.dismiss) private var dismiss

    /// Set when this sheet is hosted inside the unified Add Channel picker;
    /// shows a back chevron that returns to the catalog.
    var onBack: (() -> Void)? = nil

    @State private var readableChatIdsText: String = ""
    @State private var writableChatIdsText: String = ""
    @State private var senderAllowlistText: String = ""
    @State private var writeEnabled: Bool = false
    @State private var defaultReadLimit: String = "50"
    @State private var receiveStorageEnabled: Bool = true
    @State private var receivePollingEnabled: Bool = false
    @State private var pollIntervalSeconds: String = "3"
    @State private var attachmentIngestionEnabled: Bool = false
    @State private var ignoreSelfMessages: Bool = true
    @State private var advancedActionsEnabled: Bool = false
    @State private var enabledAdvancedActions: Set<IMessageConnectionConfiguration.AdvancedAction> = []
    @State private var inboundDispatchEnabled = false
    @State private var inboundAgentId: UUID?
    @State private var inboundRoutes: [AgentChannelDispatchRoute] = []
    @State private var inboundAutoReplyEnabled = false
    @State private var statusMessage: String?
    @State private var statusDetails: [String] = []
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isDiscovering = false
    @State private var isVerifying = false
    @State private var healthRefreshToken = 0
    @State private var activityRefreshToken = 0
    @State private var diagnostics: IMessageConnectionDiagnostics?
    @State private var discoveredChats: [DiscoveredChat] = []
    @State private var chatSearch = ""
    @State private var legacyMessagesPluginInstalled = false
    @State private var selectedSectionId: String = AgentChannelProviderSetupSection.connect.rawValue
    @State private var attentionSectionId: String?
    @State private var verifySucceeded = false
    @State private var lastSavedDraft: DraftSnapshot?
    @State private var autosaveTask: Task<Void, Never>?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private struct DiscoveredChat: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: String
        /// Participant handles from chats.list — feeds the sender picker.
        let participants: [String]
    }

    /// Everything the configuration save persists, as one Equatable value —
    /// a single `onChange` on this drives autosave.
    private struct DraftSnapshot: Equatable {
        var readableChatIdsText: String
        var writableChatIdsText: String
        var senderAllowlistText: String
        var writeEnabled: Bool
        var defaultReadLimit: String
        var receiveStorageEnabled: Bool
        var receivePollingEnabled: Bool
        var pollIntervalSeconds: String
        var attachmentIngestionEnabled: Bool
        var ignoreSelfMessages: Bool
        var advancedActionsEnabled: Bool
        var enabledAdvancedActions: Set<IMessageConnectionConfiguration.AdvancedAction>
        var inboundDispatchEnabled: Bool
        var inboundAgentId: UUID?
        var inboundRoutes: [AgentChannelDispatchRoute]
        var inboundAutoReplyEnabled: Bool
    }

    private var currentDraft: DraftSnapshot {
        DraftSnapshot(
            readableChatIdsText: readableChatIdsText,
            writableChatIdsText: writableChatIdsText,
            senderAllowlistText: senderAllowlistText,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            receiveStorageEnabled: receiveStorageEnabled,
            receivePollingEnabled: receivePollingEnabled,
            pollIntervalSeconds: pollIntervalSeconds,
            attachmentIngestionEnabled: attachmentIngestionEnabled,
            ignoreSelfMessages: ignoreSelfMessages,
            advancedActionsEnabled: advancedActionsEnabled,
            enabledAdvancedActions: enabledAdvancedActions,
            inboundDispatchEnabled: inboundDispatchEnabled,
            inboundAgentId: inboundAgentId,
            inboundRoutes: inboundRoutes,
            inboundAutoReplyEnabled: inboundAutoReplyEnabled
        )
    }

    var body: some View {
        AgentChannelSetupScaffold(
            icon: AgentChannelKind.imessage.icon,
            gradient: AgentChannelKind.imessage.brandGradient,
            title: AgentChannelKind.imessage.displayName,
            subtitle: L("Read and reply in allowlisted Messages chats on this Mac"),
            sections: AgentChannelProviderSetupSection.sections,
            selection: $selectedSectionId,
            sectionStatus: sectionStatus(for:),
            onBack: onBack
        ) { sectionId in
            VStack(alignment: .leading, spacing: 20) {
                switch AgentChannelProviderSetupSection(rawValue: sectionId) {
                case .connect:
                    connectSectionContent
                case .access:
                    accessSectionContent
                case .behavior:
                    behaviorSectionContent
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
            .disabled(isTesting || isSaving)
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
            loadConfiguration()
            legacyMessagesPluginInstalled = PluginRepositoryService.shared.plugins
                .first { $0.pluginId == "osaurus.messages" }?.isInstalled ?? false
            selectedSectionId = AgentChannelSetupFlow.initialSection(
                in: AgentChannelProviderSetupSection.sections,
                required: AgentChannelProviderSetupSection.requiredSectionIds,
                isComplete: { sectionCompleted($0) },
                fallback: AgentChannelProviderSetupSection.verify.rawValue
            )
            refreshDiagnostics()
        }
        .onChange(of: currentDraft) { _, _ in
            scheduleAutosave()
        }
        .onDisappear {
            autosaveTask?.cancel()
            autosaveNow()
        }
    }

    // MARK: - Autosave

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
        guard validationFailure() == nil else { return }
        guard (try? IMessageConnectionService.shared.saveConfiguration(currentConfiguration())) != nil
        else { return }
        lastSavedDraft = currentDraft
        refreshReceiveRuntime()
    }

    // MARK: - Section state

    /// Send-only is a valid setup: writing needs the helper and Messages
    /// Automation but neither Full Disk Access, the receive toggles, nor a
    /// sender allowlist. The receive requirements only apply when receiving
    /// is what the user turned on.
    private var isSendOnlySetup: Bool {
        !receivePollingEnabled && writeEnabled
    }

    private func sectionCompleted(_ sectionId: String) -> Bool {
        switch AgentChannelProviderSetupSection(rawValue: sectionId) {
        case .connect:
            guard diagnostics?.helperVerified ?? false else { return false }
            if isSendOnlySetup {
                return diagnostics?.automationMessages ?? false
            }
            return (diagnostics?.fullDiskAccess ?? false)
                && receivePollingEnabled
                && receiveStorageEnabled
        case .access:
            if isSendOnlySetup {
                return !parseIds(writableChatIdsText).isEmpty
            }
            return !parseIds(readableChatIdsText).isEmpty && !parseIds(senderAllowlistText).isEmpty
        case .behavior:
            return (inboundDispatchEnabled && (inboundAgentId != nil || !inboundRoutes.isEmpty)) || writeEnabled
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

    // MARK: - Connect

    private var connectSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                "iMessage runs entirely on this Mac: Osaurus reads the Messages database and sends through Messages.app using a pinned, integrity-verified helper. No account token or server is involved.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if legacyMessagesPluginInstalled {
                legacyPluginWarning
            }

            helperStatusSection
            SettingsDivider()
            permissionsSection
            SettingsDivider()
            stepReceiveSection
        }
    }

    private var legacyPluginWarning: some View {
        Label {
            Text(
                "The legacy “osaurus.messages” plugin is installed. It sends iMessages through its own path and does not use these allowlists. To avoid double-sends and confusing permissions prompts, remove that plugin once this channel is set up.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.warningColor)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(theme.warningColor)
        }
    }

    private var helperStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Messages helper"))

            helperRow
            if case .failed(let message) = helperInstallState.phase {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 23)
            }
            signedInRow
        }
    }

    private var helperRow: some View {
        let helperVerified = diagnostics?.helperVerified ?? false
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: helperIconName)
                .font(.system(size: 13))
                .foregroundColor(helperIconColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Integrity-verified helper"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(helperDetailText)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if !helperVerified && helperDownloadAvailable {
                AgentChannelSheetActionButton(
                    title: L("Download"),
                    busyTitle: helperInstallBusyTitle,
                    isBusy: helperInstallState.isBusy
                ) {
                    downloadHelper()
                }
            }
        }
    }

    /// imsg exposes no sign-in probe, so this row is informational unless a
    /// future helper release reports a definite state — never a false claim.
    private var signedInRow: some View {
        let signedIn: Bool? = diagnostics?.messagesSignedIn ?? nil
        let detail: String
        switch signedIn {
        case true?:
            detail = L("Messages.app is signed in and ready.")
        case false?:
            detail = L("Open Messages.app and sign in with your Apple Account.")
        default:
            detail = L(
                "Osaurus can't verify this automatically — make sure Messages.app is signed in with your Apple Account on this Mac."
            )
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: signedIn == true ? "checkmark.circle.fill" : "info.circle")
                .font(.system(size: 13))
                .foregroundColor(signedIn == true ? theme.successColor : theme.tertiaryText)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Signed in to Messages"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if signedIn == false {
                AgentChannelSheetActionButton(
                    title: L("Open Messages"),
                    busyTitle: L("..."),
                    isBusy: false
                ) {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/System/Applications/Messages.app"),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                    // Re-probe shortly after so the row updates once the
                    // user signs in.
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        refreshDiagnostics()
                    }
                }
            }
        }
    }

    private var helperIconName: String {
        switch diagnostics?.helperState {
        case "verified", "dev_override": return "checkmark.circle.fill"
        case "digest_mismatch", "unpinned": return "xmark.circle.fill"
        default: return "circle"
        }
    }

    private var helperIconColor: Color {
        switch diagnostics?.helperState {
        case "verified", "dev_override": return theme.successColor
        case "digest_mismatch", "unpinned": return theme.warningColor
        default: return theme.tertiaryText
        }
    }

    private var helperDetailText: String {
        switch diagnostics?.helperState {
        case "verified":
            return L("Pinned to an open-source release and checksum-verified before every launch.")
        case "dev_override":
            return L("Using the developer override binary.")
        case "digest_mismatch":
            return L("Integrity check failed — download again to restore a verified copy.")
        case "unpinned":
            return L("Release digests are not pinned in this build.")
        default:
            return L("Small one-time download, checksum-verified and required for all iMessage actions.")
        }
    }

    /// Offer the download when no helper resolved, or when a previous copy
    /// failed integrity (re-download restores a pin-matching install).
    private var helperDownloadAvailable: Bool {
        switch diagnostics?.helperState {
        case "missing", "digest_mismatch": return true
        default: return false
        }
    }

    private var helperInstallBusyTitle: String {
        switch helperInstallState.phase {
        case .downloading(let fraction):
            if let fraction {
                return String(
                    format: L("Downloading %d%%"),
                    Int((fraction * 100).rounded())
                )
            }
            return L("Downloading...")
        case .installing:
            return L("Verifying...")
        default:
            return L("...")
        }
    }

    private func downloadHelper() {
        Task {
            do {
                try await IMessageHelperInstaller.shared.installFromRelease()
            } catch {
                // State already reflects the failure; nothing else to do.
            }
            refreshDiagnostics()
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("macOS permissions"))

            permissionRow(
                .disk,
                detail: L("Required to read incoming messages from the Messages database.")
            )
            permissionRow(
                .automationMessages,
                detail: L("Required only for sending — Osaurus asks Messages.app to deliver each message.")
            )
        }
    }

    private func permissionRow(_ permission: SystemPermission, detail: String) -> some View {
        let granted = SystemPermissionService.shared.cachedIsGranted(permission)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundColor(granted ? theme.successColor : theme.tertiaryText)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if !granted {
                AgentChannelSheetActionButton(
                    title: permission == .disk ? L("Open Settings") : L("Grant"),
                    busyTitle: L("..."),
                    isBusy: false
                ) {
                    if permission == .disk {
                        SystemPermissionService.shared.openSystemSettings(for: permission)
                    } else {
                        SystemPermissionService.shared.requestPermission(permission)
                    }
                    // Re-probe shortly after the grant flow so the row updates.
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        refreshDiagnostics()
                    }
                }
            }
        }
    }

    private var stepReceiveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Turn on receiving"))

            SettingsToggle(
                title: L("Receive Messages"),
                description: L(
                    "Osaurus checks the Messages database for new messages in readable chats while the app runs."
                ),
                isOn: $receivePollingEnabled.animation(.easeOut(duration: 0.2))
            )
            SettingsToggle(
                title: L("Store Incoming Messages"),
                description: L("Keep authorized iMessages in the local inbox so agents can read and search them."),
                isOn: $receiveStorageEnabled
            )

            if !receivePollingEnabled {
                Text(
                    writeEnabled
                        ? L(
                            "Receiving is off — send-only setup. Agents can post to writable chats but will not see or reply to incoming iMessages."
                        )
                        : L("Receiving is off: agents will not see new iMessages and no agent can reply.")
                )
                .font(.system(size: 11))
                .foregroundColor(writeEnabled ? theme.tertiaryText : theme.warningColor)
                .fixedSize(horizontal: false, vertical: true)
            }

            if receivePollingEnabled {
                Text(
                    "Keep receiving enabled in only one copy of Osaurus on this Mac. A second running instance (for example a development build next to the installed app) watches the same Messages database and would reply independently, causing duplicate answers.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Access

    private var accessSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepAccessSection
            SettingsDivider()
            advancedSection
        }
    }

    private var stepAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Choose chats and people"))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(discoveredChats.isEmpty ? L("Load recent Messages chats") : L("Messages chats loaded"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Requires the verified helper and Full Disk Access. Chats are listed from this Mac's Messages database; nothing leaves the machine.",
                        bundle: .module
                    )
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                AgentChannelSheetActionButton(
                    title: discoveredChats.isEmpty ? L("Load from Messages") : L("Refresh"),
                    busyTitle: L("Loading..."),
                    isBusy: isDiscovering,
                    action: refreshChatDiscovery
                )
                .disabled(isDiscovering)
            }

            if !discoveredChats.isEmpty {
                chatSelector
            }

            Text(
                "Read lets agents see a chat, Write lets them post there, and the sender allowlist marks whose messages are handled. Manual IDs are under Advanced.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            senderPickerSection

            if parseIds(senderAllowlistText).isEmpty && !parseIds(readableChatIdsText).isEmpty {
                missingSendersWarning
            }
        }
    }

    /// People are picked, not typed: candidates come from the participants
    /// of chats marked Read (plus handles derived from direct-chat GUIDs and
    /// anything already allowlisted). Manual entry lives under Advanced.
    private var senderPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authorized senders", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "Only messages from allowed people are handled — required for receive. Manual handles are under Advanced.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            if senderCandidates.isEmpty {
                Text(
                    "Mark a chat as Read above to choose its people here, or add handles under Advanced.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                let allowed = Set(parseIds(senderAllowlistText))
                VStack(spacing: 0) {
                    ForEach(senderCandidates, id: \.self) { handle in
                        HStack(spacing: 9) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .frame(width: 20)
                            Text(handle)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            AgentChannelSelectorToggle(
                                title: L("Allow"),
                                selected: allowed.contains(handle)
                            ) {
                                senderAllowlistText = toggledIdText(senderAllowlistText, id: handle)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        if handle != senderCandidates.last {
                            SettingsDivider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground.opacity(0.4))
                )
            }
        }
    }

    /// Handles offered by the sender picker, deduplicated and normalized.
    private var senderCandidates: [String] {
        let readable = Set(parseIds(readableChatIdsText))
        var handles: [String] = []
        for chat in discoveredChats where readable.contains(chat.id) {
            handles.append(contentsOf: chat.participants)
        }
        handles.append(contentsOf: suggestedSenderHandles)
        // Already-allowlisted handles stay visible even when the chat list
        // has not been loaded this session.
        handles.append(contentsOf: parseIds(senderAllowlistText))
        return IMessageConnectionConfiguration.normalizedIds(handles)
    }

    /// The most common setup trap: chats are selected but the sender
    /// allowlist is empty, so receiving silently never starts.
    private var missingSendersWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(theme.warningColor)
                .padding(.top, 1)
            Text(
                "Receiving stays off until you add at least one authorized sender.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.warningColor)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Handles extractable from the selected readable chats: for a direct
    /// chat GUID ("service;-;handle") that's the participant's handle; bare
    /// handles pass through. Group chats (";+;") carry no single sender.
    private var suggestedSenderHandles: [String] {
        var handles: [String] = []
        for id in parseIds(readableChatIdsText) {
            if let range = id.range(of: ";-;") {
                let handle = String(id[range.upperBound...])
                if !handle.isEmpty { handles.append(handle) }
            } else if !id.contains(";") {
                handles.append(id)
            }
        }
        return IMessageConnectionConfiguration.normalizedIds(handles)
    }

    private var chatSelector: some View {
        let readableIds = Set(parseIds(readableChatIdsText))
        let writableIds = Set(parseIds(writableChatIdsText))
        let shaped = AgentChannelSelectorList.shape(
            discoveredChats,
            query: chatSearch,
            fields: { [$0.name, $0.id, $0.kind] },
            state: {
                AgentChannelReadWriteSelection(
                    read: readableIds.contains($0.id),
                    write: writableIds.contains($0.id)
                )
            },
            isSelected: { $0.isSelected }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Chats", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(discoveredChats.count) found")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            AgentChannelSelectorSearchField(
                placeholder: L("Search chats by name or ID"),
                text: $chatSearch
            )

            AgentChannelSelectorListCard(
                shaped: shaped,
                emptyText: L("No matching Messages chats")
            ) { item in
                chatRow(item.entry, access: item.state)
            }
        }
    }

    private func chatRow(
        _ chat: DiscoveredChat,
        access: AgentChannelReadWriteSelection
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: chat.kind == "group" ? "person.3.fill" : "person.crop.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(chat.id)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            AgentChannelSelectorToggle(title: L("Read"), selected: access.read) {
                readableChatIdsText = toggledIdText(readableChatIdsText, id: chat.id)
            }
            AgentChannelSelectorToggle(title: L("Write"), selected: access.write) {
                writableChatIdsText = toggledIdText(writableChatIdsText, id: chat.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Manual IDs are a fallback for chats not returned by discovery. Use the chat GUID (e.g. iMessage;-;+15551234567) or a direct handle.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

                AgentChannelMultilineSettingsField(
                    title: L("Readable Chat IDs"),
                    text: $readableChatIdsText,
                    placeholder: L("iMessage;-;+15551234567 — one per line"),
                    help: L("Chats agents may read.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Authorized Senders"),
                    text: $senderAllowlistText,
                    placeholder: L("+15551234567 or name@example.com — one per line"),
                    help: L("Only messages from these handles trigger inbound handling; required for receive.")
                )
                StyledSettingsTextField(
                    label: L("Default Read Limit"),
                    text: $defaultReadLimit,
                    placeholder: "50",
                    help: L("Default recent-message count for iMessage reads. Clamped to 1-100.")
                )
                StyledSettingsTextField(
                    label: L("Poll Interval Seconds"),
                    text: $pollIntervalSeconds,
                    placeholder: "3",
                    help: L("How often Osaurus checks for new messages. Clamped to 1-60 seconds.")
                )
                SettingsToggle(
                    title: L("Ingest Attachments"),
                    description: L(
                        "Read inbound attachment metadata from the Messages attachment folder. Only files under the Messages attachment root are ever touched."
                    ),
                    isOn: $attachmentIngestionEnabled
                )
            }
        }
    }

    // MARK: - Behavior

    private var behaviorSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepDispatchSection
            SettingsDivider()
            sendingSection
            SettingsDivider()
            advancedActionsSection
        }
    }

    private var stepDispatchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Reply to incoming messages"))

            SettingsToggle(
                title: L("Reply with an Agent"),
                description: L(
                    "Choose which agent answers allowlisted iMessages. Replies run in a private channel session; external-surface tool restrictions still apply."
                ),
                isOn: $inboundDispatchEnabled.animation(.easeOut(duration: 0.2))
            )

            if inboundDispatchEnabled {
                AgentChannelDispatchRoutingEditor(
                    roomNoun: L("chat"),
                    rooms: routableRooms,
                    defaultAgentId: $inboundAgentId,
                    routes: $inboundRoutes
                )
                SettingsToggle(
                    title: L("Reply Automatically"),
                    description: L(
                        "Reply to the incoming iMessage with the selected agent's sanitized response. iMessage and global writes plus the write allowlist still apply."
                    ),
                    isOn: $inboundAutoReplyEnabled
                )
            }

            SettingsToggle(
                title: L("Ignore Messages You Send"),
                description: L(
                    "Skip messages sent from this Mac's own account. Turn this off to test the full loop from a single machine by messaging yourself — the sender must still be in the authorized list, and automatic replies can loop if the agent answers itself."
                ),
                isOn: $ignoreSelfMessages
            )
        }
    }

    private var sendingSection: some View {
        SettingsSubsection(label: L("Sending")) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: L("Allow Sending on iMessage"),
                    description: L(
                        "Let agents post to write-allowlisted chats through Messages.app. Requires Messages Automation; the global Sending switch in Channels must also be on."
                    ),
                    isOn: $writeEnabled.animation(.easeOut(duration: 0.2))
                )

                if writeEnabled {
                    AgentChannelMultilineSettingsField(
                        title: L("Writable Chat IDs"),
                        text: $writableChatIdsText,
                        placeholder: L("iMessage;-;+15551234567 — one per line"),
                        help: L("Chats agents may post to.")
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var advancedActionsSection: some View {
        SettingsSubsection(label: L("Advanced Actions (private API)")) {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(
                        "Editing, unsending, tapbacks, typing indicators, and attachment sends use Apple's private iMessage APIs. They only work after you disable System Integrity Protection and Library Validation on this Mac — a significant, system-wide security reduction. Osaurus never changes those protections; it only detects whether the bridge is active. Do this only on a dedicated machine.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(theme.warningColor)
                }

                securityDiagnosticsRows

                SettingsToggle(
                    title: L("Enable Advanced Actions"),
                    description: L(
                        "Master switch. Each action below must also be enabled individually, and every mutation still requires confirm_send."
                    ),
                    isOn: $advancedActionsEnabled.animation(.easeOut(duration: 0.2))
                )

                if advancedActionsEnabled {
                    ForEach(IMessageConnectionConfiguration.AdvancedAction.allCases, id: \.rawValue) { action in
                        SettingsToggle(
                            title: advancedActionTitle(action),
                            description: advancedActionDescription(action),
                            isOn: advancedActionBinding(action)
                        )
                    }
                    if diagnostics?.bridgeAvailable != true {
                        Text(
                            "The private-API bridge is not active on this Mac right now, so these actions will fail until it is. Basic send/receive keeps working either way.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Read-only SIP / Library Validation state. Detection only — there is
    /// deliberately no button here.
    private var securityDiagnosticsRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            securityRow(
                title: L("System Integrity Protection"),
                state: diagnostics?.sipEnabled,
                enabledLabel: L("Enabled (secure default)"),
                disabledLabel: L("Disabled")
            )
            securityRow(
                title: L("Library Validation"),
                state: diagnostics?.libraryValidationEnabled,
                enabledLabel: L("Enabled (secure default)"),
                disabledLabel: L("Disabled")
            )
            securityRow(
                title: L("Private-API bridge"),
                state: diagnostics.map { !$0.bridgeAvailable },
                enabledLabel: L("Not active"),
                disabledLabel: L("Active in Messages.app")
            )
        }
    }

    private func securityRow(
        title: String,
        state: Bool?,
        enabledLabel: String,
        disabledLabel: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
            Spacer(minLength: 6)
            Text(state == nil ? L("Unknown") : (state == true ? enabledLabel : disabledLabel))
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
        }
    }

    private func advancedActionBinding(
        _ action: IMessageConnectionConfiguration.AdvancedAction
    ) -> Binding<Bool> {
        Binding(
            get: { enabledAdvancedActions.contains(action) },
            set: { enabled in
                if enabled {
                    enabledAdvancedActions.insert(action)
                } else {
                    enabledAdvancedActions.remove(action)
                }
            }
        )
    }

    private func advancedActionTitle(_ action: IMessageConnectionConfiguration.AdvancedAction) -> String {
        switch action {
        case .reply: return L("Threaded Replies")
        case .edit: return L("Edit Messages")
        case .unsend: return L("Unsend Messages")
        case .tapback: return L("Tapback Reactions")
        case .typing: return L("Typing Indicators")
        case .sendAttachment: return L("Send Attachments")
        case .sendEffect: return L("Message Effects")
        case .poll: return L("Polls")
        case .groupManagement: return L("Group Management")
        }
    }

    private func advancedActionDescription(
        _ action: IMessageConnectionConfiguration.AdvancedAction
    ) -> String {
        switch action {
        case .reply: return L("Reply to a specific message in a chat.")
        case .edit: return L("Edit a recently sent message.")
        case .unsend: return L("Unsend a recently sent message.")
        case .tapback: return L("Add or remove a tapback on a message.")
        case .typing: return L("Show a typing indicator in a chat.")
        case .sendAttachment: return L("Send a file from an allowlisted attachment folder.")
        case .sendEffect: return L("Send a message with a screen or bubble effect.")
        case .poll: return L("Create polls and vote in group chats.")
        case .groupManagement: return L("Rename groups or change participants.")
        }
    }

    // MARK: - Verify

    private var stepVerifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Verify an incoming message"))

            Text(
                "Changes save automatically, and receiving starts once Connect and Conversations are complete. Send yourself an iMessage from an authorized sender in a readable chat, then watch each stage appear here.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelTransportHealthView(
                connectionId: IMessageConnectionService.nativeConnectionId,
                transportId: IMessageWatchTransportRuntime.transportId,
                title: L("iMessage receive"),
                notRunningHint: L(
                    "Receiving is not running. Verify the helper and Full Disk Access, turn on Receive Messages, then add readable chats and authorized senders to start it."
                ),
                refreshToken: healthRefreshToken
            )

            AgentChannelInboundActivityListView(
                connectionId: IMessageConnectionService.nativeConnectionId,
                emptyHint: L(
                    "No incoming iMessages yet this session. Send one from an authorized sender and press “Verify incoming message”."
                ),
                refreshToken: activityRefreshToken
            )

            AgentChannelSheetActionButton(
                title: L("Verify incoming message"),
                busyTitle: L("Waiting for an iMessage..."),
                isBusy: isVerifying,
                action: verifyIncomingMessage
            )
            .disabled(isVerifying || isSaving || isTesting)
        }
    }

    private var routableRooms: [AgentChannelRoutableRoom] {
        discoveredChats.map { AgentChannelRoutableRoom(id: $0.id, name: $0.name) }
    }

    // MARK: - Load / save

    private func loadConfiguration() {
        let configuration = IMessageConnectionConfigurationStore.load()
        readableChatIdsText = configuration.readableChatIds.joined(separator: "\n")
        writableChatIdsText = configuration.writableChatIds.joined(separator: "\n")
        senderAllowlistText = configuration.senderAllowlist.joined(separator: "\n")
        writeEnabled = configuration.writeEnabled
        defaultReadLimit = "\(configuration.defaultReadLimit)"
        receiveStorageEnabled = configuration.receiveStorageEnabled
        receivePollingEnabled = configuration.receivePollingEnabled
        pollIntervalSeconds = "\(configuration.pollIntervalSeconds)"
        attachmentIngestionEnabled = configuration.attachmentIngestionEnabled
        ignoreSelfMessages = configuration.ignoreSelfMessages
        advancedActionsEnabled = configuration.advancedActionsEnabled
        enabledAdvancedActions = Set(configuration.enabledAdvancedActions)
        inboundDispatchEnabled = configuration.inboundDispatch.enabled
        inboundAgentId = configuration.inboundDispatch.targetAgentId
        inboundRoutes = configuration.inboundDispatch.routes
        inboundAutoReplyEnabled = configuration.inboundDispatch.autoReplyEnabled
        // Arm autosave only after the stored configuration has hydrated the
        // draft, so hydration itself is never mistaken for an edit.
        lastSavedDraft = currentDraft
    }

    private func validationFailure() -> (message: String, section: AgentChannelProviderSetupSection)? {
        if inboundDispatchEnabled, inboundAgentId == nil, inboundRoutes.isEmpty {
            return (
                L("Choose an agent to reply, or add a rule for incoming iMessages."),
                .behavior
            )
        }
        if inboundDispatchEnabled, inboundAutoReplyEnabled {
            guard writeEnabled else {
                return (L("Enable iMessage sending before automatic channel replies."), .behavior)
            }
            let readable = Set(parseIds(readableChatIdsText))
            let writable = Set(parseIds(writableChatIdsText))
            guard readable.isSubset(of: writable) else {
                return (
                    L("Every readable iMessage chat must also be writable when automatic replies are enabled."),
                    .access
                )
            }
        }
        return nil
    }

    private func currentConfiguration() -> IMessageConnectionConfiguration {
        IMessageConnectionConfiguration(
            readableChatIds: parseIds(readableChatIdsText),
            writableChatIds: parseIds(writableChatIdsText),
            senderAllowlist: parseIds(senderAllowlistText),
            writeEnabled: writeEnabled,
            defaultReadLimit: Int(defaultReadLimit) ?? 50,
            ignoreSelfMessages: ignoreSelfMessages,
            receiveStorageEnabled: receiveStorageEnabled,
            receivePollingEnabled: receivePollingEnabled,
            pollIntervalSeconds: Int(pollIntervalSeconds) ?? 3,
            attachmentIngestionEnabled: attachmentIngestionEnabled,
            advancedActionsEnabled: advancedActionsEnabled,
            enabledAdvancedActions: Array(enabledAdvancedActions),
            inboundDispatch: AgentChannelInboundDispatchConfiguration(
                enabled: inboundDispatchEnabled,
                targetAgentId: inboundAgentId,
                routes: inboundRoutes,
                requireMention: false,
                continueThreads: true,
                autoReplyEnabled: inboundAutoReplyEnabled
            )
        )
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
        if let failure = validationFailure() {
            showStatus(failure.message, isError: true, section: failure.section)
            return false
        }
        do {
            try IMessageConnectionService.shared.saveConfiguration(currentConfiguration())
            lastSavedDraft = currentDraft
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func saveAndDismiss() {
        autosaveTask?.cancel()
        isSaving = true
        Task {
            guard saveConfiguration() else {
                isSaving = false
                return
            }
            await AgentChannelTransportSupervisor.shared.refreshIMessageRuntime()
            let latest = await IMessageConnectionService.shared.diagnostics()
            let report = AgentChannelLiveProofReadiness.imessage(latest)
            await MainActor.run {
                isSaving = false
                diagnostics = latest
                healthRefreshToken += 1

                if inboundDispatchEnabled {
                    if report.isReadyForLiveProof {
                        _ = ToastManager.shared.success(
                            L("iMessage settings saved — receive is ready")
                        )
                        clearStatus()
                        dismiss()
                    } else {
                        showStatus(
                            L("Saved, but iMessage receive is not ready yet"),
                            details: report.blockers + report.notes,
                            isError: true,
                            section: .verify
                        )
                    }
                    return
                }

                let presentation = AgentChannelStatusPresentation.diagnostics(status: latest.status)
                if latest.failures.isEmpty {
                    _ = ToastManager.shared.success(L("iMessage settings saved"))
                    clearStatus()
                    dismiss()
                } else {
                    _ = ToastManager.shared.warning(
                        presentation.label,
                        message: latest.failures.first,
                        timeout: 8
                    )
                    showDiagnostics(latest, presentation: presentation)
                }
            }
        }
    }

    private func testConnection() {
        autosaveTask?.cancel()
        isTesting = true
        Task {
            guard saveConfiguration() else {
                isTesting = false
                return
            }
            await AgentChannelTransportSupervisor.shared.refreshIMessageRuntime()
            let latest = await IMessageConnectionService.shared.diagnostics()
            await MainActor.run {
                isTesting = false
                diagnostics = latest
                healthRefreshToken += 1
                showDiagnostics(latest)
            }
        }
    }

    private func refreshDiagnostics() {
        Task {
            let latest = await IMessageConnectionService.shared.diagnostics()
            await MainActor.run { diagnostics = latest }
        }
    }

    private func refreshChatDiscovery() {
        isDiscovering = true
        Task {
            do {
                let rows = try await IMessageConnectionService.shared.listChats()
                await MainActor.run {
                    discoveredChats = rows.compactMap { row in
                        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                        let raw = row["raw"] as? [String: Any]
                        return DiscoveredChat(
                            id: id,
                            name: (row["name"] as? String) ?? id,
                            kind: (row["kind"] as? String) ?? "chat",
                            participants: (raw?["participants"] as? [String]) ?? []
                        )
                    }
                    isDiscovering = false
                    if discoveredChats.isEmpty {
                        showStatus(
                            L("No chats came back. Verify the helper is downloaded and Full Disk Access is granted."),
                            isError: true
                        )
                    } else {
                        showStatus(L("Loaded recent Messages chats."), isError: false)
                    }
                }
            } catch {
                await MainActor.run {
                    isDiscovering = false
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func refreshReceiveRuntime() {
        Task {
            await AgentChannelTransportSupervisor.shared.refreshIMessageRuntime()
            await MainActor.run { healthRefreshToken += 1 }
        }
    }

    private func verifyIncomingMessage() {
        isVerifying = true
        showStatus(
            L("Waiting for an iMessage. Send one now from an authorized sender in a readable chat."),
            isError: false
        )
        let start = Date()
        let autoReply = inboundAutoReplyEnabled
        Task {
            let outcome = await AgentChannelInboundVerifier.waitForTerminalEvent(
                connectionId: IMessageConnectionService.nativeConnectionId,
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
                        L("No iMessage arrived within 90 seconds."),
                        details: [
                            L("Confirm the message came from an authorized sender in a readable chat."),
                            L("Confirm Receive Messages is on and Full Disk Access is granted."),
                            L("Confirm Messages.app is signed in on this Mac."),
                        ],
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

    private func showDiagnostics(
        _ diagnostics: IMessageConnectionDiagnostics,
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

    // MARK: - Status helpers

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
            withAnimation(.easeOut(duration: 0.15)) {
                selectedSectionId = section.rawValue
            }
        } else if !isError {
            attentionSectionId = nil
        }
    }

    private func clearStatus() {
        statusMessage = nil
        statusDetails = []
    }

    private func parseIds(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n\t")
        return IMessageConnectionConfiguration.normalizedIds(
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
