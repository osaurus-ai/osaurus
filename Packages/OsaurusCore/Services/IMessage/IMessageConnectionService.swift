//
//  IMessageConnectionService.swift
//  osaurus
//
//  Policy, normalization, capability gating, and receive/dispatch for the
//  native iMessage channel. Basic send/read run against the pinned `imsg`
//  helper's public methods; advanced (private-API) actions are gated behind
//  per-action operator enablement AND a live capability probe of the helper.
//

import Foundation

/// Method names the pinned `imsg` helper exposes over JSON-RPC. Public
/// methods work in basic mode; advanced ones require the injected bridge
/// (SIP + Library Validation disabled by the operator). These names are part
/// of the pinned-helper contract — see the release runbook.
/// JSON-RPC method names of the pinned imsg release. These MUST match
/// `kSupportedRPCMethods` in the upstream `RPCServer.swift`; the helper
/// advertises the list through `imsg status --json` (`rpc_methods`).
enum IMessageRPCMethod {
    static let listChats = "chats.list"
    static let watchSubscribe = "watch.subscribe"
    static let watchUnsubscribe = "watch.unsubscribe"
    static let send = "send"
    // Advanced (bridge-only). Replies and screen/bubble effects both go
    // through `send.rich`; group operations are separate methods upstream.
    static let sendRich = "send.rich"
    static let edit = "message.edit"
    static let unsend = "message.unsend"
    static let tapback = "tapback"
    static let typing = "typing"
    static let sendAttachment = "send.attachment"
    static let poll = "poll.send"
    static let groupRename = "group.rename"
    static let groupAddParticipant = "group.addParticipant"
    static let groupRemoveParticipant = "group.removeParticipant"
}

struct IMessageConnectionDiagnostics: Equatable, Sendable {
    let helperVerified: Bool
    let helperState: String
    let fullDiskAccess: Bool
    let automationMessages: Bool
    /// nil = unknown. imsg exposes no sign-in probe (verified against the
    /// pinned release source), so this is only ever non-nil if a future
    /// helper release adds one.
    let messagesSignedIn: Bool?
    let bridgeAvailable: Bool
    let advancedActionsEnabled: Bool
    let availableAdvancedMethods: [String]
    let enabledAdvancedActions: [String]
    let readableChatIds: [String]
    let writableChatIds: [String]
    let senderAllowlist: [String]
    let writeEnabled: Bool
    let receiveStorageEnabled: Bool
    let receivePollingEnabled: Bool
    let sipEnabled: Bool?
    let libraryValidationEnabled: Bool?
    let status: String
    let failures: [String]
    let notes: [String]

    var receiveReady: Bool {
        helperVerified
            && fullDiskAccess
            && receiveStorageEnabled
            && receivePollingEnabled
            && !readableChatIds.isEmpty
            && !senderAllowlist.isEmpty
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "helper_verified": helperVerified,
            "helper_state": helperState,
            "full_disk_access": fullDiskAccess,
            "automation_messages": automationMessages,
            "messages_signed_in": messagesSignedIn.map { $0 as Any } ?? "unknown",
            "bridge_available": bridgeAvailable,
            "advanced_actions_enabled": advancedActionsEnabled,
            "available_advanced_methods": availableAdvancedMethods,
            "enabled_advanced_actions": enabledAdvancedActions,
            "receive_ready": receiveReady,
            "readable_chat_ids": readableChatIds,
            "writable_chat_ids": writableChatIds,
            "sender_allowlist": senderAllowlist,
            "write_enabled": writeEnabled,
            "receive_storage_enabled": receiveStorageEnabled,
            "receive_polling_enabled": receivePollingEnabled,
            "authorization": [
                "sender_allowlist": senderAllowlist,
                "room_allowlist": readableChatIds,
                "authorize_before_storage": true,
                "authorize_before_dispatch": true,
            ],
            "status": status,
            "failures": failures,
        ]
        if !notes.isEmpty { result["notes"] = notes }
        if let sipEnabled { result["sip_enabled"] = sipEnabled }
        if let libraryValidationEnabled {
            result["library_validation_enabled"] = libraryValidationEnabled
        }
        return result
    }
}

enum IMessageConnectionServiceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidChatId(String)
    case chatNotReadable(String)
    case chatNotWritable(String)
    case writeDisabled
    case sendConfirmationRequired
    case messageTooLong
    case emptyMessage
    case messageStoreUnavailable
    case configurationSaveFailed(String)
    case advancedActionDisabled(String)
    case advancedActionUnavailable(String)
    case invalidAdvancedParameter(String)
    case attachmentNotAllowed(String)
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "iMessage is not configured. Complete setup and allowlist at least one chat."
        case .invalidChatId(let chatId):
            return "`\(chatId)` is not a valid iMessage chat id or handle."
        case .chatNotReadable(let chatId):
            return "iMessage chat `\(chatId)` is not allowlisted for read access."
        case .chatNotWritable(let chatId):
            return "iMessage chat `\(chatId)` is not allowlisted for write access."
        case .writeDisabled:
            return "iMessage write access is disabled in settings."
        case .sendConfirmationRequired:
            return "`confirm_send` must be true before Osaurus sends an iMessage."
        case .messageTooLong:
            return "iMessage content is too long, even after splitting into multiple messages."
        case .emptyMessage:
            return "iMessage message content must not be empty."
        case .messageStoreUnavailable:
            return "iMessage message store is unavailable."
        case .configurationSaveFailed(let message):
            return "iMessage configuration could not be saved: \(message)"
        case .advancedActionDisabled(let action):
            return "The iMessage advanced action `\(action)` is disabled. Enable it in iMessage settings and acknowledge the private-API security warning first."
        case .advancedActionUnavailable(let action):
            return "The iMessage advanced action `\(action)` needs the private-API bridge, which is not active on this Mac (SIP + Library Validation must be disabled by the operator)."
        case .invalidAdvancedParameter(let detail):
            return "Invalid iMessage advanced-action parameter: \(detail)."
        case .attachmentNotAllowed(let path):
            return "Attachment path is outside the allowlisted iMessage attachment roots."
                + (path.isEmpty ? "" : " (\(IMessageRPCSecurity.redact(path)))")
        case .helper(let message):
            return IMessageRPCSecurity.redact(message)
        }
    }
}

