//
//  TelegramConnectionService.swift
//  osaurus
//
//  Policy, normalization, and diagnostics layer for the native Telegram channel.
//

import Foundation

struct TelegramConnectionDiagnostics: Equatable, Sendable {
    let tokenSaved: Bool
    let bot: TelegramUser?
    let readableChatIds: [String]
    let writableChatIds: [String]
    let senderAllowlist: [String]
    let writeEnabled: Bool
    let status: String
    let failures: [String]

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "token_saved": tokenSaved,
            "readable_chat_ids": readableChatIds,
            "writable_chat_ids": writableChatIds,
            "sender_allowlist": senderAllowlist,
            "write_enabled": writeEnabled,
            "status": status,
            "failures": failures,
        ]
        if let bot {
            result["bot"] = [
                "id": "\(bot.id)",
                "username": bot.username ?? "",
                "display_name": bot.displayName,
                "is_bot": bot.isBot,
            ]
        }
        return result
    }
}

enum TelegramConnectionServiceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidChatId(String)
    case chatNotReadable(String)
    case chatNotWritable(String)
    case writeDisabled
    case sendConfirmationRequired
    case messageTooLong
    case emptyMessage
    case configurationSaveFailed(String)
    case messageStoreUnavailable
    case invalidWebhookSecret
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Telegram is not configured. Add a bot token in Settings and allowlist at least one chat."
        case .invalidChatId(let chatId):
            return "`\(chatId)` is not a valid Telegram chat id or @channel username."
        case .chatNotReadable(let chatId):
            return "Telegram chat `\(chatId)` is not allowlisted for read access."
        case .chatNotWritable(let chatId):
            return "Telegram chat `\(chatId)` is not allowlisted for write access."
        case .writeDisabled:
            return "Telegram write access is disabled in settings."
        case .sendConfirmationRequired:
            return "`confirm_send` must be true before Osaurus posts to Telegram."
        case .messageTooLong:
            return "Telegram messages must fit Telegram's 4096-character limit."
        case .emptyMessage:
            return "Telegram message content must not be empty."
        case .configurationSaveFailed(let message):
            return "Telegram configuration could not be saved: \(message)"
        case .messageStoreUnavailable:
            return "Telegram message store is unavailable."
        case .invalidWebhookSecret:
            return "Telegram webhook secret token did not match the configured value."
        case .api(let message):
            return message
        }
    }
}

enum TelegramUpdateNormalizer {
    static let connectionId = "telegram"
    static let maxInboundContentLength = 4096

    static func normalize(
        update: TelegramUpdate,
        botId: Int64?,
        configuration: TelegramConnectionConfiguration
    ) -> TelegramReceiveResultOrEvent {
        let providerEventId = "\(update.updateId)"
        guard let message = update.primaryMessage else {
            return .result(
                TelegramReceiveResult(
                    providerEventId: providerEventId,
                    roomId: nil,
                    providerMessageId: nil,
                    status: .ignored,
                    reason: "update_has_no_message"
                )
            )
        }

        let stableRoomId = message.chat.stableId
        let providerMessageId = "\(message.messageId)"
        let roomId = configuration.readableRoomId(for: message.chat) ?? stableRoomId
        let senderId = message.from.map { "\($0.id)" } ?? message.senderChat.map { "\($0.id)" }
        let content = message.contentText
        guard !content.isEmpty else {
            return .result(
                TelegramReceiveResult(
                    providerEventId: providerEventId,
                    roomId: stableRoomId,
                    providerMessageId: providerMessageId,
                    status: .ignored,
                    reason: "empty_message_content"
                )
            )
        }
        guard content.utf16.count <= Self.maxInboundContentLength else {
            return .result(
                TelegramReceiveResult(
                    providerEventId: providerEventId,
                    roomId: roomId,
                    providerMessageId: providerMessageId,
                    status: .ignored,
                    reason: "message_too_long"
                )
            )
        }

        return .event(
            TelegramNormalizedInboundEvent(
                providerEventId: providerEventId,
                roomId: roomId,
                providerMessageId: providerMessageId,
                content: content,
                senderId: senderId,
                authorName: message.from?.displayName ?? message.senderChat?.displayName,
                isBotMessage: message.from?.isBot == true,
                isSelfMessage: botId != nil && message.from?.id == botId,
                providerTimestamp: Self.iso8601Timestamp(fromTelegramDate: message.date),
                payloadJSON: encodedPayload(update)
            )
        )
    }

