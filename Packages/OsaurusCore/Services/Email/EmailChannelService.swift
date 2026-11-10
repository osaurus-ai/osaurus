//
//  EmailChannelService.swift
//  osaurus
//
//  The native Email channel. Mail checked by `EmailChannelTransportRuntime`
//  comes in here one message at a time: it is authorized (watched mailbox,
//  allowlisted sender, never seen before), stored, and handed to the
//  channel's automations with a reply that goes back into the same mail
//  thread. Mail app accounts reply through Mail; IMAP accounts through
//  their SMTP server. Every send is gated by Allow Sending and the global
//  channel write switch.
//
//  Routing: the space is the account (`SourceConnection.id`), a room is a
//  watched mailbox (`<account id>/<mailbox>`), a thread is the mail thread
//  (first `References` id, else the message's own id).
//

import Foundation

struct EmailChannelDiagnostics: Equatable, Sendable {
    let accountCount: Int
    let readableRoomIds: [String]
    let senderAllowlist: [String]
    let receiveEnabled: Bool
    let writeEnabled: Bool
    let usesMailApp: Bool
    /// nil when no watched account is a Mail app account.
    let mailRunning: Bool?
    let automationDenied: Bool
    /// Display names of watched IMAP accounts with no SMTP server.
    let accountsWithoutSending: [String]
    let status: String
    let failures: [String]
    let notes: [String]

    var receiveReady: Bool {
        receiveEnabled && accountCount > 0 && !readableRoomIds.isEmpty && !senderAllowlist.isEmpty
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "account_count": accountCount,
            "receive_ready": receiveReady,
            "readable_room_ids": readableRoomIds,
            "sender_allowlist": senderAllowlist,
            "receive_enabled": receiveEnabled,
            "write_enabled": writeEnabled,
            "uses_mail_app": usesMailApp,
            "automation_denied": automationDenied,
            "accounts_without_sending": accountsWithoutSending,
            "authorization": [
                "sender_allowlist": senderAllowlist,
                "room_allowlist": readableRoomIds,
                "authorize_before_storage": true,
                "authorize_before_dispatch": true,
            ],
            "status": status,
            "failures": failures,
        ]
        if let mailRunning { result["mail_running"] = mailRunning }
        if !notes.isEmpty { result["notes"] = notes }
        return result
    }
}

enum EmailChannelServiceError: LocalizedError, Equatable, Sendable {
    case accountMissing(String)
    case invalidRoomId(String)
    case roomNotReadable(String)
    case roomNotWritable(String)
    case writeDisabled
    case globalWritesDisabled
    case sendConfirmationRequired
    case emptyMessage
    case messageTooLong
    case messageStoreUnavailable
    case threadNotFound(String)
    case accountCannotSend(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .accountMissing(let id):
            return "Mail account `\(id)` is not set up. Add it in Email settings."
        case .invalidRoomId(let roomId):
            return "`\(roomId)` is not an Email room id. Rooms are `<account id>/<mailbox>` (see list_rooms)."
        case .roomNotReadable(let roomId):
            return "Mailbox `\(roomId)` is not watched by the Email channel."
        case .roomNotWritable(let roomId):
            return "Replies from mailbox `\(roomId)` are not allowed."
        case .writeDisabled:
            return "Email sending is off. Turn on Allow Sending in Email settings."
        case .globalWritesDisabled:
            return "Sending is paused: Allow Agents to Send Messages is off in Channels."
        case .sendConfirmationRequired:
            return "`confirm_send` must be true before Osaurus sends an email."
        case .emptyMessage:
            return "Email reply content must not be empty."
        case .messageTooLong:
            return "Email reply content is too long."
        case .messageStoreUnavailable:
            return "Email message store is unavailable."
        case .threadNotFound(let threadId):
            return "No received email in thread `\(threadId)`. Use a `thread_id` from read_messages."
        case .accountCannotSend(let name):
            return "\(name) has no SMTP server for replies. Edit the account in Email settings."
        case .unsupported(let action):
            return "Email does not support `\(action)`: agents can only reply to mail they received."
        }
    }
}

final class EmailChannelService: @unchecked Sendable {
    static let nativeConnectionId = AgentChannelConnection.nativeEmailConnectionId
    static let maxReplyLength = 100_000

    static let shared = EmailChannelService(messageStore: AgentChannelMessageStore.shared)