/// Normalizes one inbound iMessage row into an Agent Channel event.
struct IMessageNormalizedInboundEvent: Equatable, Sendable {
    var providerEventId: String
    var roomId: String
    var providerMessageId: String
    var content: String
    var attachments: [AgentChannelStoredAttachment]
    var senderId: String?
    var authorName: String?
    var isSelfMessage: Bool
    var providerTimestamp: String?
    var rowId: Int64
}

final class IMessageConnectionService: @unchecked Sendable {
    static let nativeConnectionId = AgentChannelConnection.nativeIMessageConnectionId
    static let updatesCursorRoomId = "__imessage_cursor__"
    static let spaceId = "imessage"
    static let maxInboundContentLength = 20_000

    static let shared = IMessageConnectionService(
        transport: IMessageConnectionService.makeDefaultTransport(),
        messageStore: AgentChannelMessageStore.shared
    )

    private let transport: any IMessageRPCTransport
    private let messageStore: AgentChannelMessageStore?
    private let activityCenter: AgentChannelInboundActivityCenter
    private let integrity: IMessageSystemIntegrityProbing

    /// Single-flight cache for `chats.list`. The imsg RPC server processes
    /// requests strictly sequentially, and a full listing over a large
    /// Messages database can take tens of seconds — if the settings sheet,
    /// destination pickers, and the receive poller each issued their own
    /// listing, they would queue behind one another on the helper process
    /// and time out intermittently. Every consumer shares one cached
    /// response instead, and concurrent callers await the same in-flight
    /// fetch.
    private let chatListLock = NSLock()
    private var cachedChatList: IMessageRPCResponse?
    private var chatListFetchedAt: Date?
    private var chatListTask: Task<IMessageRPCResponse, Error>?
    private static let chatListTTL: TimeInterval = 60
    /// Even a forced refresh (unresolved allowlisted chat) reuses a listing
    /// younger than this, so a chat that genuinely isn't in the recent-chats
    /// window can't make the poller hammer the helper.
    private static let chatListForcedRefreshFloor: TimeInterval = 15

    /// Last successfully probed capabilities. Synchronous policy code (the
    /// Agent Channel action-policy projection) reads bridge availability from
    /// here; every async probe refreshes it.
    private let capabilitiesLock = NSLock()
    private var lastProbedCapabilities: IMessageCapabilities = .empty

    /// Watch rows dropped this session because their chat is outside the
    /// readable allowlist. The stream covers every conversation in Messages,
    /// so per-row Activity records would leak other chats' identifiers and
    /// flood the ring — a session counter surfaced through receive health
    /// explains a "message arrived but nothing happened" Verify instead.
    private let watchStatsLock = NSLock()
    private var watchDroppedNonAllowlistedRows = 0

    init(
        transport: any IMessageRPCTransport,
        messageStore: AgentChannelMessageStore? = nil,
        activityCenter: AgentChannelInboundActivityCenter = .shared,
        integrity: IMessageSystemIntegrityProbing = IMessageSystemIntegrityProbe()
    ) {
        self.transport = transport
        self.messageStore = messageStore
        self.activityCenter = activityCenter
        self.integrity = integrity
    }

    private static func makeDefaultTransport() -> any IMessageRPCTransport {
        #if os(macOS)
            return IMessageProcessRPCClient()
        #else
            return IMessageUnavailableTransport()
        #endif
    }

    // MARK: - Configuration

    func configuration() -> IMessageConnectionConfiguration {
        IMessageConnectionConfigurationStore.load()
    }

    func saveConfiguration(_ configuration: IMessageConnectionConfiguration) throws {
        do {
            try IMessageConnectionConfigurationStore.save(configuration)
        } catch {
            throw IMessageConnectionServiceError.configurationSaveFailed(error.localizedDescription)
        }
    }

    // MARK: - Chat list cache

    /// Fetch (or reuse) the helper's recent-chats listing. `forceRefresh`
    /// lowers the acceptable cache age to the forced-refresh floor instead
    /// of bypassing the cache entirely.
    private func fetchChatList(forceRefresh: Bool = false) async throws -> IMessageRPCResponse {
        enum Action {
            case cached(IMessageRPCResponse)
            case awaited(Task<IMessageRPCResponse, Error>)
        }
        let maxAge = forceRefresh ? Self.chatListForcedRefreshFloor : Self.chatListTTL
        let action: Action = chatListLock.withLock {
            if let cached = cachedChatList, let fetchedAt = chatListFetchedAt,
                Date().timeIntervalSince(fetchedAt) < maxAge
            {
                return .cached(cached)
            }
            if let task = chatListTask { return .awaited(task) }
            let task = Task<IMessageRPCResponse, Error> { [weak self] in
                guard let self else {
                    throw IMessageConnectionServiceError.helper("service released")
                }
                defer { self.chatListLock.withLock { self.chatListTask = nil } }
                // First spawn opens chat.db; a large database needs more
                // than the default per-call timeout.
                let response = try await self.callHelper(
                    method: IMessageRPCMethod.listChats,
                    params: ["limit": 200],
                    timeout: 60
                )
                self.chatListLock.withLock {
                    self.cachedChatList = response
                    self.chatListFetchedAt = Date()
                }
                return response
            }
            chatListTask = task
            return .awaited(task)
        }
        switch action {
        case .cached(let response): return response
        case .awaited(let task): return try await task.value
        }
    }

    func helperAvailable() -> Bool {
        transport.isHelperAvailable()
    }

    // MARK: - Diagnostics