    static func storedMessage(_ event: TelegramNormalizedInboundEvent) -> AgentChannelStoredMessage {
        AgentChannelStoredMessage(
            connectionId: connectionId,
            roomId: event.roomId,
            providerMessageId: event.providerMessageId,
            direction: .inbound,
            authorId: event.senderId,
            authorName: event.authorName,
            content: event.content,
            payloadJSON: event.payloadJSON,
            providerTimestamp: event.providerTimestamp
        )
    }

    private static func encodedPayload(_ update: TelegramUpdate) -> String {
        guard let data = try? JSONEncoder().encode(update),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private static func iso8601Timestamp(fromTelegramDate date: Int) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(date)))
    }
}

enum TelegramReceiveResultOrEvent: Equatable, Sendable {
    case result(TelegramReceiveResult)
    case event(TelegramNormalizedInboundEvent)
}

private enum TelegramReceivePendingResult {
    case result(TelegramReceiveResult)
    case event(TelegramNormalizedInboundEvent)
}

final class TelegramConnectionService: @unchecked Sendable {
    static let nativeConnectionId = TelegramUpdateNormalizer.connectionId
    static let updatesCursorRoomId = "__telegram_updates__"

    static let shared = TelegramConnectionService(
        client: TelegramAPIClient(),
        credentialStore: KeychainTelegramCredentialStorage(),
        messageStore: AgentChannelMessageStore.shared
    )

    private static let connectionId = nativeConnectionId

    private let client: TelegramAPIClientProtocol
    private let credentialStore: any TelegramCredentialStorage
    private let messageStore: AgentChannelMessageStore?
    private let recordMessageSnapshotsInline: Bool
    private let botIdentityLock = NSLock()
    private var cachedBotId: Int64?

    init(
        client: TelegramAPIClientProtocol,
        credentialStore: any TelegramCredentialStorage = KeychainTelegramCredentialStorage(),
        messageStore: AgentChannelMessageStore? = nil,
        recordMessageSnapshotsInline: Bool = false
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.messageStore = messageStore
        self.recordMessageSnapshotsInline = recordMessageSnapshotsInline
    }

    func configuration() -> TelegramConnectionConfiguration {
        TelegramConnectionConfigurationStore.load()
    }