    private let messageStore: AgentChannelMessageStore?
    private let activityCenter: AgentChannelInboundActivityCenter
    private let writeKillSwitch: ChannelWriteKillSwitch

    /// Tests swap these.
    var connectionLookup: @Sendable (String) async -> SourceConnection? = { id in
        await MainActor.run { SourceConnectionStore.shared.connection(id: id) }
    }
    var mailService: any MailServicing = AppleScriptMailService()
    var isMailRunning: @Sendable () -> Bool = {
        AppleScriptBridge.isRunning(bundleIdentifier: AppleScriptMailService.bundleIdentifier)
    }
    var password: @Sendable (String) -> String? = {
        SourceCredentialVault.read(connectionId: $0, field: SourceCredentialVault.passwordField)
    }
    var makeSMTPTransport: (@Sendable (SMTPClient.Config) -> any IMAPTransport)?
    var deliverToEvents: @Sendable (ChannelInboundMessage) async -> AgentChannelInboundRelaySubmission = {
        await EventManager.shared.ingestChannelMessage($0)
    }

    init(
        messageStore: AgentChannelMessageStore? = nil,
        activityCenter: AgentChannelInboundActivityCenter = .shared,
        writeKillSwitch: ChannelWriteKillSwitch = .shared
    ) {
        self.messageStore = messageStore
        self.activityCenter = activityCenter
        self.writeKillSwitch = writeKillSwitch
    }

    // MARK: - Configuration

    func configuration() -> EmailChannelConfiguration {
        EmailChannelConfigurationStore.load()
    }

    func saveConfiguration(_ configuration: EmailChannelConfiguration) throws {
        try EmailChannelConfigurationStore.save(configuration)
    }

    /// The accounts a call covers: the one that is `channelConnectionId`,
    /// or every account when nil.
    static func accounts(_ channelConnectionId: String?, in config: EmailChannelConfiguration)
        -> [EmailChannelAccount]
    {
        guard let channelConnectionId else { return config.accounts }
        return config.account(channelConnectionId: channelConnectionId).map { [$0] } ?? []
    }

    // MARK: - Diagnostics

    func diagnostics(channelConnectionId: String? = nil) async -> EmailChannelDiagnostics {
        let accounts = Self.accounts(channelConnectionId, in: configuration())
        let receiveEnabled = accounts.contains(where: \.receiveEnabled)
        let writeEnabled = accounts.contains(where: \.writeEnabled)
        let senderAllowlist = EmailChannelConfiguration.normalizedSenders(accounts.flatMap(\.senderAllowlist))
        var failures: [String] = []
        var notes: [String] = []
        var usesMailApp = false
        var withoutSending: [String] = []
        for account in accounts {
            guard let connection = await connectionLookup(account.connectionId) else {
                failures.append("A watched mail account was removed (\(account.connectionId)). Remove it in Email settings.")
                continue
            }
            switch connection.config {
            case .mailApp:
                usesMailApp = true
            case .imap(let imap):
                if !imap.canSend { withoutSending.append(connection.displayName) }
                if let problem = imap.securityProblem { failures.append("\(connection.displayName): \(problem)") }
            case .apiToken:
                failures.append("\(connection.displayName) is not a mail account.")
            }
        }
        if accounts.isEmpty {
            failures.append("Add at least one mail account to watch.")
        }
        for account in accounts where account.receiveEnabled && account.senderAllowlist.isEmpty {
            failures.append("Add at least one allowed sender address or @domain for receive.")
            break
        }
        let mailRunning = usesMailApp ? isMailRunning() : nil
        notes.append(
            "Replies from IMAP accounts are sent over SMTP with TLS on port 465 (no STARTTLS) and are not copied to the account's Sent mailbox."
        )

        let status: String
        if accounts.isEmpty {
            status = "not_configured"
        } else if writeEnabled {
            status = "connected_read_write"
        } else {
            status = "connected_read_only"
        }
        return EmailChannelDiagnostics(
            accountCount: accounts.count,
            readableRoomIds: accounts.flatMap(\.roomIds),
            senderAllowlist: senderAllowlist,
            receiveEnabled: receiveEnabled,
            writeEnabled: writeEnabled,
            usesMailApp: usesMailApp,
            mailRunning: mailRunning,
            automationDenied: EmailChannelTransportRuntime.lastAutomationDenied,
            accountsWithoutSending: withoutSending,
            status: status,
            failures: failures,
            notes: notes)
    }