    func diagnostics() async -> IMessageConnectionDiagnostics {
        let config = configuration()
        let verification = IMessageRuntimeAssets.verifyBundledExecutable()
        let helperState: String
        switch verification {
        case .verified: helperState = "verified"
        case .overridden: helperState = "dev_override"
        case .missing: helperState = "missing"
        case .unpinned: helperState = "unpinned"
        case .digestMismatch: helperState = "digest_mismatch"
        }
        let capabilities = await probeAndCacheCapabilities()
        let fda = await SystemPermissionService.shared.cachedIsGranted(.disk)
        let automation = await SystemPermissionService.shared.cachedIsGranted(.automationMessages)
        let integritySnapshot = integrity.snapshot()

        var failures: [String] = []
        var notes: [String] = []
        if verification.trustedURL == nil {
            failures.append(
                "The iMessage helper is not usable (\(helperState)); download it from iMessage settings to enable basic and advanced iMessage actions."
            )
        }
        if !fda {
            failures.append(
                "Grant Full Disk Access so Osaurus can read the Messages database for iMessage receive/read."
            )
        }
        // imsg has no sign-in probe, so sign-in state is unknown rather than
        // asserted; sends fail with a helper error if Messages is signed out.
        notes.append(
            "Messages sign-in state cannot be probed; Messages.app must be signed in with an Apple Account for sends and receives to work."
        )
        if config.writeEnabled && !automation {
            failures.append(
                "Grant Messages Automation so Osaurus can send iMessages through Messages.app."
            )
        }
        if config.receivePollingEnabled && config.readableChatIds.isEmpty {
            failures.append("Add at least one readable iMessage chat for receive.")
        }
        if config.receivePollingEnabled && config.senderAllowlist.isEmpty {
            failures.append("Add at least one authorized iMessage sender for receive.")
        }
        if config.advancedActionsEnabled && !capabilities.bridgeAvailable {
            notes.append(
                "Advanced iMessage actions are enabled but the private-API bridge is not active. They will fall back to basic behavior or fail until SIP and Library Validation are disabled by the operator and the bridge injects into Messages.app."
            )
        }
        if config.advancedActionsEnabled {
            notes.append(
                "Advanced iMessage actions require SIP and system-wide Library Validation to be disabled. Osaurus never changes those protections; this is an operator-selected security tradeoff."
            )
        }

        let status: String
        if verification.trustedURL == nil {
            status = "helper_unavailable"
        } else if !fda {
            status = "needs_permissions"
        } else if config.writeEnabled {
            status = "connected_read_write"
        } else {
            status = "connected_read_only"
        }

        return IMessageConnectionDiagnostics(
            helperVerified: verification.trustedURL != nil,
            helperState: helperState,
            fullDiskAccess: fda,
            automationMessages: automation,
            messagesSignedIn: nil,
            bridgeAvailable: capabilities.bridgeAvailable,
            advancedActionsEnabled: config.advancedActionsEnabled,
            availableAdvancedMethods: capabilities.bridgeAvailable
                ? capabilities.rpcMethods.sorted() : [],
            enabledAdvancedActions: config.enabledAdvancedActions.map(\.rawValue),
            readableChatIds: config.readableChatIds,
            writableChatIds: config.writableChatIds,
            senderAllowlist: config.senderAllowlist,
            writeEnabled: config.writeEnabled,
            receiveStorageEnabled: config.receiveStorageEnabled,
            receivePollingEnabled: config.receivePollingEnabled,
            sipEnabled: integritySnapshot.sipEnabled,
            libraryValidationEnabled: integritySnapshot.libraryValidationEnabled,
            status: status,
            failures: failures,
            notes: notes
        )
    }

    func messageStoreDiagnostics() -> [String: Any] {
        [
            "enabled": messageStore != nil,
            "open": messageStore?.isOpen ?? false,
            "database_path": OsaurusPaths.agentChannelMessagesDatabaseFile().path,
            "message_dedupe": "connection_id + room_id + provider_message_id",
            "event_dedupe": "connection_id + provider_event_id",
            "cursor": "imsg chat.db ROWID stored in channel_receive_cursors",
            "transport_runtime": "imessage_watch",
        ]
    }

    /// Probe the helper and remember the result for synchronous readers.
    /// A failed probe (`probed == false`) does not clear a previous success,
    /// so a transient helper hiccup doesn't flap the advertised policies.
    private func probeAndCacheCapabilities() async -> IMessageCapabilities {
        let capabilities = await transport.probeCapabilities()
        if capabilities.probed {
            capabilitiesLock.withLock { lastProbedCapabilities = capabilities }
        }
        return capabilities
    }

    /// Bridge availability from the most recent successful probe, readable
    /// without spawning the helper. False until something has probed.
    func lastKnownBridgeAvailable() -> Bool {
        capabilitiesLock.withLock { lastProbedCapabilities.bridgeAvailable }
    }

    // MARK: - Discovery

    func listSpaces() -> [[String: Any]] {
        [["id": Self.spaceId, "name": "iMessage", "kind": "messaging_network"]]
    }