    func saveConfiguration(_ configuration: TelegramConnectionConfiguration) throws {
        do {
            try TelegramConnectionConfigurationStore.save(configuration)
        } catch {
            throw TelegramConnectionServiceError.configurationSaveFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func saveBotToken(_ token: String) throws -> Bool {
        clearCachedBotIdentity()
        let saved = credentialStore.saveBotToken(token)
        if !saved {
            throw TelegramConnectionServiceError.configurationSaveFailed(
                "The token was empty or Keychain storage was unavailable."
            )
        }
        return saved
    }

    @discardableResult
    func deleteBotToken() -> Bool {
        clearCachedBotIdentity()
        return credentialStore.deleteBotToken()
    }

    func hasBotToken() -> Bool {
        credentialStore.hasBotToken()
    }

    func diagnostics() async -> TelegramConnectionDiagnostics {
        let config = configuration()
        guard let token = credentialStore.botToken() else {
            return TelegramConnectionDiagnostics(
                tokenSaved: false,
                bot: nil,
                readableChatIds: config.readableChatIds,
                writableChatIds: config.writableChatIds,
                senderAllowlist: config.senderAllowlist,
                writeEnabled: config.writeEnabled,
                status: "not_configured",
                failures: ["No Telegram bot token is saved."]
            )
        }

        var failures: [String] = []
        let bot: TelegramUser?
        do {
            bot = try await client.getMe(token: token)
        } catch {
            bot = nil
            failures.append(redacted(error, token: token))
        }

        let receiveNeedsSenderAllowlist = config.receiveStorageEnabled
            && config.longPollingEnabled
            && !config.readableChatIds.isEmpty
            && config.senderAllowlist.isEmpty

        let status: String
        if bot == nil {
            status = "token_invalid_or_unavailable"
        } else if config.readableChatIds.isEmpty {
            status = "connected_needs_allowlist"
        } else if receiveNeedsSenderAllowlist {
            status = "connected_receive_needs_sender_allowlist"
        } else if config.writeEnabled && config.writableChatIds.isEmpty {
            status = "connected_read_only_write_needs_chats"
        } else if config.writeEnabled {
            status = "connected_read_write"
        } else {
            status = "connected_read_only"
        }

        if receiveNeedsSenderAllowlist {
            failures.append(
                "Telegram long polling is enabled with readable chats but no authorized sender IDs; inbound updates will be denied before storage or dispatch."
            )
        }

        return TelegramConnectionDiagnostics(
            tokenSaved: true,
            bot: bot,
            readableChatIds: config.readableChatIds,
            writableChatIds: config.writableChatIds,
            senderAllowlist: config.senderAllowlist,
            writeEnabled: config.writeEnabled,
            status: status,
            failures: failures
        )
    }

    func messageStoreDiagnostics() -> [String: Any] {
        [
            "enabled": messageStore != nil,
            "open": messageStore?.isOpen ?? false,
            "database_path": OsaurusPaths.agentChannelMessagesDatabaseFile().path,
            "message_dedupe": "connection_id + room_id + provider_message_id",
            "event_dedupe": "connection_id + provider_event_id",
            "cursor": "telegram getUpdates offset stored in channel_receive_cursors",
            "transport_runtime": "telegram_long_poll",
        ]
    }

    func listSpaces() -> [[String: Any]] {
        [
            [
                "id": "telegram",
                "name": "Telegram",
                "kind": "messaging_network",
            ]
        ]
    }

    func listChats() async throws -> [[String: Any]] {
        let config = configuration()
        let token = credentialStore.botToken()
        var rows: [[String: Any]] = []
        for chatId in config.configuredChatIds {
            var row: [String: Any] = [
                "id": chatId,
                "name": chatId,
                "kind": "chat",
                "read_allowed": config.canRead(chatId: chatId),
                "write_allowed": config.canWrite(chatId: chatId),
            ]
            if let token {
                do {
                    let chat = try await client.getChat(chatId: chatId, token: token)
                    row["provider_chat_id"] = chat.stableId
                    row["name"] = chat.displayName
                    row["type"] = chat.type
                    row["username"] = chat.username ?? ""
                } catch {
                    row["error"] = redacted(error, token: token)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func readChat(_ request: TelegramReadRequest) throws -> [String: Any] {
        let config = configuration()
        let chatId = try requireReadableChat(request.chatId, config: config)
        let safeLimit = TelegramConnectionConfiguration.clampReadLimit(request.limit ?? config.defaultReadLimit)
        guard let messageStore else {
            throw TelegramConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()
        let rows = try messageStore.recentMessages(
            connectionId: Self.connectionId,
            roomId: chatId,
            limit: safeLimit
        )
        return [
            "kind": "telegram_stored_messages",
            "chat_id": chatId,
            "limit": safeLimit,
            "partial": true,
            "messages": rows.map(Self.storedMessageDictionary),
        ]
    }

    func searchMessages(
        query: String,
        chatIds: [String]?,
        limitPerChat: Int?,
        maxMatches: Int?
    ) throws -> [String: Any] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw TelegramConnectionServiceError.emptyMessage
        }
        let config = configuration()
        let candidateChats = TelegramConnectionConfiguration.normalizedIds(chatIds ?? config.readableChatIds)
        let allowedChats = candidateChats.filter { config.canRead(chatId: $0) }
        guard !allowedChats.isEmpty else {
            throw TelegramConnectionServiceError.chatNotReadable(candidateChats.first ?? "")
        }
        guard let messageStore else {
            throw TelegramConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()

        let safeLimit = TelegramConnectionConfiguration.clampReadLimit(limitPerChat ?? config.defaultReadLimit)
        let safeMaxMatches = min(max(maxMatches ?? 25, 1), 50)
        let needle = trimmedQuery.lowercased()
        var matches: [[String: Any]] = []

        for chatId in allowedChats {
            let rows = try messageStore.recentMessages(
                connectionId: Self.connectionId,
                roomId: chatId,
                limit: safeLimit
            )
            for row in rows {
                let haystack = "\(row.content) \(row.authorName ?? "") \(row.authorId ?? "")".lowercased()
                guard haystack.contains(needle) else { continue }
                matches.append(Self.storedMessageDictionary(row))
                if matches.count >= safeMaxMatches { break }
            }
            if matches.count >= safeMaxMatches { break }
        }

        return [
            "kind": "telegram_stored_message_search",
            "query": trimmedQuery,
            "searched_chat_ids": allowedChats,
            "limit_per_chat": safeLimit,
            "max_matches": safeMaxMatches,
            "match_count": matches.count,
            "partial": true,
            "messages": matches,
        ]
    }

    func draftMessage(chatId: String, content: String) throws -> [String: Any] {
        let config = configuration()
        let normalizedChatId = try requireWritableChat(chatId, config: config)
        let trimmedContent = try validateMessageContent(content)
        return [
            "kind": "telegram_message_draft",
            "chat_id": normalizedChatId,
            "content": trimmedContent,
            "requires_send_confirmation": true,
        ]
    }

    func sendMessage(_ request: TelegramWriteRequest) async throws -> [String: Any] {
        guard request.confirmSend else {
            throw TelegramConnectionServiceError.sendConfirmationRequired
        }
        let token = try requireToken()
        let config = configuration()
        let chatId = try requireWritableChat(request.chatId, config: config)
        let text = try validateMessageContent(request.text)
        let message = try await client.sendMessage(
            chatId: chatId,
            text: text,
            replyToMessageId: request.replyToMessageId,
            token: token
        )
        recordMessages([Self.storedMessage(message, roomId: chatId, direction: .outbound)])
        return [
            "kind": "telegram_message_sent",
            "chat_id": chatId,
            "delivery_status": TelegramDeliveryStatus.sent.rawValue,
            "message": Self.messageDictionary(message),
        ]
    }

    func processWebhookPayload(
        _ data: Data,
        secretTokenHeader: String? = nil,
        expectedSecretToken: String? = nil
    ) async throws -> TelegramReceiveBatchResult {
        if let expectedSecretToken,
           !Self.constantTimeEquals(secretTokenHeader ?? "", expectedSecretToken) {
            throw TelegramConnectionServiceError.invalidWebhookSecret
        }
        let update = try JSONDecoder().decode(TelegramUpdate.self, from: data)
        return try await processUpdates([update], source: "webhook")
    }

    func pollUpdates(limit: Int = 100, timeout: Int = 0) async throws -> TelegramReceiveBatchResult {
        let token = try requireToken()
        guard let messageStore else {
            throw TelegramConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()
        let cursor = try messageStore.cursor(
            connectionId: Self.connectionId,
            roomId: Self.updatesCursorRoomId
        )
        let offset = cursor.flatMap(Int64.init)
        let updates = try await client.getUpdates(
            offset: offset,
            limit: TelegramConnectionConfiguration.clampLongPollingLimit(limit),
            timeout: TelegramConnectionConfiguration.clampLongPollingTimeoutSeconds(timeout),
            token: token
        )
        return try await processUpdates(updates, source: "long_poll")
    }

    func processUpdates(_ updates: [TelegramUpdate], source: String) async throws -> TelegramReceiveBatchResult {
        guard let messageStore else {
            throw TelegramConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()

        let config = configuration()
        let botId = await currentBotIdForNormalization()
        var pending: [TelegramReceivePendingResult] = []
        var maxUpdateId: Int64?

        for update in updates {
            maxUpdateId = max(maxUpdateId ?? update.updateId, update.updateId)
            switch TelegramUpdateNormalizer.normalize(update: update, botId: botId, configuration: config) {
            case .result(let result):
                pending.append(.result(result))
            case .event(let event):
                pending.append(.event(event))
            }
        }

        var inserted = 0
        var results: [TelegramReceiveResult] = []
        let authorizationService = AgentChannelConnectionService(
            discordService: .shared,
            telegramService: self
        )
        for item in pending {
            switch item {
            case .result(let result):
                results.append(result)
            case .event(let event):
                let authorization = try authorizationService.authorizeInboundMessage(
                    AgentChannelInboundMessageAuthorizationRequest(
                        connectionId: Self.connectionId,
                        providerEventId: event.providerEventId,
                        providerMessageId: event.providerMessageId,
                        spaceId: "telegram",
                        roomId: event.roomId,
                        senderId: event.senderId,
                        isBotMessage: event.isBotMessage,
                        isSelfMessage: event.isSelfMessage
                    ),
                    messageStore: messageStore
                )
                let receive = try messageStore.recordReceiveEvent(
                    connectionId: Self.connectionId,
                    providerEventId: event.providerEventId,
                    authorization: authorization,
                    message: TelegramUpdateNormalizer.storedMessage(event)
                )
                if receive.messageInserted { inserted += 1 }
                results.append(
                    TelegramReceiveResult(
                        providerEventId: event.providerEventId,
                        roomId: event.roomId,
                        providerMessageId: event.providerMessageId,
                        status: Self.deliveryStatus(for: receive),
                        reason: receive.disposition == .accepted ? nil : receive.authorizationReason
                    )
                )
            }
        }
        if source == "long_poll", let maxUpdateId {
            try messageStore.upsertCursor(
                connectionId: Self.connectionId,
                roomId: Self.updatesCursorRoomId,
                cursor: "\(maxUpdateId + 1)"
            )
        }

        return TelegramReceiveBatchResult(
            source: source,
            received: updates.count,
            stored: inserted,
            results: results
        )
    }

    private func currentBotIdForNormalization() async -> Int64? {
        if let cached = botIdentityLock.withLock({ cachedBotId }) {
            return cached
        }
        guard let token = credentialStore.botToken() else { return nil }
        do {
            let botId = try await client.getMe(token: token).id
            botIdentityLock.withLock { cachedBotId = botId }
            return botId
        } catch {
            return botIdentityLock.withLock { cachedBotId }
        }
    }

    private func clearCachedBotIdentity() {
        botIdentityLock.withLock { cachedBotId = nil }
    }

    private func requireToken() throws -> String {
        guard let token = credentialStore.botToken() else {
            throw TelegramConnectionServiceError.notConfigured
        }
        return token
    }

    private func requireChatId(_ chatId: String) throws -> String {
        let normalized = TelegramConnectionConfiguration.normalizedChatId(chatId)
        guard TelegramConnectionConfiguration.isValidChatId(normalized) else {
            throw TelegramConnectionServiceError.invalidChatId(chatId)
        }
        return normalized
    }

    private func requireReadableChat(
        _ chatId: String,
        config: TelegramConnectionConfiguration
    ) throws -> String {
        let normalized = try requireChatId(chatId)
        guard config.canRead(chatId: normalized) else {
            throw TelegramConnectionServiceError.chatNotReadable(normalized)
        }
        return normalized
    }

    private func requireWritableChat(
        _ chatId: String,
        config: TelegramConnectionConfiguration
    ) throws -> String {
        let normalized = try requireChatId(chatId)
        guard config.writeEnabled else {
            throw TelegramConnectionServiceError.writeDisabled
        }
        guard config.canWrite(chatId: normalized) else {
            throw TelegramConnectionServiceError.chatNotWritable(normalized)
        }
        return normalized
    }

    private func validateMessageContent(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TelegramConnectionServiceError.emptyMessage
        }
        guard trimmed.utf16.count <= TelegramUpdateNormalizer.maxInboundContentLength else {
            throw TelegramConnectionServiceError.messageTooLong
        }
        return trimmed
    }

    private static func deliveryStatus(for receive: AgentChannelReceiveResult) -> TelegramDeliveryStatus {
        switch receive.disposition {
        case .accepted:
            return .accepted
        case .duplicate:
            return .duplicate
        case .denied:
            switch receive.authorizationReason {
            case "self_message_denied", "bot_message_denied":
                return .ignored
            default:
                return .unauthorized
            }
        }
    }

    private func redacted(_ error: Error, token: String) -> String {
        TelegramSecurity.redact(error.localizedDescription, token: token)
    }

    private func recordMessages(_ messages: [AgentChannelStoredMessage]) {
        guard let messageStore, !messages.isEmpty else { return }
        if recordMessageSnapshotsInline {
            Self.persistMessages(messages, messageStore: messageStore)
        } else {
            Task.detached(priority: .utility) {
                Self.persistMessages(messages, messageStore: messageStore)
            }
        }
    }

    private static func persistMessages(
        _ rows: [AgentChannelStoredMessage],
        messageStore: AgentChannelMessageStore
    ) {
        do {
            try messageStore.openIfNeeded()
            _ = try messageStore.recordMessages(rows)
        } catch {
            NSLog("[Telegram] Failed to record Agent Channel messages: \(error.localizedDescription)")
        }
    }

    private static func storedMessage(
        _ message: TelegramMessage,
        roomId: String? = nil,
        direction: AgentChannelStoredMessageDirection
    ) -> AgentChannelStoredMessage {
        AgentChannelStoredMessage(
            connectionId: connectionId,
            roomId: roomId ?? message.chat.stableId,
            providerMessageId: "\(message.messageId)",
            direction: direction,
            threadId: message.replyToMessage.map { "\($0.messageId)" },
            authorId: message.from.map { "\($0.id)" } ?? message.senderChat.map { "\($0.id)" },
            authorName: message.from?.displayName ?? message.senderChat?.displayName,
            content: message.contentText,
            payloadJSON: encodedPayload(message),
            providerTimestamp: TelegramUpdateNormalizer.iso8601TimestampForService(message.date)
        )
    }

    private static func encodedPayload(_ message: TelegramMessage) -> String {
        guard let data = try? JSONEncoder().encode(message),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private static func storedMessageDictionary(_ message: AgentChannelStoredMessage) -> [String: Any] {
        [
            "id": message.providerMessageId,
            "chat_id": message.roomId,
            "content": message.content,
            "timestamp": message.providerTimestamp ?? "",
            "author": [
                "id": message.authorId ?? "",
                "display_name": message.authorName ?? "",
            ],
            "direction": message.direction.rawValue,
            "raw": message.payloadJSON,
        ]
    }

    private static func messageDictionary(_ message: TelegramMessage) -> [String: Any] {
        [
            "id": "\(message.messageId)",
            "chat_id": message.chat.stableId,
            "content": message.contentText,
            "timestamp": TelegramUpdateNormalizer.iso8601TimestampForService(message.date),
            "author": [
                "id": message.from.map { "\($0.id)" } ?? "",
                "display_name": message.from?.displayName ?? "",
                "is_bot": message.from?.isBot ?? false,
            ],
        ]
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0 ..< count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

private extension TelegramUpdateNormalizer {
    static func iso8601TimestampForService(_ date: Int) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(date)))
    }
}

actor TelegramLongPollTransportRuntime {
    static let transportId = "telegram_long_poll"

    private let service: TelegramConnectionService
    private let healthCenter: AgentChannelTransportHealthCenter
    private let backoffPolicy: AgentChannelTransportBackoffPolicy
    private let sleeper: any AgentChannelTransportSleeping
    private var worker: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastHealth: AgentChannelTransportHealthState

    init(
        service: TelegramConnectionService = .shared,
        healthCenter: AgentChannelTransportHealthCenter = .shared,
        backoffPolicy: AgentChannelTransportBackoffPolicy = AgentChannelTransportBackoffPolicy(),
        sleeper: any AgentChannelTransportSleeping = AgentChannelTransportTaskSleeper()
    ) {
        self.service = service
        self.healthCenter = healthCenter
        self.backoffPolicy = backoffPolicy
        self.sleeper = sleeper
        self.lastHealth = AgentChannelTransportHealthState(
            connectionId: TelegramConnectionService.nativeConnectionId,
            transportId: Self.transportId,
            provider: .telegram,
            status: .idle,
            severity: .info,
            summary: "Telegram long polling is idle.",
            isRunning: false,
            receiveEnabled: false
        )
    }

    func health() -> AgentChannelTransportHealthState {
        lastHealth
    }

    func start(pollInterval: TimeInterval = 0) {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.runLoop(pollInterval: pollInterval)
        }
    }

    func stop(now: Date = Date()) async {
        let oldWorker = worker
        worker = nil
        oldWorker?.cancel()
        await oldWorker?.value
        consecutiveFailures = 0
        await publish(
            AgentChannelTransportHealthState(
                connectionId: TelegramConnectionService.nativeConnectionId,
                transportId: Self.transportId,
                provider: .telegram,
                status: .idle,
                severity: .info,
                summary: "Telegram long polling is idle.",
                isRunning: false,
                receiveEnabled: service.configuration().longPollingEnabled,
                updatedAt: now
            )
        )
    }

    func runStep(
        now: Date = Date(),
        jitter: Double = Double.random(in: 0 ... 1)
    ) async -> AgentChannelTransportStepResult {
        let configuration = service.configuration()
        guard configuration.receiveStorageEnabled else {
            consecutiveFailures = 0
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: TelegramConnectionService.nativeConnectionId,
                    transportId: Self.transportId,
                    provider: .telegram,
                    status: .disabled,
                    severity: .info,
                    summary: "Telegram receive storage is disabled.",
                    isRunning: false,
                    receiveEnabled: false,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(disposition: .skipped, health: health)
        }
        guard configuration.longPollingEnabled else {
            consecutiveFailures = 0
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: TelegramConnectionService.nativeConnectionId,
                    transportId: Self.transportId,
                    provider: .telegram,
                    status: .disabled,
                    severity: .info,
                    summary: "Telegram long polling is disabled.",
                    isRunning: false,
                    receiveEnabled: true,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(disposition: .skipped, health: health)
        }

        do {
            let batch = try await service.pollUpdates(
                limit: configuration.longPollingLimit,
                timeout: configuration.longPollingTimeoutSeconds
            )
            consecutiveFailures = 0
            let dispatchSuppressed = batch.results.filter { $0.status == .accepted }.count
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: TelegramConnectionService.nativeConnectionId,
                    transportId: Self.transportId,
                    provider: .telegram,
                    status: .healthy,
                    severity: .info,
                    summary: "Telegram long polling is healthy.",
                    isRunning: worker != nil,
                    receiveEnabled: true,
                    lastSuccessAt: now,
                    lastReceivedCount: batch.received,
                    lastStoredCount: batch.stored,
                    dispatchSuppressedCount: dispatchSuppressed,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(
                disposition: .succeeded,
                health: health,
                received: batch.received,
                stored: batch.stored,
                dispatchAttempted: 0,
                dispatchSuppressed: dispatchSuppressed
            )
        } catch TelegramAPIError.conflict(let message) {
            consecutiveFailures += 1
            let delay = backoffPolicy.delay(consecutiveFailures: consecutiveFailures, jitter: jitter)
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: TelegramConnectionService.nativeConnectionId,
                    transportId: Self.transportId,
                    provider: .telegram,
                    status: .conflict,
                    severity: .error,
                    summary: "Telegram long polling has a competing consumer.",
                    detail: message,
                    isRunning: worker != nil,
                    receiveEnabled: true,
                    lastFailureAt: now,
                    nextRetryAt: now.addingTimeInterval(delay),
                    consecutiveFailures: consecutiveFailures,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(
                disposition: .conflict,
                health: health,
                retryDelay: delay
            )
        } catch {
            consecutiveFailures += 1
            let delay = backoffPolicy.delay(consecutiveFailures: consecutiveFailures, jitter: jitter)
            let health = await publish(
                AgentChannelTransportHealthState(
                    connectionId: TelegramConnectionService.nativeConnectionId,
                    transportId: Self.transportId,
                    provider: .telegram,
                    status: .failed,
                    severity: .warning,
                    summary: "Telegram long polling failed.",
                    detail: error.localizedDescription,
                    isRunning: worker != nil,
                    receiveEnabled: true,
                    lastFailureAt: now,
                    nextRetryAt: now.addingTimeInterval(delay),
                    consecutiveFailures: consecutiveFailures,
                    updatedAt: now
                )
            )
            return AgentChannelTransportStepResult(
                disposition: .failed,
                health: health,
                retryDelay: delay
            )
        }
    }

    private func runLoop(pollInterval: TimeInterval) async {
        while !Task.isCancelled {
            let result = await runStep()
            let delay = max(result.retryDelay ?? pollInterval, 1)
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                break
            }
        }
    }

    @discardableResult
    private func publish(_ health: AgentChannelTransportHealthState) async -> AgentChannelTransportHealthState {
        lastHealth = health
        await healthCenter.update(health)
        return health
    }
}

extension TelegramLongPollTransportRuntime: AgentChannelReceiveTransportRuntime {}