    func messageStoreDiagnostics() -> [String: Any] {
        [
            "enabled": messageStore != nil,
            "open": messageStore?.isOpen ?? false,
            "database_path": OsaurusPaths.agentChannelMessagesDatabaseFile().path,
            "message_dedupe": "connection_id + room_id + provider_message_id (Message-ID)",
            "event_dedupe": "connection_id + provider_event_id (email:<account>:<Message-ID>)",
            "cursor": "per account + mailbox (IMAP UID or Mail received date)",
            "transport_runtime": EmailChannelTransportRuntime.transportId,
        ]
    }

    // MARK: - Discovery

    func listSpaces(channelConnectionId: String? = nil) async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for account in Self.accounts(channelConnectionId, in: configuration()) {
            let connection = await connectionLookup(account.connectionId)
            rows.append([
                "id": account.connectionId,
                "name": connection?.displayName ?? account.connectionId,
                "kind": "mail_account",
                "account_type": connection?.type.rawValue ?? "missing",
                "can_send": connection.map(Self.canSend) ?? false,
            ])
        }
        return rows
    }

    func listRooms(spaceId: String, channelConnectionId: String? = nil) async -> [[String: Any]] {
        let space = spaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [[String: Any]] = []
        for account in Self.accounts(channelConnectionId, in: configuration())
        where space.isEmpty || account.connectionId == space {
            let connection = await connectionLookup(account.connectionId)
            for mailbox in account.effectiveMailboxes {
                let roomId = EmailChannelConfiguration.roomId(connectionId: account.connectionId, mailbox: mailbox)
                rows.append([
                    "id": roomId,
                    "name": Self.roomName(connection: connection, mailbox: mailbox),
                    "kind": "mailbox",
                    "read_allowed": account.canRead(roomId: roomId),
                    "write_allowed": account.canWrite(roomId: roomId) && (connection.map(Self.canSend) ?? false),
                ])
            }
        }
        return rows
    }

    static func roomName(connection: SourceConnection?, mailbox: String) -> String {
        let box = EmailMailboxName.display(mailbox)
        guard let connection else { return box }
        return "\(connection.displayName) · \(box)"
    }

    static func canSend(_ connection: SourceConnection) -> Bool {
        switch connection.config {
        case .mailApp: true
        case .imap(let imap): imap.canSend
        case .apiToken: false
        }
    }

    // MARK: - Reads (local message store)

    func readMailbox(roomId: String, limit: Int?, channelConnectionId: String? = nil) throws -> [String: Any] {
        let (room, account) = try requireReadableRoom(roomId, channelConnectionId: channelConnectionId)
        let safeLimit = EmailChannelConfiguration.clampReadLimit(limit ?? account.defaultReadLimit)
        let store = try openStore()
        let rows = try store.recentMessages(connectionId: account.channelConnectionId, roomId: room, limit: safeLimit)
        return [
            "kind": "email_stored_messages",
            "room_id": room,
            "limit": safeLimit,
            "partial": true,
            "messages": rows.map(Self.storedMessageDictionary),
        ]
    }

    func readThread(threadId: String, limit: Int?, channelConnectionId: String? = nil) throws -> [String: Any] {
        let thread = EmailMIME.cleanId(threadId)
        guard !thread.isEmpty else { throw EmailChannelServiceError.threadNotFound(threadId) }
        let accounts = Self.accounts(channelConnectionId, in: configuration())
        let safeLimit = EmailChannelConfiguration.clampReadLimit(limit ?? accounts.first?.defaultReadLimit ?? 25)
        let rows = try threadMessages(thread, accounts: accounts)
        guard !rows.isEmpty else { throw EmailChannelServiceError.threadNotFound(thread) }
        return [
            "kind": "email_stored_thread",
            "thread_id": thread,
            "limit": safeLimit,
            "partial": true,
            "messages": rows.suffix(safeLimit).map(Self.storedMessageDictionary),
        ]
    }

    func searchMessages(
        query: String, roomIds: [String]?, limitPerRoom: Int?, maxMatches: Int?, channelConnectionId: String? = nil
    ) throws -> [String: Any] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { throw EmailChannelServiceError.emptyMessage }
        let accounts = Self.accounts(channelConnectionId, in: configuration())
        let candidates = (roomIds ?? accounts.flatMap(\.roomIds)).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rooms: [(String, EmailChannelAccount)] = candidates.compactMap { room in
            accounts.first { $0.canRead(roomId: room) }.map { (room, $0) }
        }
        guard !rooms.isEmpty else { throw EmailChannelServiceError.roomNotReadable(candidates.first ?? "") }
        let store = try openStore()
        let safeLimit = EmailChannelConfiguration.clampReadLimit(
            limitPerRoom ?? accounts.first?.defaultReadLimit ?? 25)
        let safeMax = min(max(maxMatches ?? 25, 1), 50)
        var matches: [[String: Any]] = []
        for (room, account) in rooms {
            for row in try store.recentMessages(
                connectionId: account.channelConnectionId, roomId: room, limit: safeLimit)
            {
                let haystack = "\(row.content) \(row.authorName ?? "") \(row.authorId ?? "")".lowercased()
                guard haystack.contains(needle) else { continue }
                matches.append(Self.storedMessageDictionary(row))
                if matches.count >= safeMax { break }
            }
            if matches.count >= safeMax { break }
        }
        return [
            "kind": "email_stored_message_search",
            "query": query,
            "searched_room_ids": rooms.map(\.0),
            "limit_per_room": safeLimit,
            "max_matches": safeMax,
            "match_count": matches.count,
            "partial": true,
            "messages": matches,
        ]
    }

    /// Stored messages of a thread in watched mailboxes, oldest first.
    private func threadMessages(_ thread: String, accounts: [EmailChannelAccount]) throws
        -> [AgentChannelStoredMessage]
    {
        let store = try openStore()
        var rows: [AgentChannelStoredMessage] = []
        for account in accounts {
            for room in account.roomIds {
                rows += try store.recentMessages(connectionId: account.channelConnectionId, roomId: room, limit: 200)
                    .filter { $0.threadId == thread || $0.providerMessageId == thread }
            }
        }
        return rows.sorted { $0.receivedAt < $1.receivedAt }
    }

    // MARK: - Writes

    /// `reply_thread`: answers the newest received message in the thread.
    func replyToThread(
        threadId: String, content: String, confirmSend: Bool, channelConnectionId: String? = nil
    ) async throws -> [String: Any] {
        guard confirmSend else { throw EmailChannelServiceError.sendConfirmationRequired }
        let thread = EmailMIME.cleanId(threadId)
        let accounts = Self.accounts(channelConnectionId, in: configuration())
        guard
            let latest = try threadMessages(thread, accounts: accounts).last(where: { $0.direction == .inbound }),
            let original = Self.emailMessage(from: latest),
            let route = EmailChannelConfiguration.parseRoomId(latest.roomId)
        else { throw EmailChannelServiceError.threadNotFound(thread) }
        var payload = try await sendReply(
            to: original, connectionId: route.connectionId, mailbox: route.mailbox, body: content)
        payload["thread_id"] = thread
        return payload
    }

    /// Sends `body` as a reply to `original`, threaded under it, from the
    /// account that received it.
    @discardableResult
    func sendReply(to original: EmailMessage, connectionId: String, mailbox: String, body: String) async throws
        -> [String: Any]
    {
        let roomId = EmailChannelConfiguration.roomId(connectionId: connectionId, mailbox: mailbox)
        guard let account = configuration().account(connectionId: connectionId) else {
            throw EmailChannelServiceError.accountMissing(connectionId)
        }
        guard account.writeEnabled else { throw EmailChannelServiceError.writeDisabled }
        guard account.canWrite(roomId: roomId) else { throw EmailChannelServiceError.roomNotWritable(roomId) }
        guard writeKillSwitch.snapshot().writeEnabled else { throw EmailChannelServiceError.globalWritesDisabled }
        let text = try Self.validateReply(body)
        guard let connection = await connectionLookup(connectionId) else {
            throw EmailChannelServiceError.accountMissing(connectionId)
        }
        let thread = original.threadId ?? original.messageId
        var result: [String: Any] = [
            "kind": "email_reply_sent",
            "room_id": roomId,
            "in_reply_to": original.messageId,
            "to": original.from,
        ]
        switch connection.config {
        case .mailApp(let mailConfig):
            let path = MailAppMailboxFetcher(account: mailConfig.account).path(for: mailbox)
            let sent = try await mailService.reply(
                id: original.messageId, mailboxPath: path, body: text, replyAll: false, send: true)
            result["via"] = "mail_app"
            result["subject"] = sent.subject
            result["delivery_status"] = sent.sent ? "sent" : "draft"
        case .imap(let imap):
            guard imap.canSend, let from = imap.effectiveFromAddress else {
                throw EmailChannelServiceError.accountCannotSend(connection.displayName)
            }
            guard let secret = password(connection.id) else { throw SMTPError.passwordMissing }
            let message = EmailMessageBuilder.reply(to: original, from: from, body: text)
            let smtpConfig = SMTPClient.Config(imap: imap, password: secret)
            let client =
                makeSMTPTransport.map { SMTPClient(config: smtpConfig, makeTransport: $0) }
                ?? SMTPClient(config: smtpConfig)
            try await client.send(message)
            result["via"] = "smtp"
            result["subject"] = message.subject
            result["message_id"] = message.messageId
            result["delivery_status"] = "sent"
        case .apiToken:
            throw EmailChannelServiceError.accountCannotSend(connection.displayName)
        }
        recordOutbound(
            channelConnectionId: account.channelConnectionId, roomId: roomId, threadId: thread, content: text,
            providerMessageId: (result["message_id"] as? String) ?? "reply-\(UUID().uuidString.lowercased())")
        return result
    }

    /// Opens an unsent reply in Mail for review (Mail app accounts). Nothing
    /// is sent, so neither Allow Sending nor the write switch applies.
    func saveDraft(to original: EmailMessage, connectionId: String, mailbox: String, body: String) async throws {
        let text = try Self.validateReply(body)
        guard let connection = await connectionLookup(connectionId), case .mailApp(let mailConfig) = connection.config
        else { return }
        let path = MailAppMailboxFetcher(account: mailConfig.account).path(for: mailbox)
        _ = try await mailService.reply(
            id: original.messageId, mailboxPath: path, body: text, replyAll: false, send: false)
    }

    // MARK: - Inbound

    /// Authorizes, stores and dispatches newly arrived mail from one watched mailbox.
    @discardableResult
    func ingest(
        _ messages: [EmailMessage], connection: SourceConnection, account: EmailChannelAccount, mailbox: String
    ) async throws -> AgentChannelReceiveBatchSummary {
        guard let messageStore else { throw EmailChannelServiceError.messageStoreUnavailable }
        try messageStore.openIfNeeded()
        let channelConnectionId = account.channelConnectionId
        let roomId = EmailChannelConfiguration.roomId(connectionId: connection.id, mailbox: mailbox)
        let authorizer = AgentChannelConnectionService(discordService: .shared, emailService: self)
        var inserted = 0
        var attempted = 0
        var suppressed = 0

        for message in messages {
            let eventId = Self.providerEventId(connectionId: connection.id, messageId: message.messageId)
            await activityCenter.record(connectionId: channelConnectionId, providerEventId: eventId, stage: .received)
            let content = Self.agentContent(message.trimmed(toBodyChars: account.maxBodyChars), includeBody: account.includeBody)
            let authorization = try authorizer.authorizeInboundMessage(
                AgentChannelInboundMessageAuthorizationRequest(
                    connectionId: channelConnectionId,
                    providerEventId: eventId,
                    providerMessageId: message.messageId,
                    spaceId: connection.id,
                    roomId: roomId,
                    senderId: message.from.lowercased(),
                    isBotMessage: Self.isAutomatedSender(message.from),
                    isSelfMessage: Self.isOwnAddress(message.from, connection: connection)),
                messageStore: messageStore)
            let receive = try messageStore.recordReceiveEvent(
                connectionId: channelConnectionId,
                providerEventId: eventId,
                authorization: authorization,
                message: Self.storedMessage(
                    message, connectionId: channelConnectionId, roomId: roomId, content: content,
                    account: connection.displayName))
            if receive.messageInserted { inserted += 1 }
            guard receive.disposition == .accepted else {
                await activityCenter.record(
                    connectionId: channelConnectionId, providerEventId: eventId, stage: .rejected,
                    reason: receive.authorizationReason)
                continue
            }
            await activityCenter.record(connectionId: channelConnectionId, providerEventId: eventId, stage: .stored)
            let submission = await dispatch(
                message, content: content, eventId: eventId, roomId: roomId, connection: connection,
                account: account, mailbox: mailbox)
            attempted += submission.dispatchAttempted
            suppressed += submission.dispatchSuppressed
            switch submission {
            case .dispatched(let target, let rule):
                await activityCenter.record(
                    connectionId: channelConnectionId, providerEventId: eventId, stage: .dispatched,
                    reason: await AgentChannelInboundActivityPresentation.dispatchReason(target: target, rule: rule))
            case .fired(let eventNames, _):
                await activityCenter.record(
                    connectionId: channelConnectionId, providerEventId: eventId, stage: .dispatched,
                    reason: AgentChannelInboundActivityPresentation.firedReason(eventNames: eventNames))
            case .suppressed(let reason):
                await activityCenter.record(
                    connectionId: channelConnectionId, providerEventId: eventId, stage: .dispatchSuppressed,
                    reason: reason)
            }
        }
        return AgentChannelReceiveBatchSummary(
            received: messages.count, stored: inserted, dispatchAttempted: attempted, dispatchSuppressed: suppressed)
    }

    private func dispatch(
        _ message: EmailMessage, content: String, eventId: String, roomId: String, connection: SourceConnection,
        account: EmailChannelAccount, mailbox: String
    ) async -> AgentChannelInboundRelaySubmission {
        let sender = message.from.lowercased()
        let thread = message.threadId ?? message.messageId
        let identity = ChannelIdentity(
            kind: .email,
            installationId: connection.id,
            groupId: roomId,
            threadId: thread,
            sender: ChannelSenderMetadata(senderId: sender, displayName: message.fromName, email: sender),
            trustLevel: .verified)
        let connectionId = connection.id
        let responder: AgentChannelInboundReplyHandler = { [weak self] reply in
            guard let self else { throw EmailChannelServiceError.messageStoreUnavailable }
            try await self.sendReply(to: message, connectionId: connectionId, mailbox: mailbox, body: reply)
        }
        var drafter: AgentChannelInboundReplyHandler?
        if case .mailApp = connection.config, account.draftUnsentReplies {
            drafter = { [weak self] reply in
                try await self?.saveDraft(to: message, connectionId: connectionId, mailbox: mailbox, body: reply)
            }
        }
        let subject = message.subject.isEmpty ? "" : ", subject \"\(message.subject)\""
        return await deliverToEvents(
            ChannelInboundMessage(
                identity: identity,
                kind: .email,
                connectionId: account.channelConnectionId,
                providerEventId: eventId,
                providerRoute: AgentChannelProviderRoute(
                    conversationId: roomId,
                    threadId: thread,
                    replyAddress: sender,
                    displayName: Self.roomName(connection: connection, mailbox: mailbox)),
                content: content,
                sourceLabel: "Email from \(sender) in \(Self.roomName(connection: connection, mailbox: mailbox))\(subject)",
                mentionsBot: nil,
                reply: responder,
                draftReply: drafter,
                extraPayload: [
                    "email": EventPayload.emailFields(
                        message: message.trimmed(toBodyChars: account.maxBodyChars),
                        connectionId: connection.id, account: connection.displayName,
                        includeBody: account.includeBody)
                ]))
    }

    // MARK: - Helpers

    static func providerEventId(connectionId: String, messageId: String) -> String {
        "email:\(connectionId):\(messageId)"
    }

    /// What the agent reads: the headers that matter, then the text.
    static func agentContent(_ message: EmailMessage, includeBody: Bool) -> String {
        var lines: [String] = []
        let from = message.fromName.map { "\($0) <\(message.from)>" } ?? message.from
        lines.append("From: \(from)")
        if !message.subject.isEmpty { lines.append("Subject: \(message.subject)") }
        if !message.attachments.isEmpty {
            lines.append("Attachments: " + message.attachments.map(\.name).joined(separator: ", "))
        }
        let text = (includeBody ? message.body : nil) ?? message.snippet
        if !text.isEmpty {
            lines.append("")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    /// Bounces and no-reply senders are never answered, so two
    /// auto-responders can't mail each other forever.
    static func isAutomatedSender(_ address: String) -> Bool {
        let local = address.lowercased().split(separator: "@").first.map(String.init) ?? ""
        let automated = ["mailer-daemon", "postmaster", "noreply", "no-reply", "donotreply", "do-not-reply"]
        return automated.contains(local)
    }

    static func isOwnAddress(_ address: String, connection: SourceConnection) -> Bool {
        guard case .imap(let imap) = connection.config else { return false }
        let lowered = address.lowercased()
        return lowered == imap.effectiveFromAddress || lowered == imap.username.lowercased()
    }

    static func validateReply(_ body: String) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmailChannelServiceError.emptyMessage }
        guard trimmed.count <= maxReplyLength else { throw EmailChannelServiceError.messageTooLong }
        return trimmed
    }

    private func requireReadableRoom(_ roomId: String, channelConnectionId: String?) throws
        -> (String, EmailChannelAccount)
    {
        let room = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EmailChannelConfiguration.parseRoomId(room) != nil else {
            throw EmailChannelServiceError.invalidRoomId(roomId)
        }
        guard let account = Self.accounts(channelConnectionId, in: configuration()).first(where: {
            $0.canRead(roomId: room)
        }) else { throw EmailChannelServiceError.roomNotReadable(room) }
        return (room, account)
    }

    private func openStore() throws -> AgentChannelMessageStore {
        guard let messageStore else { throw EmailChannelServiceError.messageStoreUnavailable }
        try messageStore.openIfNeeded()
        return messageStore
    }

    private func recordOutbound(
        channelConnectionId: String, roomId: String, threadId: String, content: String, providerMessageId: String
    ) {
        guard let messageStore else { return }
        let message = AgentChannelStoredMessage(
            connectionId: channelConnectionId, roomId: roomId, providerMessageId: providerMessageId,
            direction: .outbound, threadId: threadId, content: content,
            providerTimestamp: ISO8601DateFormatter().string(from: Date()))
        do {
            try messageStore.openIfNeeded()
            _ = try messageStore.recordMessages([message])
        } catch {
            NSLog("[Email] Failed to record outbound reply: \(error.localizedDescription)")
        }
    }

    // MARK: - Stored rows

    private struct StoredEmail: Codable {
        var messageId: String
        var threadId: String?
        var subject: String
        var from: String
        var fromName: String?
        var to: [String]
        var cc: [String]
        var date: Date?
        var mailbox: String
        var account: String
        var attachments: [String]
    }

    static func storedMessage(
        _ message: EmailMessage, connectionId: String = nativeConnectionId, roomId: String, content: String,
        account: String
    ) -> AgentChannelStoredMessage
    {
        let stored = StoredEmail(
            messageId: message.messageId, threadId: message.threadId, subject: message.subject, from: message.from,
            fromName: message.fromName, to: message.to, cc: message.cc, date: message.date, mailbox: message.mailbox,
            account: account, attachments: message.attachments.map(\.name))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = (try? encoder.encode(stored)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return AgentChannelStoredMessage(
            connectionId: connectionId,
            roomId: roomId,
            providerMessageId: message.messageId,
            direction: .inbound,
            threadId: message.threadId ?? message.messageId,
            authorId: message.from.lowercased(),
            authorName: message.fromName,
            content: content,
            payloadJSON: payload,
            providerTimestamp: message.date.map { ISO8601DateFormatter().string(from: $0) })
    }

    /// The received message a stored row came from, enough to reply to it.
    static func emailMessage(from row: AgentChannelStoredMessage) -> EmailMessage? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(StoredEmail.self, from: Data(row.payloadJSON.utf8)) else { return nil }
        return EmailMessage(
            messageId: stored.messageId, threadId: stored.threadId, subject: stored.subject, from: stored.from,
            fromName: stored.fromName, to: stored.to, cc: stored.cc, date: stored.date, mailbox: stored.mailbox,
            snippet: "", body: nil, attachments: [], isRead: true, sizeBytes: nil)
    }

    static func storedMessageDictionary(_ message: AgentChannelStoredMessage) -> [String: Any] {
        var row: [String: Any] = [
            "id": message.providerMessageId,
            "room_id": message.roomId,
            "thread_id": message.threadId ?? message.providerMessageId,
            "content": message.content,
            "timestamp": message.providerTimestamp ?? "",
            "author": [
                "id": message.authorId ?? "",
                "display_name": message.authorName ?? "",
            ],
            "direction": message.direction.rawValue,
        ]
        if let original = emailMessage(from: message) {
            row["subject"] = original.subject
            if !original.to.isEmpty { row["to"] = original.to }
            if !original.cc.isEmpty { row["cc"] = original.cc }
        }
        return row
    }
}
