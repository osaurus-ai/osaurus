//
//  EmailSettingsView.swift
//  osaurus
//
//  Configuration sheet for one Email channel account.
//
//  Email has no bot account: each Email connection reads one mail account
//  the user already has — an account in the Mail app, or an IMAP server
//  with an optional SMTP server for replies. Each watched mailbox is a
//  room, each mail thread a thread, and only the account's allowlisted
//  senders reach an agent.
//

import SwiftUI

struct EmailSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Set when this sheet is hosted inside the unified Add Channel picker;
    /// shows a back chevron that returns to the catalog.
    var onBack: (() -> Void)? = nil
    /// The Email connection: `email`, or `email-<mail account>` for another
    /// one. Empty for a new account until its mail account is chosen.
    @State private var connectionId: String

    init(
        onBack: (() -> Void)? = nil, connectionId: String = AgentChannelConnection.nativeEmailConnectionId,
        newAccount: Bool = false
    ) {
        self.onBack = onBack
        _connectionId = State(initialValue: newAccount ? "" : connectionId)
    }

    private var isPendingAccount: Bool { connectionId.isEmpty }

    /// The account being edited; an empty `connectionId` until a mail
    /// account is chosen.
    @State private var draft = EmailChannelAccount(connectionId: "")
    @State private var senderAllowlistText = ""

    @State private var accountSheet: EmailAccountSheet.Mode?
    @State private var mailboxOptions: [String: [String]] = [:]
    @State private var mailboxErrors: [String: String] = [:]
    @State private var loadingMailboxesFor: String?

    @State private var statusMessage: String?
    @State private var statusDetails: [String] = []
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isVerifying = false
    @State private var isChecking = false
    @State private var healthRefreshToken = 0
    @State private var activityRefreshToken = 0
    @State private var diagnostics: EmailChannelDiagnostics?
    @State private var selectedSectionId: String = AgentChannelProviderSetupSection.connect.rawValue
    @State private var attentionSectionId: String?
    @State private var verifySucceeded = false
    @State private var lastSaved: EmailChannelAccount?
    @State private var autosaveTask: Task<Void, Never>?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var mailAccounts: [SourceConnection] {
        SourceConnectionStore.shared.connections(of: [.mailApp, .imap])
    }

    private var channelEvents: [OsaurusEvent] {
        EventManager.shared.events(kind: .email, connectionId: connectionId).filter(\.isEnabled)
    }
    private var inboundDispatchEnabled: Bool { !channelEvents.isEmpty }
    private var inboundAutoReplyEnabled: Bool {
        channelEvents.contains { $0.reply.replies(for: $0.action.kind) }
    }

    private var currentAccount: EmailChannelAccount {
        var account = draft
        account.channelConnectionId = connectionId
        account.senderAllowlist = senders
        return account
    }

    private var hasMailAccount: Bool { !draft.connectionId.isEmpty }

    /// Mail accounts another Email connection already reads.
    private var mailAccountsInUse: [String: String] {
        var used: [String: String] = [:]
        for account in EmailChannelService.shared.configuration().accounts
        where account.channelConnectionId != connectionId {
            used[account.connectionId] =
                ChannelAccounts.displayName(connectionId: account.channelConnectionId) ?? account.channelConnectionId
        }
        return used
    }

    var body: some View {
        AgentChannelSetupScaffold(
            icon: AgentChannelKind.email.icon,
            gradient: AgentChannelKind.email.brandGradient,
            title: isPendingAccount
                ? ChannelAccounts.newTitle(.email)
                : ChannelAccounts.displayName(connectionId: connectionId) ?? AgentChannelKind.email.displayName,
            subtitle: L("Read mail from allowlisted senders and reply in the thread"),
            sections: AgentChannelProviderSetupSection.sections,
            selection: $selectedSectionId,
            sectionStatus: sectionStatus(for:),
            onBack: onBack,
            pendingAccount: isPendingAccount
                ? AgentChannelPendingAccount(
                    actionTitle: L("Add Account"), isWorking: false, canConnect: hasMailAccount,
                    connect: connectNewAccount)
                : nil
        ) { sectionId in
            VStack(alignment: .leading, spacing: theme.space.s20) {
                switch AgentChannelProviderSetupSection(rawValue: sectionId) {
                case .connect:
                    connectSectionContent
                case .receiving:
                    receivingSectionContent
                case .routing:
                    ChannelRoutingSection(kind: .email, connectionId: connectionId)
                case .sending:
                    sendingSectionContent
                case .verify, nil:
                    verifySection
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
            guard !isPendingAccount else { return }
            loadConfiguration()
            selectedSectionId = AgentChannelSetupFlow.initialSection(
                in: AgentChannelProviderSetupSection.sections,
                required: AgentChannelProviderSetupSection.requiredSectionIds,
                isComplete: { sectionCompleted($0) },
                fallback: AgentChannelProviderSetupSection.verify.rawValue
            )
            refreshDiagnostics()
        }
        .onChange(of: currentAccount) { _, _ in
            scheduleAutosave()
        }
        .onDisappear {
            autosaveTask?.cancel()
            autosaveNow()
        }
        .sheet(item: $accountSheet) { mode in
            EmailAccountSheet(mode: mode) { saved in
                if !hasMailAccount, mailAccountsInUse[saved.id] == nil { draft.connectionId = saved.id }
                accountSheet = nil
                refreshDiagnostics()
            } onDeleted: {
                accountSheet = nil
                refreshDiagnostics()
            } onClose: {
                accountSheet = nil
            }
        }
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard lastSaved != nil, currentAccount != lastSaved else { return }
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            autosaveNow()
        }
    }

    private func autosaveNow() {
        guard lastSaved != nil, currentAccount != lastSaved else { return }
        // A removed account stays removed.
        guard ChannelAccounts.account(connectionId: connectionId) != nil else { return }
        guard validationFailure() == nil else { return }
        let account = currentAccount
        guard (try? EmailChannelService.shared.saveConfiguration(savedConfiguration(account))) != nil else { return }
        lastSaved = account
        refreshReceiveRuntime()
    }

    // MARK: - Section state

    private var senders: [String] {
        EmailChannelConfiguration.normalizedSenders(
            senderAllowlistText.components(separatedBy: CharacterSet(charactersIn: ",\n\t ")))
    }

    private func sectionCompleted(_ sectionId: String) -> Bool {
        switch AgentChannelProviderSetupSection(rawValue: sectionId) {
        case .connect:
            return hasMailAccount && draft.receiveEnabled
        case .receiving:
            return !senders.isEmpty
        case .routing:
            return inboundDispatchEnabled
        case .sending:
            return draft.writeEnabled
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
        VStack(alignment: .leading, spacing: theme.space.s20) {
            Text(
                "Email reads mail from accounts you already have: an account in the Mail app (no password needed), or an IMAP server with an app password kept in the Keychain. Each watched mailbox becomes a room and each mail thread a conversation.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            SettingsFieldRow(
                label: "Name",
                hint: L("Shown in Channels, routing rules and history."),
                anchorId: "agentChannels.accountName",
                verbatimHint: true
            ) {
                SettingsTextField(placeholder: L("e.g. Work mail"), text: $draft.name)
            }
            accountsSection
            if !isPendingAccount {
                receiveToggleSection
                ChannelAccountRemoveSection(connectionId: connectionId, kind: .email) { dismiss() }
            }
        }
    }

    /// Keeps the chosen mail account as its own Email connection and opens
    /// the rest of its setup.
    private func connectNewAccount() {
        clearStatus()
        let mailAccount = mailAccounts.first { $0.id == draft.connectionId }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let id = try ChannelAccountCreation.addEmail(
                name: name.isEmpty ? (mailAccount?.displayName ?? "") : name, mailAccountId: draft.connectionId)
            connectionId = id
            loadConfiguration()
            withAnimation(theme.motion.quick) {
                selectedSectionId = AgentChannelProviderSetupSection.receiving.rawValue
            }
            refreshReceiveRuntime()
            refreshDiagnostics()
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            AgentChannelSectionHeading(L("Choose the mail account"))

            if mailAccounts.isEmpty {
                Text("No mail account yet. Add one to start.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            } else {
                VStack(spacing: theme.space.s0) {
                    ForEach(mailAccounts) { account in
                        accountRow(account)
                    }
                }
                .settingsChrome(.inset)
            }

            ForEach(missingAccountIds, id: \.self) { id in
                HStack(alignment: .top, spacing: theme.space.s8) {
                    SettingsFindingRow(
                        severity: .warning,
                        title: L("A watched account was removed"),
                        detail: L("Mail for \(id) is no longer checked.")
                    )
                    SettingsButton(.secondary, "Remove", size: .compact) {
                        draft.connectionId = ""
                    }
                }
            }

            SettingsButton(.secondary, "Add Account…", icon: "plus", size: .compact) {
                accountSheet = .add
            }
        }
    }

    private var missingAccountIds: [String] {
        let known = Set(mailAccounts.map(\.id))
        return hasMailAccount && !known.contains(draft.connectionId) ? [draft.connectionId] : []
    }

    private func accountRow(_ account: SourceConnection) -> some View {
        let watched = draft.connectionId == account.id
        let usedBy = mailAccountsInUse[account.id]
        return HStack(spacing: theme.space.s8) {
            Image(systemName: account.type == .mailApp ? "envelope.fill" : "server.rack")
                .glyphSize(.footnote, weight: .semibold)
                .foregroundColor(theme.text.secondary)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: account.displayName)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Text(verbatim: usedBy.map { L("Used by \($0)") } ?? account.config.summary)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            SettingsButton(.secondary, "Edit…", size: .compact) { accountSheet = .edit(account) }
            AgentChannelSelectorToggle(title: L("Watch"), selected: watched) {
                if watched {
                    draft.connectionId = ""
                } else {
                    draft.connectionId = account.id
                    draft.mailboxes = []
                    if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        draft.name = account.displayName
                    }
                }
            }
            .disabled(usedBy != nil)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    private var receiveToggleSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            AgentChannelSectionHeading(L("Turn on receiving"))

            SettingsToggle(
                title: "Receive Mail",
                description: L(
                    "Check the watched mailboxes while the app runs and store mail from allowed senders in the local inbox."
                ),
                isOn: $draft.receiveEnabled.animation(theme.motion.quick)
            )

            if !draft.receiveEnabled {
                Text("Receiving is off: no mailbox is checked and no agent can reply.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Mailboxes and senders

    private var receivingSectionContent: some View {
        VStack(alignment: .leading, spacing: theme.space.s20) {
            sendersSection
            if hasMailAccount {
                mailboxSection($draft)
            }
            AgentChannelAdvancedSection {
                SettingsStepperRow(
                    label: "Default Read Limit",
                    help: L("Messages an agent reads from a mailbox when it does not ask for a number."),
                    value: $draft.defaultReadLimit,
                    range: 1...100
                )
            }
        }
    }

    private var sendersSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            AgentChannelSectionHeading(L("Choose who can reach agents"))
            AgentChannelMultilineSettingsField(
                title: L("Allowed Senders"),
                text: $senderAllowlistText,
                placeholder: L("alex@example.com or @example.com — one per line"),
                help: L(
                    "Only mail from these addresses, or from anyone at an @domain, reaches an agent. Everything else stays in your mailbox untouched. Automated senders such as no-reply addresses are always skipped."
                )
            )
            if senders.isEmpty, hasMailAccount {
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.status.warning.foreground)
                    Text("Receiving stays off until you add at least one allowed sender.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.status.warning.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func mailboxSection(_ account: Binding<EmailChannelAccount>) -> some View {
        let id = account.wrappedValue.connectionId
        let connection = mailAccounts.first { $0.id == id }
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            AgentChannelSectionHeading(connection?.displayName ?? id)

            mailboxField(account)

            SettingsToggle(
                title: "Only Unread Mail",
                description: L("Skip mail already read in your mail app."),
                isOn: account.unreadOnly
            )
            SettingsToggle(
                title: "Include the Message Text",
                description: L("Off, agents see only the sender, subject and a short preview."),
                isOn: account.includeBody
            )
            if account.wrappedValue.includeBody {
                SettingsStepperRow(
                    label: "Message Length Limit",
                    help: L("Characters of each message passed to the agent."),
                    value: account.maxBodyChars,
                    range: EmailChannelAccount.maxBodyCharsRange,
                    step: 500
                )
            }
            SettingsStepperRow(
                label: "Check Every",
                help: L("How often Osaurus looks for new mail."),
                value: Binding(
                    get: { account.wrappedValue.pollIntervalSeconds / 60 },
                    set: { account.wrappedValue.pollIntervalSeconds = $0 * 60 }
                ),
                range: 1...60,
                unit: "min"
            )
            SettingsRow(
                title: "Mail That Arrived While Osaurus Was Closed",
                description: L("What the first check after a relaunch does with mail it missed.")
            ) {
                Picker(selection: account.catchUp) {
                    ForEach(SourceCatchUpPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: {
                    EmptyView()
                }
                .assignedPickerPopupPresentation()
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func mailboxField(_ account: Binding<EmailChannelAccount>) -> some View {
        let id = account.wrappedValue.connectionId
        let text = Binding(
            get: { account.wrappedValue.mailboxes.joined(separator: ", ") },
            set: { account.wrappedValue.mailboxes = EventSourceDrafts.list($0) }
        )
        return EventEditorLabeled(L("Mailboxes (comma separated; empty = Inbox)")) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                HStack(spacing: theme.space.s8) {
                    SettingsTextField(placeholder: L("Inbox"), text: text, icon: "tray")
                    SettingsButton(
                        .secondary, "Choose…", icon: "list.bullet", isLoading: loadingMailboxesFor == id,
                        size: .compact
                    ) {
                        Task { await loadMailboxes(connectionId: id) }
                    }
                }
                if let error = mailboxErrors[id] {
                    Text(verbatim: error)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.status.warning.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let options = mailboxOptions[id], !options.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: theme.space.s4) {
                            ForEach(options, id: \.self) { name in
                                Toggle(isOn: membership(name, in: account)) {
                                    Text(verbatim: EmailMailboxName.display(name))
                                        .font(SettingsFont.rowDescription)
                                }
                                .settingsCheckbox()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.space.s8)
                    }
                    .frame(maxHeight: 160)
                    .settingsChrome(.inset)
                }
            }
        }
    }

    private func membership(_ name: String, in account: Binding<EmailChannelAccount>) -> Binding<Bool> {
        let isInbox = name.uppercased() == EmailSourceConfig.inbox
        return Binding(
            get: {
                account.wrappedValue.mailboxes.contains(name) || (account.wrappedValue.mailboxes.isEmpty && isInbox)
            },
            set: { on in
                var current = account.wrappedValue.effectiveMailboxes
                current.removeAll { $0 == name || (isInbox && $0.uppercased() == EmailSourceConfig.inbox) }
                if on { current.append(name) }
                account.wrappedValue.mailboxes = current
            })
    }

    private func loadMailboxes(connectionId id: String) async {
        guard let connection = mailAccounts.first(where: { $0.id == id }),
            let fetcher = MailboxFetcherFactory.fetcher(for: connection)
        else { return }
        loadingMailboxesFor = id
        defer { loadingMailboxesFor = nil }
        do {
            let options = try await fetcher.mailboxes()
            mailboxOptions[id] = options
            mailboxErrors[id] = options.isEmpty ? L("The account has no mailboxes.") : nil
        } catch {
            mailboxErrors[id] = error.localizedDescription
        }
    }

    // MARK: - Sending

    private var sendingSectionContent: some View {
        VStack(alignment: .leading, spacing: theme.space.s20) {
            SettingsFieldRow(label: "Sending") {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    SettingsToggle(
                        title: "Allow Sending Email",
                        description: L(
                            "Let agents reply in the thread of mail they received, from the account it arrived on. Mail app accounts send through Mail; IMAP accounts need a reply server. The global Sending switch in Channels must also be on."
                        ),
                        isOn: $draft.writeEnabled.animation(theme.motion.quick)
                    )
                    SettingsToggle(
                        title: "Open Unsent Replies as Drafts",
                        description: L(
                            "When a reply is not sent automatically, put it in Mail as a draft to review. Mail app accounts only."
                        ),
                        isOn: $draft.draftUnsentReplies
                    )
                    ForEach(accountsWithoutSending, id: \.self) { name in
                        SettingsFindingRow(
                            severity: .warning,
                            title: L("\(name) cannot send replies"),
                            detail: L("Add a reply server (SMTP) and From address to this account, or replies from it fail.")
                        )
                    }
                    Text(
                        "Agents can only reply to mail they received; they cannot start new email. Replies over SMTP use TLS on port 465 and are not copied to the Sent mailbox.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var accountsWithoutSending: [String] {
        guard let connection = mailAccounts.first(where: { $0.id == draft.connectionId }),
            !EmailChannelService.canSend(connection)
        else { return [] }
        return [connection.displayName]
    }

    // MARK: - Verify

    private var verifySection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            AgentChannelSectionHeading(L("Verify an incoming message"))

            Text(
                "Changes save automatically, and receiving starts once an account, Receive Mail and an allowed sender are set. Send mail from an allowed sender to a watched mailbox, press Check Now, then watch each stage appear here.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            if currentAccount.roomIds.isEmpty {
                Text("Watch a mail account to see its mailbox checks here.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            ForEach(currentAccount.roomIds, id: \.self) { roomId in
                AgentChannelTransportHealthView(
                    connectionId: connectionId,
                    transportId: EmailChannelTransportRuntime.transportId(roomId: roomId),
                    title: roomTitle(roomId),
                    notRunningHint: L(
                        "This mailbox is not being checked. Turn on Receive Mail and add an allowed sender to start."
                    ),
                    refreshToken: healthRefreshToken
                )
            }

            AgentChannelInboundActivityListView(
                connectionId: connectionId,
                emptyHint: L(
                    "No incoming mail yet this session. Send one from an allowed sender and press “Verify incoming message”."
                ),
                refreshToken: activityRefreshToken
            )

            HStack(spacing: theme.space.s8) {
                AgentChannelSheetActionButton(
                    title: L("Check Now"),
                    busyTitle: L("Checking..."),
                    isBusy: isChecking,
                    action: checkNow
                )
                .disabled(isChecking || !currentAccount.canStartReceive())
                AgentChannelSheetActionButton(
                    title: L("Verify incoming message"),
                    busyTitle: L("Waiting for mail..."),
                    isBusy: isVerifying,
                    action: verifyIncomingMessage
                )
                .disabled(isVerifying || isSaving || isTesting)
            }
        }
    }

    private func roomTitle(_ roomId: String) -> String {
        guard let route = EmailChannelConfiguration.parseRoomId(roomId) else { return roomId }
        return EmailChannelService.roomName(
            connection: mailAccounts.first { $0.id == route.connectionId }, mailbox: route.mailbox)
    }

    // MARK: - Load / save

    private func loadConfiguration() {
        let configuration = EmailChannelService.shared.configuration()
        draft =
            configuration.account(channelConnectionId: connectionId)
            ?? EmailChannelAccount(connectionId: "", channelConnectionId: connectionId)
        senderAllowlistText = draft.senderAllowlist.joined(separator: "\n")
        // Arm autosave only after the stored configuration has hydrated the
        // draft, so hydration itself is never mistaken for an edit.
        lastSaved = currentAccount
    }

    /// `email.json` with this connection's account replaced, in place.
    private func savedConfiguration(_ account: EmailChannelAccount) -> EmailChannelConfiguration {
        var configuration = EmailChannelService.shared.configuration()
        let index = configuration.accounts.firstIndex { $0.channelConnectionId == connectionId }
        configuration.accounts.removeAll { $0.channelConnectionId == connectionId }
        guard !account.connectionId.isEmpty else { return configuration }
        configuration.accounts.insert(account, at: min(index ?? configuration.accounts.count, configuration.accounts.count))
        return configuration
    }

    private func validationFailure() -> (message: String, section: AgentChannelProviderSetupSection)? {
        if inboundDispatchEnabled, inboundAutoReplyEnabled, !draft.writeEnabled {
            return (L("Allow sending email before automatic channel replies."), .sending)
        }
        return nil
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
        if let failure = validationFailure() {
            showStatus(failure.message, isError: true, section: failure.section)
            return false
        }
        do {
            let account = currentAccount
            try EmailChannelService.shared.saveConfiguration(savedConfiguration(account))
            lastSaved = account
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
            await AgentChannelTransportSupervisor.shared.refreshEmailRuntime()
            let latest = await EmailChannelService.shared.diagnostics(channelConnectionId: connectionId)
            let report = AgentChannelLiveProofReadiness.email(latest)
            isSaving = false
            diagnostics = latest
            healthRefreshToken += 1

            if inboundDispatchEnabled {
                if report.isReadyForLiveProof {
                    _ = ToastManager.shared.success(L("Email settings saved — receive is ready"))
                    clearStatus()
                    dismiss()
                } else {
                    showStatus(
                        L("Saved, but Email receive is not ready yet"),
                        details: report.blockers + report.notes,
                        isError: true,
                        section: .verify
                    )
                }
                return
            }

            if latest.failures.isEmpty {
                _ = ToastManager.shared.success(L("Email settings saved"))
                clearStatus()
                dismiss()
            } else {
                showDiagnostics(latest)
            }
        }
    }

    /// Saves, then signs in to every watched account so a wrong password or
    /// a Mail permission prompt shows up here rather than on the first check.
    private func testConnection() {
        autosaveTask?.cancel()
        isTesting = true
        Task {
            guard saveConfiguration() else {
                isTesting = false
                return
            }
            await AgentChannelTransportSupervisor.shared.refreshEmailRuntime()
            var problems: [String] = []
            for account in [draft] where hasMailAccount {
                guard let connection = mailAccounts.first(where: { $0.id == account.connectionId }),
                    let fetcher = MailboxFetcherFactory.fetcher(for: connection)
                else { continue }
                do {
                    _ = try await fetcher.mailboxes()
                } catch {
                    problems.append("\(connection.displayName): \(error.localizedDescription)")
                }
            }
            let latest = await EmailChannelService.shared.diagnostics(channelConnectionId: connectionId)
            isTesting = false
            diagnostics = latest
            healthRefreshToken += 1
            showDiagnostics(latest, extraFailures: problems)
        }
    }

    private func refreshDiagnostics() {
        Task {
            diagnostics = await EmailChannelService.shared.diagnostics(channelConnectionId: connectionId)
        }
    }

    private func refreshReceiveRuntime() {
        Task {
            await AgentChannelTransportSupervisor.shared.refreshEmailRuntime()
            healthRefreshToken += 1
        }
    }

    private func checkNow() {
        isChecking = true
        Task {
            await EmailChannelTransportRuntime.shared.checkNow()
            isChecking = false
            healthRefreshToken += 1
            activityRefreshToken += 1
        }
    }

    private func verifyIncomingMessage() {
        isVerifying = true
        showStatus(
            L("Waiting for mail. Send one now from an allowed sender to a watched mailbox."),
            isError: false
        )
        let start = Date()
        let autoReply = inboundAutoReplyEnabled
        Task {
            await EmailChannelTransportRuntime.shared.checkNow()
            let outcome = await AgentChannelInboundVerifier.waitForTerminalEvent(
                connectionId: connectionId,
                since: start,
                autoReplyEnabled: autoReply,
                onActivity: {
                    activityRefreshToken += 1
                    healthRefreshToken += 1
                }
            )
            isVerifying = false
            activityRefreshToken += 1
            if let event = outcome.event {
                presentVerifyOutcome(event, timedOutWaitingForMore: outcome.timedOutWaitingForMore)
            } else {
                showStatus(
                    L("No mail arrived within 90 seconds."),
                    details: [
                        L("Confirm the mail came from an allowed sender and landed in a watched mailbox."),
                        L("Mail is checked on the interval you set; press Check Now to look right away."),
                        L("Confirm the mailbox check above shows as running."),
                    ],
                    isError: true
                )
            }
        }
    }

    private func presentVerifyOutcome(
        _ event: AgentChannelInboundActivityEvent,
        timedOutWaitingForMore: Bool = false
    ) {
        let label = AgentChannelInboundActivityPresentation.label(for: event.stage)
        var details: [String] = []
        if let guidance = AgentChannelInboundActivityPresentation.guidance(stage: event.stage, reason: event.reason) {
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

    private func showDiagnostics(_ diagnostics: EmailChannelDiagnostics, extraFailures: [String] = []) {
        let presentation = AgentChannelStatusPresentation.diagnostics(status: diagnostics.status)
        let failures = extraFailures + diagnostics.failures
        showStatus(
            failures.isEmpty ? presentation.label : L("Some accounts need attention"),
            details: failures + diagnostics.notes,
            isError: !failures.isEmpty || presentation.tone == .error
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
            withAnimation(theme.motion.quick) {
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
}