    func listChats() async throws -> [[String: Any]] {
        let config = configuration()
        guard transport.isHelperAvailable() else {
            return config.configuredChatIds.map { chatRow($0, config: config) }
        }
        do {
            let response = try await fetchChatList()
            let helperChats = response.array("chats")
            if helperChats.isEmpty {
                return config.configuredChatIds.map { chatRow($0, config: config) }
            }
            return helperChats.map { chat in
                // `guid` ("iMessage;-;+1555…") is the stable target our
                // allowlists store; `id` is the numeric chat.db row id.
                let id = (chat["guid"] as? String) ?? (chat["identifier"] as? String) ?? ""
                let name = (chat["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let contactName = (chat["contact_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return [
                    "id": id,
                    "name": name ?? contactName ?? id,
                    "kind": (chat["is_group"] as? Bool) == true ? "group" : "chat",
                    "read_allowed": config.canRead(chatId: id),
                    "write_allowed": config.canWrite(chatId: id),
                    "raw": chat,
                ]
            }
        } catch {
            return config.configuredChatIds.map { chatRow($0, config: config) }
        }
    }

    private func chatRow(_ chatId: String, config: IMessageConnectionConfiguration) -> [String: Any] {
        [
            "id": chatId,
            "name": chatId,
            "kind": "chat",
            "read_allowed": config.canRead(chatId: chatId),
            "write_allowed": config.canWrite(chatId: chatId),
        ]
    }

    // MARK: - Reads (local message store)

    func readChat(chatId: String, limit: Int?) throws -> [String: Any] {
        let config = configuration()
        let normalized = try requireReadableChat(chatId, config: config)
        let safeLimit = IMessageConnectionConfiguration.clampReadLimit(limit ?? config.defaultReadLimit)
        guard let messageStore else {
            throw IMessageConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()
        let rows = try messageStore.recentMessages(
            connectionId: Self.nativeConnectionId,
            roomId: normalized,
            limit: safeLimit
        )
        return [
            "kind": "imessage_stored_messages",
            "chat_id": normalized,
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
            throw IMessageConnectionServiceError.emptyMessage
        }
        let config = configuration()
        let candidateChats = IMessageConnectionConfiguration.normalizedIds(chatIds ?? config.readableChatIds)
        let allowedChats = candidateChats.filter { config.canRead(chatId: $0) }
        guard !allowedChats.isEmpty else {
            throw IMessageConnectionServiceError.chatNotReadable(candidateChats.first ?? "")
        }
        guard let messageStore else {
            throw IMessageConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()

        let safeLimit = IMessageConnectionConfiguration.clampReadLimit(limitPerChat ?? config.defaultReadLimit)
        let safeMaxMatches = min(max(maxMatches ?? 25, 1), 50)
        let needle = trimmedQuery.lowercased()
        var matches: [[String: Any]] = []

        for chatId in allowedChats {
            let rows = try messageStore.recentMessages(
                connectionId: Self.nativeConnectionId,
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
            "kind": "imessage_stored_message_search",
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
        let normalized = try requireWritableChat(chatId, config: config)
        let trimmed = try validateMessageContent(content)
        return [
            "kind": "imessage_message_draft",
            "chat_id": normalized,
            "content": trimmed,
            "requires_send_confirmation": true,
        ]
    }

    // MARK: - Writes (basic: Messages.app send)

    func sendMessage(chatId: String, content: String, confirmSend: Bool) async throws -> [String: Any] {
        guard confirmSend else { throw IMessageConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let normalized = try requireWritableChat(chatId, config: config)
        let text = try validateMessageContent(content)
        let chunks = AgentChannelMessageFormatter.plainTextChunks(text)
        guard !chunks.isEmpty else { throw IMessageConnectionServiceError.emptyMessage }
        guard chunks.count <= AgentChannelMessageFormatter.maxChunksPerSend else {
            throw IMessageConnectionServiceError.messageTooLong
        }
        var lastResult: [String: Any] = [:]
        for chunk in chunks {
            let response = try await callHelper(
                method: IMessageRPCMethod.send,
                params: ["chat_guid": normalized, "text": chunk]
            )
            lastResult = response.object()
        }
        recordOutbound(chatId: normalized, content: text, result: lastResult)
        var result: [String: Any] = [
            "kind": "imessage_message_sent",
            "chat_id": normalized,
            "delivery_status": "sent",
            "message": lastResult,
        ]
        if chunks.count > 1 { result["chunk_count"] = chunks.count }
        return result
    }

    // MARK: - Advanced (private-API, capability + enablement gated)

    func replyToMessage(
        chatId: String,
        messageId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        try await performAdvancedWrite(
            action: .reply,
            method: IMessageRPCMethod.sendRich,
            chatId: chatId,
            confirmSend: confirmSend
        ) { normalized in
            let text = try self.validateMessageContent(content)
            return ["chat_guid": normalized, "reply_to": messageId, "text": text]
        }
    }

    func editMessage(
        chatId: String,
        messageId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        try await performAdvancedWrite(
            action: .edit,
            method: IMessageRPCMethod.edit,
            chatId: chatId,
            confirmSend: confirmSend
        ) { normalized in
            let text = try self.validateMessageContent(content)
            return ["chat_guid": normalized, "message_id": messageId, "text": text]
        }
    }

    func unsendMessage(
        chatId: String,
        messageId: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        try await performAdvancedWrite(
            action: .unsend,
            method: IMessageRPCMethod.unsend,
            chatId: chatId,
            confirmSend: confirmSend
        ) { normalized in
            ["chat_guid": normalized, "message_id": messageId]
        }
    }

    func setTapback(
        chatId: String,
        messageId: String,
        reaction: String,
        adding: Bool,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        // The helper only accepts the six canonical tapback kinds
        // (love|like|dislike|laugh|emphasize|question); agents pass emoji or
        // aliases, so normalize before calling and fail with a typed error
        // instead of the helper's opaque "unsupported tapback reaction".
        guard let kind = AgentChannelReactionNormalizer.imessageTapbackKind(reaction) else {
            throw IMessageConnectionServiceError.invalidAdvancedParameter(
                "reaction \"\(reaction)\" has no iMessage tapback equivalent; use one of: "
                    + AgentChannelReactionNormalizer.imessageTapbackKinds.sorted().joined(separator: ", ")
            )
        }
        return try await performAdvancedWrite(
            action: .tapback,
            method: IMessageRPCMethod.tapback,
            chatId: chatId,
            confirmSend: confirmSend
        ) { normalized in
            // Upstream removes a tapback via `remove: true` (or a
            // "remove-" reaction prefix), not an `adding` flag.
            ["chat_guid": normalized, "message_id": messageId, "reaction": kind, "remove": !adding]
        }
    }

    func sendTyping(chatId: String, confirmSend: Bool) async throws -> [String: Any] {
        try await performAdvancedWrite(
            action: .typing,
            method: IMessageRPCMethod.typing,
            chatId: chatId,
            confirmSend: confirmSend
        ) { normalized in
            ["chat_guid": normalized, "typing": true]
        }
    }

    func sendAttachment(
        chatId: String,
        path: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let config = configuration()
        guard config.isAttachmentPathAllowed(path) else {
            throw IMessageConnectionServiceError.attachmentNotAllowed(path)
        }
        return try await performAdvancedWrite(
            action: .sendAttachment,
            method: IMessageRPCMethod.sendAttachment,
            chatId: chatId,
            confirmSend: confirmSend
        ) { normalized in
            ["chat_guid": normalized, "file": path]
        }
    }

    func sendEffect(
        chatId: String,
        content: String,
        effect: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let effectName = effect.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !effectName.isEmpty else {
            throw IMessageConnectionServiceError.invalidAdvancedParameter("effect must not be empty")
        }
        return try await performAdvancedWrite(
            action: .sendEffect,
            method: IMessageRPCMethod.sendRich,
            chatId: chatId,
            confirmSend: confirmSend
        ) { normalized in
            let text = try self.validateMessageContent(content)
            // Upstream expands short effect names ("slam") to full
            // com.apple.MobileSMS.expressivesend identifiers.
            return ["chat_guid": normalized, "text": text, "effect_id": effectName]
        }
    }

    static let pollOptionRange = 2 ... 12

    func createPoll(
        chatId: String,
        question: String,
        options: [String],
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            throw IMessageConnectionServiceError.invalidAdvancedParameter("poll question must not be empty")
        }
        let trimmedOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard Self.pollOptionRange.contains(trimmedOptions.count) else {
            throw IMessageConnectionServiceError.invalidAdvancedParameter(
                "polls need \(Self.pollOptionRange.lowerBound)-\(Self.pollOptionRange.upperBound) non-empty options"
            )
        }
        return try await performAdvancedWrite(
            action: .poll,
            method: IMessageRPCMethod.poll,
            chatId: chatId,
            confirmSend: confirmSend
        ) { normalized in
            ["chat_guid": normalized, "question": trimmedQuestion, "options": trimmedOptions]
        }
    }

    enum GroupOperation: String, CaseIterable, Sendable {
        case rename
        case addParticipant = "add_participant"
        case removeParticipant = "remove_participant"
    }

    func manageGroup(
        chatId: String,
        operation: GroupOperation,
        value: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw IMessageConnectionServiceError.invalidAdvancedParameter(
                "group \(operation.rawValue) needs a non-empty value"
            )
        }
        // Upstream exposes one method per group operation instead of a
        // single mutation method with an `operation` discriminator.
        let method: String
        switch operation {
        case .rename: method = IMessageRPCMethod.groupRename
        case .addParticipant: method = IMessageRPCMethod.groupAddParticipant
        case .removeParticipant: method = IMessageRPCMethod.groupRemoveParticipant
        }
        return try await performAdvancedWrite(
            action: .groupManagement,
            method: method,
            chatId: chatId,
            confirmSend: confirmSend
        ) { normalized in
            switch operation {
            case .rename:
                return ["chat_guid": normalized, "name": trimmedValue]
            case .addParticipant, .removeParticipant:
                return [
                    "chat_guid": normalized,
                    "address": IMessageConnectionConfiguration.normalizedId(trimmedValue),
                ]
            }
        }
    }

    private func performAdvancedWrite(
        action: IMessageConnectionConfiguration.AdvancedAction,
        method: String,
        chatId: String,
        confirmSend: Bool,
        buildParams: (String) throws -> [String: any Sendable]
    ) async throws -> [String: Any] {
        guard confirmSend else { throw IMessageConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        guard config.isAdvancedActionEnabled(action) else {
            throw IMessageConnectionServiceError.advancedActionDisabled(action.rawValue)
        }
        let normalized = try requireWritableChat(chatId, config: config)
        let capabilities = await probeAndCacheCapabilities()
        guard capabilities.supportsAdvanced(method) else {
            throw IMessageConnectionServiceError.advancedActionUnavailable(action.rawValue)
        }
        let params = try buildParams(normalized)
        let response = try await callHelper(method: method, params: params)
        return [
            "kind": "imessage_\(action.rawValue)",
            "chat_id": normalized,
            "delivery_status": "sent",
            "result": response.object(),
        ]
    }

    // MARK: - Receive (watch stream)

    /// Row skipped without ingesting; surfaced in Activity unless it is an
    /// expected decoration (reaction rows).
    static let watchSkipReason = "imessage_row_not_ingestible"

    /// Run one live receive session against the helper's `watch.subscribe`
    /// stream. An existing cursor is passed as `since_rowid`, so rows that
    /// arrived while receive was down are backfilled instead of lost; with no
    /// cursor the watcher starts "from now", so enabling the channel never
    /// replays old conversations into agents.
    ///
    /// Returns normally only when the surrounding task is cancelled (receive
    /// stopped); throws when the subscription cannot be established or the
    /// helper dies mid-session. The caller (transport runtime) owns restart
    /// backoff.
    func runWatchSession(
        onReady: @escaping @Sendable () async -> Void,
        onBatch: @escaping @Sendable (AgentChannelReceiveBatchSummary) async -> Void
    ) async throws {
        guard let messageStore else {
            throw IMessageConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()
        let config = configuration()
        guard config.canStartReceive() else { return }
        let cursor = try messageStore.cursor(
            connectionId: Self.nativeConnectionId,
            roomId: Self.updatesCursorRoomId
        )

        let (notifications, continuation) = AsyncStream.makeStream(
            of: (method: String, paramsJSON: Data).self
        )
        await transport.setNotificationHandler { method, paramsJSON in
            continuation.yield((method, paramsJSON))
        }
        defer {
            continuation.finish()
            let transport = self.transport
            Task { await transport.setNotificationHandler(nil) }
        }

        var params: [String: any Sendable] = [:]
        if config.attachmentIngestionEnabled { params["attachments"] = true }
        if let sinceRowId = cursor.flatMap(Int64.init) {
            params["since_rowid"] = sinceRowId
        }
        // First subscribe can be slow: spawning the helper opens chat.db.
        let subscribed = try await callHelper(
            method: IMessageRPCMethod.watchSubscribe,
            params: params,
            timeout: 60
        )
        let subscriptionId = subscribed.object()["subscription"] as? Int
        await onReady()

        var sessionError: Error?
        for await (method, paramsJSON) in notifications {
            if Task.isCancelled { break }
            switch method {
            case IMessageRPCNotification.message:
                guard
                    let object = (try? JSONSerialization.jsonObject(with: paramsJSON))
                        as? [String: Any],
                    let payload = object["message"] as? [String: Any]
                else { continue }
                let summary = try await handleWatchEvent(payload)
                await onBatch(summary)
            case IMessageRPCNotification.error:
                let object = (try? JSONSerialization.jsonObject(with: paramsJSON)) as? [String: Any]
                let detail =
                    ((object?["error"] as? [String: Any])?["message"] as? String)
                    ?? "unknown watch error"
                sessionError = IMessageConnectionServiceError.helper(
                    "The iMessage watch stream failed: \(IMessageRPCSecurity.redact(detail))"
                )
            case IMessageRPCNotification.helperTerminated:
                sessionError = IMessageConnectionServiceError.helper(
                    "The iMessage helper exited during receive."
                )
            default:
                continue
            }
            if sessionError != nil { break }
        }

        if Task.isCancelled {
            // Graceful stop: drop the subscription so the helper stops
            // scanning chat.db on our behalf.
            if let subscriptionId {
                _ = try? await callHelper(
                    method: IMessageRPCMethod.watchUnsubscribe,
                    params: ["subscription": subscriptionId],
                    timeout: 5
                )
            }
            return
        }
        throw sessionError
            ?? IMessageConnectionServiceError.helper(
                "The iMessage watch stream ended unexpectedly."
            )
    }

    /// Process one watch `message` notification payload: filter to
    /// allowlisted chats, normalize, authorize, record, dispatch, and advance
    /// the global chat.db rowid cursor. The cursor is persisted only after
    /// the row has been recorded (or explicitly skipped), so a crash
    /// redelivers rows instead of losing them; provider-event-id dedupe makes
    /// redelivery harmless.
    @discardableResult
    func handleWatchEvent(_ payload: [String: Any]) async throws -> AgentChannelReceiveBatchSummary {
        guard let messageStore else {
            throw IMessageConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()
        // Re-read configuration per event so allowlist and toggle edits
        // apply to a running session without an app restart.
        let config = configuration()
        let empty = AgentChannelReceiveBatchSummary(
            received: 0, stored: 0, dispatchAttempted: 0, dispatchSuppressed: 0
        )
        guard config.canStartReceive() else { return empty }
        let rowId = (payload["id"] as? Int64) ?? (payload["id"] as? Int).map(Int64.init) ?? 0

        // The watch stream covers every chat in Messages; rows from chats
        // outside the read allowlist are dropped before authorization so
        // non-allowlisted conversations never reach storage or Activity.
        let chatGuid = (payload["chat_guid"] as? String)
            ?? (payload["chat_identifier"] as? String) ?? ""
        let roomId = IMessageConnectionConfiguration.normalizedId(chatGuid)
        guard !roomId.isEmpty, config.canRead(chatId: roomId) else {
            watchStatsLock.withLock { watchDroppedNonAllowlistedRows += 1 }
            try advanceReceiveCursor(to: rowId, messageStore: messageStore)
            return empty
        }

        guard let event = normalizeInbound(payload, config: config) else {
            // Reactions, empty rows, and oversize content are not
            // conversation events. Advance the cursor past them so a
            // reconnect's since-rowid backfill never replays them, and record
            // non-reaction skips so they stay visible in Activity.
            if let guid = (payload["guid"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
                !guid.isEmpty,
                (payload["is_reaction"] as? Bool) != true
            {
                await activityCenter.record(
                    connectionId: Self.nativeConnectionId,
                    providerEventId: guid,
                    stage: .rejected,
                    reason: Self.watchSkipReason
                )
            }
            try advanceReceiveCursor(to: rowId, messageStore: messageStore)
            return empty
        }

        let summary = try await ingest(events: [event], config: config, messageStore: messageStore)
        try advanceReceiveCursor(to: max(rowId, event.rowId), messageStore: messageStore)
        return summary
    }

    /// Monotonically advance the global chat.db rowid receive cursor.
    private func advanceReceiveCursor(
        to rowId: Int64,
        messageStore: AgentChannelMessageStore
    ) throws {
        guard rowId > 0 else { return }
        let current = try messageStore.cursor(
            connectionId: Self.nativeConnectionId,
            roomId: Self.updatesCursorRoomId
        ).flatMap(Int64.init) ?? 0
        guard rowId > current else { return }
        try messageStore.upsertCursor(
            connectionId: Self.nativeConnectionId,
            roomId: Self.updatesCursorRoomId,
            cursor: String(rowId)
        )
    }

    /// Rows dropped this session because their chat was not in the readable
    /// allowlist. Read by the receive runtime to annotate health state.
    func watchDroppedNonAllowlistedCount() -> Int {
        watchStatsLock.withLock { watchDroppedNonAllowlistedRows }
    }

    /// Kill the helper child process (if any). Called when receive stops or
    /// the app exits so no orphaned `imsg rpc` process keeps watching
    /// chat.db.
    func shutdownTransport() async {
        await transport.shutdown()
    }

    private func ingest(
        events: [IMessageNormalizedInboundEvent],
        config: IMessageConnectionConfiguration,
        messageStore: AgentChannelMessageStore
    ) async throws -> AgentChannelReceiveBatchSummary {
        var inserted = 0
        var dispatchAttempted = 0
        var dispatchSuppressed = 0
        let authorizationService = AgentChannelConnectionService(
            discordService: .shared,
            imessageService: self
        )

        for event in events {
            await activityCenter.record(
                connectionId: Self.nativeConnectionId,
                providerEventId: event.providerEventId,
                stage: .received
            )
            let authorization = try authorizationService.authorizeInboundMessage(
                AgentChannelInboundMessageAuthorizationRequest(
                    connectionId: Self.nativeConnectionId,
                    providerEventId: event.providerEventId,
                    providerMessageId: event.providerMessageId,
                    spaceId: Self.spaceId,
                    roomId: event.roomId,
                    senderId: event.senderId,
                    isBotMessage: false,
                    isSelfMessage: event.isSelfMessage
                ),
                messageStore: messageStore
            )
            let receive = try messageStore.recordReceiveEvent(
                connectionId: Self.nativeConnectionId,
                providerEventId: event.providerEventId,
                authorization: authorization,
                message: Self.storedMessage(event)
            )
            if receive.messageInserted { inserted += 1 }
            if receive.disposition == .accepted {
                await activityCenter.record(
                    connectionId: Self.nativeConnectionId,
                    providerEventId: event.providerEventId,
                    stage: .stored
                )
                let submission = await relayInboundEvent(event, config: config)
                dispatchAttempted += submission.dispatchAttempted
                dispatchSuppressed += submission.dispatchSuppressed
                switch submission {
                case .dispatched(let agentId, let rule):
                    await activityCenter.record(
                        connectionId: Self.nativeConnectionId,
                        providerEventId: event.providerEventId,
                        stage: .dispatched,
                        reason: await AgentChannelInboundActivityPresentation.dispatchReason(
                            agentId: agentId,
                            rule: rule
                        )
                    )
                case .suppressed(let reason):
                    await activityCenter.record(
                        connectionId: Self.nativeConnectionId,
                        providerEventId: event.providerEventId,
                        stage: .dispatchSuppressed,
                        reason: reason
                    )
                }
            } else {
                await activityCenter.record(
                    connectionId: Self.nativeConnectionId,
                    providerEventId: event.providerEventId,
                    stage: .rejected,
                    reason: receive.authorizationReason
                )
            }
        }

        // Cursor advancement is owned by `handleWatchEvent`, which persists
        // it only after the event has been authorized and recorded here.
        return AgentChannelReceiveBatchSummary(
            received: events.count,
            stored: inserted,
            dispatchAttempted: dispatchAttempted,
            dispatchSuppressed: dispatchSuppressed
        )
    }

    private func relayInboundEvent(
        _ event: IMessageNormalizedInboundEvent,
        config: IMessageConnectionConfiguration
    ) async -> AgentChannelInboundRelaySubmission {
        let settings = config.inboundDispatch
        guard settings.isConfigured else {
            return .suppressed("inbound_dispatch_not_configured")
        }
        guard !settings.requireMention else {
            return .suppressed("imessage_mention_detection_unavailable")
        }
        guard let senderId = event.senderId else {
            return .suppressed("inbound_sender_missing")
        }
        let identity = ChannelIdentity(
            kind: .imessage,
            installationId: Self.nativeConnectionId,
            groupId: event.roomId,
            sender: ChannelSenderMetadata(senderId: senderId, displayName: event.authorName),
            trustLevel: .verified
        )
        let responder: AgentChannelInboundReplyHandler?
        if settings.autoReplyEnabled {
            responder = { [weak self] reply in
                guard let self else {
                    throw IMessageConnectionServiceError.helper(
                        "iMessage connection was released before replying."
                    )
                }
                _ = try await self.sendMessage(
                    chatId: event.roomId,
                    content: reply,
                    confirmSend: true
                )
            }
        } else {
            responder = nil
        }
        return await AgentChannelInboundRelay.shared.submit(
            AgentChannelInboundRelayRequest(
                identity: identity,
                connectionId: Self.nativeConnectionId,
                providerEventId: event.providerEventId,
                providerRoute: AgentChannelProviderRoute(
                    conversationId: event.roomId,
                    displayName: "iMessage \(event.roomId)"
                ),
                content: event.content,
                attachments: event.attachments,
                settings: settings,
                sourceLabel: "iMessage chat \(event.roomId), sender \(senderId)",
                reply: responder
            )
        )
    }

    // MARK: - Normalization

    private func normalizeInbound(
        _ row: [String: Any],
        config: IMessageConnectionConfiguration
    ) -> IMessageNormalizedInboundEvent? {
        guard let guid = (row["guid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !guid.isEmpty
        else { return nil }
        // Tapback/reaction events come through as message rows too; their
        // text is decoration ("Loved …"), not conversation content.
        if (row["is_reaction"] as? Bool) == true { return nil }
        // Upstream `MessagePayload`: `id` is the chat.db message rowid.
        let rowId = (row["id"] as? Int64)
            ?? (row["id"] as? Int).map(Int64.init)
            ?? 0
        guard let chatGuid = (row["chat_guid"] as? String) ?? (row["chat_identifier"] as? String)
        else { return nil }
        let roomId = IMessageConnectionConfiguration.normalizedId(chatGuid)
        // iMessage rows include the local account's own sent messages; the
        // helper marks them is_from_me. Only self-messages get a nil senderId
        // fallback of the local handle.
        let isFromMe = (row["is_from_me"] as? Bool) ?? false
        let senderId = (row["sender"] as? String).map(IMessageConnectionConfiguration.normalizedId)
        let content = (row["text"] as? String) ?? ""
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Attachment-only messages carry empty text but real attachments.
        let attachments = normalizeAttachments(row["attachments"], config: config)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }
        guard trimmed.utf16.count <= Self.maxInboundContentLength else { return nil }

        return IMessageNormalizedInboundEvent(
            providerEventId: guid,
            roomId: roomId,
            providerMessageId: guid,
            content: trimmed,
            attachments: attachments,
            senderId: senderId,
            authorName: row["sender_name"] as? String,
            isSelfMessage: isFromMe,
            providerTimestamp: row["created_at"] as? String,
            rowId: rowId
        )
    }

    private func normalizeAttachments(
        _ raw: Any?,
        config: IMessageConnectionConfiguration
    ) -> [AgentChannelStoredAttachment] {
        guard config.attachmentIngestionEnabled, let entries = raw as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            // Upstream `AttachmentPayload`: `original_path` is the on-disk
            // location, `filename` the display name, `total_bytes` the size.
            let path = (entry["original_path"] as? String) ?? (entry["filename"] as? String) ?? ""
            let sizeBytes = (entry["total_bytes"] as? Int) ?? 0
            // Fence: only ingest attachments under an allowlisted root and
            // within the size cap.
            guard config.isAttachmentPathAllowed(path), sizeBytes <= config.maxAttachmentBytes else {
                return nil
            }
            return AgentChannelStoredAttachment(
                providerId: path,
                kind: Self.attachmentKind(entry["mime_type"] as? String),
                filename: (entry["transfer_name"] as? String)
                    ?? (path as NSString).lastPathComponent,
                contentType: entry["mime_type"] as? String,
                sizeBytes: sizeBytes
            )
        }
    }

    private static func attachmentKind(_ mime: String?) -> AgentChannelStoredAttachmentKind {
        guard let mime = mime?.lowercased() else { return .file }
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        return .file
    }

    // MARK: - Helper invocation

    private func callHelper(
        method: String,
        params: [String: any Sendable],
        timeout: TimeInterval = 15
    ) async throws -> IMessageRPCResponse {
        do {
            return try await transport.call(method: method, params: params, timeout: timeout)
        } catch let error as IMessageRPCError {
            throw IMessageConnectionServiceError.helper(error.localizedDescription)
        }
    }

    private func recordOutbound(chatId: String, content: String, result: [String: Any]) {
        guard let messageStore else { return }
        let providerMessageId = (result["guid"] as? String)
            ?? (result["message_id"] as? String)
            ?? UUID().uuidString
        let message = AgentChannelStoredMessage(
            connectionId: Self.nativeConnectionId,
            roomId: chatId,
            providerMessageId: providerMessageId,
            direction: .outbound,
            content: content,
            providerTimestamp: ISO8601DateFormatter().string(from: Date())
        )
        Task.detached(priority: .utility) {
            do {
                try messageStore.openIfNeeded()
                _ = try messageStore.recordMessages([message])
            } catch {
                NSLog("[iMessage] Failed to record outbound message: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Validation

    private func requireReadableChat(
        _ chatId: String,
        config: IMessageConnectionConfiguration
    ) throws -> String {
        let normalized = try requireChatId(chatId)
        guard config.canRead(chatId: normalized) else {
            throw IMessageConnectionServiceError.chatNotReadable(normalized)
        }
        return normalized
    }

    private func requireWritableChat(
        _ chatId: String,
        config: IMessageConnectionConfiguration
    ) throws -> String {
        let normalized = try requireChatId(chatId)
        guard config.writeEnabled else {
            throw IMessageConnectionServiceError.writeDisabled
        }
        guard config.canWrite(chatId: normalized) else {
            throw IMessageConnectionServiceError.chatNotWritable(normalized)
        }
        return normalized
    }

    private func requireChatId(_ chatId: String) throws -> String {
        let normalized = IMessageConnectionConfiguration.normalizedId(chatId)
        guard IMessageConnectionConfiguration.isValidChatId(normalized) else {
            throw IMessageConnectionServiceError.invalidChatId(chatId)
        }
        return normalized
    }

    private func validateMessageContent(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IMessageConnectionServiceError.emptyMessage
        }
        let maxInput = AgentChannelMessageFormatter.plainTextChunkLimit
            * AgentChannelMessageFormatter.maxChunksPerSend
        guard trimmed.utf16.count <= maxInput else {
            throw IMessageConnectionServiceError.messageTooLong
        }
        return trimmed
    }

    private static func storedMessage(_ event: IMessageNormalizedInboundEvent) -> AgentChannelStoredMessage {
        AgentChannelStoredMessage(
            connectionId: nativeConnectionId,
            roomId: event.roomId,
            providerMessageId: event.providerMessageId,
            direction: .inbound,
            authorId: event.senderId,
            authorName: event.authorName,
            content: event.content,
            attachments: event.attachments,
            providerTimestamp: event.providerTimestamp
        )
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
            "attachments": message.attachments.map { attachment in
                [
                    "id": attachment.providerId,
                    "kind": attachment.kind.rawValue,
                    "filename": attachment.filename ?? "",
                    "content_type": attachment.contentType ?? "",
                    "size": attachment.sizeBytes ?? 0,
                ]
            },
        ]
    }
}

/// Small provider-neutral receive summary so the transport runtime can report
/// counts without depending on a provider-specific batch type.
struct AgentChannelReceiveBatchSummary: Equatable, Sendable {
    var received: Int
    var stored: Int
    var dispatchAttempted: Int
    var dispatchSuppressed: Int
}

#if !os(macOS)
    /// Non-macOS placeholder so the package still compiles; iMessage is a
    /// macOS-only channel.
    struct IMessageUnavailableTransport: IMessageRPCTransport {
        func call(method: String, params: [String: any Sendable], timeout: TimeInterval) async throws
            -> IMessageRPCResponse
        {
            throw IMessageRPCError.helperUnavailable("iMessage is only available on macOS")
        }
        func probeCapabilities() async -> IMessageCapabilities { .empty }
        func isHelperAvailable() -> Bool { false }
        func setNotificationHandler(
            _ handler: (@Sendable (_ method: String, _ paramsJSON: Data) -> Void)?
        ) async {}
        func shutdown() async {}
    }
#endif
