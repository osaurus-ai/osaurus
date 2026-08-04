//
//  WhatsAppConnectionService.swift
//  osaurus
//
//  Policy, normalization, QR pairing, and receive/dispatch for the native
//  WhatsApp channel. All provider I/O goes through the local `osaurus-wa`
//  helper (a whatsmeow WhatsApp Web bridge linked to the user's own account
//  by QR code) over newline-framed JSON-RPC — no webhooks, no relay tunnel,
//  no Meta Business account.
//

import Foundation

/// Method names the `osaurus-wa` helper exposes over JSON-RPC. These are
/// part of the helper contract (`rpcMethods` in helpers/osaurus-wa/main.go);
/// the helper advertises the list through `status`.
enum WhatsAppRPCMethod {
    static let status = "status"
    static let loginStart = "login.start"
    static let loginCancel = "login.cancel"
    static let loginPasskeyResponse = "login.passkey_response"
    static let loginPasskeyConfirm = "login.passkey_confirm"
    static let logout = "logout"
    static let listChats = "chats.list"
    static let send = "send"
    static let sendAttachment = "send.attachment"
    static let messageEdit = "message.edit"
    static let messageRevoke = "message.revoke"
    static let react = "react"
    static let typing = "typing"
    static let read = "read"
    static let watchSubscribe = "watch.subscribe"
}

struct WhatsAppConnectionDiagnostics: Equatable, Sendable {
    let helperVerified: Bool
    let helperState: String
    let helperVersion: String?
    let linked: Bool
    let selfNumber: String?
    let readableChatIds: [String]
    let writableChatIds: [String]
    let senderAllowlist: [String]
    let writeEnabled: Bool
    let receiveEnabled: Bool
    let status: String
    let failures: [String]
    let notes: [String]

    var receiveReady: Bool {
        helperVerified
            && linked
            && receiveEnabled
            && !readableChatIds.isEmpty
            && !senderAllowlist.isEmpty
    }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "helper_verified": helperVerified,
            "helper_state": helperState,
            "helper_version": helperVersion ?? "",
            "linked": linked,
            "self_number": selfNumber ?? "",
            "receive_ready": receiveReady,
            "readable_chat_ids": readableChatIds,
            "writable_chat_ids": writableChatIds,
            "sender_allowlist": senderAllowlist,
            "write_enabled": writeEnabled,
            "receive_enabled": receiveEnabled,
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
        return result
    }
}

enum WhatsAppConnectionServiceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case notLinked
    case invalidChatId(String)
    case chatNotReadable(String)
    case chatNotWritable(String)
    case writeDisabled
    case sendConfirmationRequired
    case messageTooLong
    case emptyMessage
    case messageStoreUnavailable
    case configurationSaveFailed(String)
    case pairingAlreadyActive
    case attachmentNotAllowed(String)
    case attachmentTooLarge(Int)
    case invalidThreadId(String)
    case helper(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "WhatsApp is not configured. Link an account and allowlist at least one chat."
        case .notLinked:
            return "No WhatsApp account is linked. Scan the QR code in WhatsApp settings first."
        case .invalidChatId(let chatId):
            return "`\(chatId)` is not a valid WhatsApp chat id (phone number or JID)."
        case .chatNotReadable(let chatId):
            return "WhatsApp chat `\(chatId)` is not allowlisted for read access."
        case .chatNotWritable(let chatId):
            return "WhatsApp chat `\(chatId)` is not allowlisted for write access."
        case .writeDisabled:
            return "WhatsApp write access is disabled in settings."
        case .sendConfirmationRequired:
            return "`confirm_send` must be true before Osaurus sends a WhatsApp message."
        case .messageTooLong:
            return "WhatsApp message content is too long, even after splitting into multiple messages."
        case .emptyMessage:
            return "WhatsApp message content must not be empty."
        case .messageStoreUnavailable:
            return "WhatsApp message store is unavailable."
        case .configurationSaveFailed(let message):
            return "WhatsApp configuration could not be saved: \(message)"
        case .pairingAlreadyActive:
            return "A WhatsApp QR pairing session is already in progress."
        case .attachmentNotAllowed(let path):
            return
                "Attachment path `\(WhatsAppRPCSecurity.redact(path))` is not inside an allowlisted attachment root (or attachment support is disabled)."
        case .attachmentTooLarge(let maxBytes):
            return "Attachment exceeds the configured limit of \(maxBytes) bytes."
        case .invalidThreadId(let threadId):
            return
                "`\(threadId)` is not a WhatsApp thread id. Use `<chat_id>:<message_id>` of the message to quote (see `reply_thread_id` on read results)."
        case .helper(let message):
            return WhatsAppRPCSecurity.redact(message)
        }
    }
}

/// One inbound WhatsApp message normalized into an Agent Channel event.
struct WhatsAppNormalizedInboundEvent: Equatable, Sendable {
    var providerEventId: String
    var roomId: String
    var providerMessageId: String
    var content: String
    var senderId: String?
    var authorName: String?
    var isSelfMessage: Bool
    var isGroup: Bool
    var mentionsSelf: Bool
    var providerTimestamp: String?
    /// Downloaded media, when attachment ingestion is on and the helper
    /// managed to fetch the payload.
    var attachments: [AgentChannelStoredAttachment] = []
    /// Quoted-reply metadata (WhatsApp "reply") when the message quotes
    /// another one.
    var quotedMessageId: String?
    var quotedSenderId: String?
    var quotedText: String?
}

/// Terminal + intermediate events of one QR pairing session, streamed to the
/// settings UI.
enum WhatsAppPairingEvent: Equatable, Sendable {
    /// A fresh QR code string to render (codes rotate roughly every 20s).
    case qr(code: String)
    /// WhatsApp's passkey linking gate fired after the scan: the account
    /// needs a WebAuthn assertion. The payload is the JSON-encoded request
    /// options; answer with `submitPasskeyResponse(_:)`.
    case passkeyChallenge(publicKeyJSON: String)
    /// The passkey exchange produced a verification code the user must
    /// match against their phone; answer with `confirmPasskeyCode()`.
    case passkeyCode(code: String)
    case success(selfNumber: String?)
    case timeout
    case failed(String)
}

final class WhatsAppConnectionService: @unchecked Sendable {
    static let nativeConnectionId = AgentChannelConnection.nativeWhatsAppConnectionId
    static let spaceId = "whatsapp"
    static let maxInboundContentLength = 20_000

    static let shared = WhatsAppConnectionService(
        transport: WhatsAppConnectionService.makeDefaultTransport(),
        messageStore: AgentChannelMessageStore.shared
    )

    private let transport: any WhatsAppRPCTransport
    private let messageStore: AgentChannelMessageStore?
    private let activityCenter: AgentChannelInboundActivityCenter

    /// Last successfully probed link status. Synchronous policy code and the
    /// transport supervisor read from here; every async probe refreshes it.
    private let linkStatusLock = NSLock()
    private var lastProbedLinkStatus: WhatsAppLinkStatus = .empty

    /// Serializes pairing sessions (one at a time).
    private let pairingLock = NSLock()
    private var pairingActive = false

    /// Watch rows dropped this session because their chat is outside the
    /// readable allowlist (the stream covers every conversation).
    private let watchStatsLock = NSLock()
    private var watchDroppedNonAllowlistedRows = 0

    init(
        transport: any WhatsAppRPCTransport,
        messageStore: AgentChannelMessageStore? = nil,
        activityCenter: AgentChannelInboundActivityCenter = .shared
    ) {
        self.transport = transport
        self.messageStore = messageStore
        self.activityCenter = activityCenter
    }

    private static func makeDefaultTransport() -> any WhatsAppRPCTransport {
        #if os(macOS)
            return WhatsAppProcessRPCClient()
        #else
            return WhatsAppUnavailableTransport()
        #endif
    }

    // MARK: - Configuration

    func configuration() -> WhatsAppConnectionConfiguration {
        WhatsAppConnectionConfigurationStore.load()
    }

    func saveConfiguration(_ configuration: WhatsAppConnectionConfiguration) throws {
        do {
            try WhatsAppConnectionConfigurationStore.save(configuration)
        } catch {
            throw WhatsAppConnectionServiceError.configurationSaveFailed(error.localizedDescription)
        }
    }

    func helperAvailable() -> Bool {
        transport.isHelperAvailable()
    }

    // MARK: - Link status

    /// Probe the helper's link status and remember the result for
    /// synchronous readers. A failed probe does not clear a previous
    /// success, so a transient helper hiccup doesn't flap policies.
    @discardableResult
    func probeAndCacheLinkStatus() async -> WhatsAppLinkStatus {
        let status = await transport.probeLinkStatus()
        if status.probed {
            linkStatusLock.withLock { lastProbedLinkStatus = status }
        }
        return status
    }

    /// Link status from the most recent successful probe, readable without
    /// spawning the helper. `.empty` until something has probed.
    func lastKnownLinkStatus() -> WhatsAppLinkStatus {
        linkStatusLock.withLock { lastProbedLinkStatus }
    }

    /// Blocking availability probe for the credential-availability cache:
    /// helper present AND a linked session in the store. Must not run on
    /// the main thread (it spawns the status CLI).
    func helperLinkedBlockingProbe() -> Bool {
        guard helperAvailable() else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        let box = WhatsAppLinkStatusBox()
        let transport = self.transport
        Task.detached(priority: .utility) {
            let status = await transport.probeLinkStatus()
            box.set(status)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
        let status = box.get()
        if status.probed {
            linkStatusLock.withLock { lastProbedLinkStatus = status }
        }
        return status.linked
    }

    // MARK: - Pairing (QR login)

    /// Begin a QR pairing session. Returns a stream of pairing events; the
    /// stream finishes after a terminal event (success / timeout / failure)
    /// or when `cancelPairing()` is called. Only one session runs at a time.
    func startPairing() async throws -> AsyncStream<WhatsAppPairingEvent> {
        let acquired = pairingLock.withLock { () -> Bool in
            guard !pairingActive else { return false }
            pairingActive = true
            return true
        }
        guard acquired else { throw WhatsAppConnectionServiceError.pairingAlreadyActive }

        let (stream, continuation) = AsyncStream.makeStream(of: WhatsAppPairingEvent.self)
        await transport.setNotificationHandler { [weak self] method, paramsJSON in
            guard let self else { return }
            let params = (try? JSONSerialization.jsonObject(with: paramsJSON)) as? [String: Any] ?? [:]
            switch method {
            case WhatsAppRPCNotification.qr:
                if let code = params["code"] as? String, !code.isEmpty {
                    continuation.yield(.qr(code: code))
                }
            case WhatsAppRPCNotification.passkey:
                // Non-terminal: the pairing session stays open while the
                // user completes the WebAuthn round-trip.
                switch params["stage"] as? String {
                case "challenge":
                    if let publicKey = params["public_key_json"] as? String, !publicKey.isEmpty {
                        continuation.yield(.passkeyChallenge(publicKeyJSON: publicKey))
                    }
                case "confirm":
                    if let code = params["code"] as? String, !code.isEmpty {
                        continuation.yield(.passkeyCode(code: code))
                    }
                default:
                    break
                }
            case WhatsAppRPCNotification.login:
                switch params["status"] as? String {
                case "success":
                    continuation.yield(.success(selfNumber: params["self_number"] as? String))
                case "timeout":
                    continuation.yield(.timeout)
                default:
                    continuation.yield(
                        .failed((params["detail"] as? String) ?? "pairing failed")
                    )
                }
                self.endPairing(continuation: continuation)
            case WhatsAppRPCNotification.helperTerminated:
                continuation.yield(.failed("The WhatsApp helper exited during pairing."))
                self.endPairing(continuation: continuation)
            default:
                break
            }
        }
        do {
            let response = try await callHelper(method: WhatsAppRPCMethod.loginStart, params: [:])
            if response.bool("already_linked") == true {
                let status = await probeAndCacheLinkStatus()
                continuation.yield(.success(selfNumber: status.selfNumber))
                endPairing(continuation: continuation)
            }
        } catch {
            endPairing(continuation: continuation)
            throw error
        }
        return stream
    }

    /// Forward the WebAuthn assertion JSON (from `cred.toJSON()` in a
    /// web.whatsapp.com browser tab) to the helper during a passkey-gated
    /// pairing. The pairing stream then continues with either a
    /// `.passkeyCode` event or a terminal result.
    func submitPasskeyResponse(_ responseJSON: String) async throws {
        let trimmed = responseJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WhatsAppConnectionServiceError.helper(
                "Paste the passkey response JSON from the browser first."
            )
        }
        _ = try await callHelper(
            method: WhatsAppRPCMethod.loginPasskeyResponse,
            params: ["response_json": trimmed],
            timeout: 45
        )
    }

    /// Confirm that the on-screen passkey code matches the one on the phone,
    /// finishing the passkey pairing exchange.
    func confirmPasskeyCode() async throws {
        _ = try await callHelper(
            method: WhatsAppRPCMethod.loginPasskeyConfirm,
            params: [:],
            timeout: 45
        )
    }

    func cancelPairing() async {
        _ = try? await callHelper(method: WhatsAppRPCMethod.loginCancel, params: [:], timeout: 5)
        let wasActive = pairingLock.withLock { () -> Bool in
            let was = pairingActive
            pairingActive = false
            return was
        }
        if wasActive {
            await transport.setNotificationHandler(nil)
        }
    }

    private func endPairing(continuation: AsyncStream<WhatsAppPairingEvent>.Continuation) {
        pairingLock.withLock { pairingActive = false }
        continuation.finish()
        let transport = self.transport
        Task { await transport.setNotificationHandler(nil) }
    }

    /// Unlink the account: helper `logout` (falls back to a local session
    /// wipe when offline), then refresh the cached link status.
    func unlink() async throws -> [String: Any] {
        let response = try await callHelper(method: WhatsAppRPCMethod.logout, params: [:], timeout: 30)
        await transport.shutdown()
        linkStatusLock.withLock { lastProbedLinkStatus = .empty }
        _ = await probeAndCacheLinkStatus()
        AgentChannelCredentialAvailability.shared.invalidate(.whatsapp)
        return response.object()
    }

    // MARK: - Diagnostics

    func diagnostics() async -> WhatsAppConnectionDiagnostics {
        let config = configuration()
        let helperState: String
        let helperVerified: Bool
        #if os(macOS)
            let verification = WhatsAppRuntimeAssets.verifyExecutable()
            switch verification {
            case .verified: helperState = "verified"
            case .overridden: helperState = "dev_override"
            case .missing: helperState = "missing"
            case .unpinned: helperState = "unpinned"
            case .digestMismatch: helperState = "digest_mismatch"
            }
            helperVerified = verification.trustedURL != nil
        #else
            helperState = "unsupported_platform"
            helperVerified = false
        #endif
        let linkStatus = await probeAndCacheLinkStatus()

        var failures: [String] = []
        var notes: [String] = []
        if !helperVerified {
            failures.append(
                "The WhatsApp helper is not usable (\(helperState)); download it in WhatsApp settings once a pinned release is available, or build it with `make wa-helper` (dev)."
            )
        } else if !linkStatus.linked {
            failures.append(
                "No WhatsApp account is linked. Open WhatsApp settings and scan the QR code with your phone (WhatsApp > Settings > Linked Devices)."
            )
        }
        if config.receiveEnabled && config.readableChatIds.isEmpty {
            failures.append("Add at least one readable WhatsApp chat for receive.")
        }
        if config.receiveEnabled && config.senderAllowlist.isEmpty {
            failures.append("Add at least one authorized WhatsApp sender for receive.")
        }
        notes.append(
            "WhatsApp connectivity uses the unofficial WhatsApp Web protocol (like a linked desktop app). WhatsApp may log the session out; re-scan the QR code if the link drops. A dedicated number is recommended."
        )

        let status: String
        if !helperVerified {
            status = "helper_unavailable"
        } else if !linkStatus.linked {
            status = "not_linked"
        } else if config.writeEnabled {
            status = "connected_read_write"
        } else {
            status = "connected_read_only"
        }

        return WhatsAppConnectionDiagnostics(
            helperVerified: helperVerified,
            helperState: helperState,
            helperVersion: linkStatus.helperVersion,
            linked: linkStatus.linked,
            selfNumber: linkStatus.selfNumber,
            readableChatIds: config.readableChatIds,
            writableChatIds: config.writableChatIds,
            senderAllowlist: config.senderAllowlist,
            writeEnabled: config.writeEnabled,
            receiveEnabled: config.receiveEnabled,
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
            "event_dedupe": "connection_id + provider_event_id (WAMID)",
            "cursor": "none — the WhatsApp watch stream is live-only",
            "transport_runtime": "whatsapp_watch",
        ]
    }

    // MARK: - Discovery

    func listSpaces() -> [[String: Any]] {
        [["id": Self.spaceId, "name": "WhatsApp", "kind": "messaging_network"]]
    }

    func listChats() async throws -> [[String: Any]] {
        let config = configuration()
        guard transport.isHelperAvailable(), lastKnownLinkStatus().linked || helperAvailable() else {
            return config.configuredChatIds.map { chatRow($0, config: config) }
        }
        do {
            // `chats.list` connects the helper; a first connect after idle
            // can take several seconds.
            let response = try await callHelper(
                method: WhatsAppRPCMethod.listChats,
                params: [:],
                timeout: 60
            )
            let helperChats = response.array("chats")
            if helperChats.isEmpty {
                return config.configuredChatIds.map { chatRow($0, config: config) }
            }
            return helperChats.map { chat in
                let jid = (chat["jid"] as? String) ?? ""
                let kind = (chat["kind"] as? String) ?? "dm"
                // DMs are identified by phone number (the allowlist-friendly
                // form); groups keep their `...@g.us` JID.
                let id = kind == "dm"
                    ? WhatsAppConnectionConfiguration.normalizedId((chat["number"] as? String) ?? jid)
                    : WhatsAppConnectionConfiguration.normalizedId(jid)
                let name = (chat["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return [
                    "id": id,
                    "name": name ?? id,
                    "kind": kind == "group" ? "group" : "chat",
                    "read_allowed": config.canRead(chatId: id),
                    "write_allowed": config.canWrite(chatId: id),
                    "raw": chat,
                ]
            }
        } catch {
            return config.configuredChatIds.map { chatRow($0, config: config) }
        }
    }

    private func chatRow(_ chatId: String, config: WhatsAppConnectionConfiguration) -> [String: Any] {
        [
            "id": chatId,
            "name": chatId,
            "kind": chatId.hasSuffix("@g.us") ? "group" : "chat",
            "read_allowed": config.canRead(chatId: chatId),
            "write_allowed": config.canWrite(chatId: chatId),
        ]
    }

    // MARK: - Reads (local message store)

    func readChat(chatId: String, limit: Int?) throws -> [String: Any] {
        let config = configuration()
        let normalized = try requireReadableChat(chatId, config: config)
        let safeLimit = WhatsAppConnectionConfiguration.clampReadLimit(limit ?? config.defaultReadLimit)
        guard let messageStore else {
            throw WhatsAppConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()
        let rows = try messageStore.recentMessages(
            connectionId: Self.nativeConnectionId,
            roomId: normalized,
            limit: safeLimit
        )
        return [
            "kind": "whatsapp_stored_messages",
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
            throw WhatsAppConnectionServiceError.emptyMessage
        }
        let config = configuration()
        let candidateChats = WhatsAppConnectionConfiguration.normalizedIds(
            chatIds ?? config.readableChatIds
        )
        let allowedChats = candidateChats.filter { config.canRead(chatId: $0) }
        guard !allowedChats.isEmpty else {
            throw WhatsAppConnectionServiceError.chatNotReadable(candidateChats.first ?? "")
        }
        guard let messageStore else {
            throw WhatsAppConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()

        let safeLimit = WhatsAppConnectionConfiguration.clampReadLimit(
            limitPerChat ?? config.defaultReadLimit
        )
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
            "kind": "whatsapp_stored_message_search",
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
            "kind": "whatsapp_message_draft",
            "chat_id": normalized,
            "content": trimmed,
            "requires_send_confirmation": true,
        ]
    }

    // MARK: - Writes

    func sendMessage(chatId: String, content: String, confirmSend: Bool) async throws -> [String: Any] {
        guard confirmSend else { throw WhatsAppConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let normalized = try requireWritableChat(chatId, config: config)
        let text = try validateMessageContent(content)
        let chunks = AgentChannelMessageFormatter.plainTextChunks(text)
        guard !chunks.isEmpty else { throw WhatsAppConnectionServiceError.emptyMessage }
        guard chunks.count <= AgentChannelMessageFormatter.maxChunksPerSend else {
            throw WhatsAppConnectionServiceError.messageTooLong
        }
        var lastResult: [String: Any] = [:]
        for chunk in chunks {
            let response = try await callHelper(
                method: WhatsAppRPCMethod.send,
                params: ["to": normalized, "text": chunk],
                timeout: 45
            )
            lastResult = response.object()
        }
        recordOutbound(chatId: normalized, content: text, result: lastResult)
        var result: [String: Any] = [
            "kind": "whatsapp_message_sent",
            "chat_id": normalized,
            "delivery_status": "sent",
            "message": lastResult,
        ]
        if chunks.count > 1 { result["chunk_count"] = chunks.count }
        return result
    }

    /// Standard `reply_thread` entry point. A WhatsApp "thread" is a quoted
    /// reply; the thread id is `<chat_id>:<message_id>` of the message being
    /// quoted (WAMIDs and chat ids never contain a colon).
    func replyToThread(
        threadId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard
            let separator = threadId.lastIndex(of: ":"),
            separator != threadId.startIndex,
            threadId.index(after: separator) != threadId.endIndex
        else {
            throw WhatsAppConnectionServiceError.invalidThreadId(threadId)
        }
        let chatId = String(threadId[..<separator])
        let messageId = String(threadId[threadId.index(after: separator)...])
        var payload = try await replyToMessage(
            chatId: chatId,
            messageId: messageId,
            content: content,
            confirmSend: confirmSend
        )
        payload["thread_id"] = threadId
        return payload
    }

    /// Quoted reply — WhatsApp's native "reply" affordance. The quoted
    /// message id doubles as the thread id in the agent-channel surface.
    func replyToMessage(
        chatId: String,
        messageId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw WhatsAppConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let normalized = try requireWritableChat(chatId, config: config)
        let text = try validateMessageContent(content)
        let chunks = AgentChannelMessageFormatter.plainTextChunks(text)
        guard !chunks.isEmpty else { throw WhatsAppConnectionServiceError.emptyMessage }
        guard chunks.count <= AgentChannelMessageFormatter.maxChunksPerSend else {
            throw WhatsAppConnectionServiceError.messageTooLong
        }
        let quoted = storedMessageRow(chatId: normalized, providerMessageId: messageId)
        var lastResult: [String: Any] = [:]
        for (index, chunk) in chunks.enumerated() {
            var params: [String: any Sendable] = ["to": normalized, "text": chunk]
            // Only the first chunk carries the quote; continuation chunks
            // read as normal follow-ups beneath the reply.
            if index == 0 {
                params["quote_id"] = messageId
                if let sender = quoted?.authorId, !sender.isEmpty {
                    params["quote_sender"] = sender
                }
                params["quote_text"] = String((quoted?.content ?? "").prefix(300))
            }
            let response = try await callHelper(
                method: WhatsAppRPCMethod.send,
                params: params,
                timeout: 45
            )
            lastResult = response.object()
        }
        recordOutbound(chatId: normalized, content: text, result: lastResult)
        var result: [String: Any] = [
            "kind": "whatsapp_reply_sent",
            "chat_id": normalized,
            "quoted_message_id": messageId,
            "delivery_status": "sent",
            "message": lastResult,
        ]
        if chunks.count > 1 { result["chunk_count"] = chunks.count }
        return result
    }

    func editMessage(
        chatId: String,
        messageId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw WhatsAppConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let normalized = try requireWritableChat(chatId, config: config)
        let text = try validateMessageContent(content)
        // An edit replaces one WhatsApp frame; content that would need
        // chunking cannot express itself as an edit.
        guard text.utf16.count <= AgentChannelMessageFormatter.plainTextChunkLimit else {
            throw WhatsAppConnectionServiceError.messageTooLong
        }
        let response = try await callHelper(
            method: WhatsAppRPCMethod.messageEdit,
            params: ["chat": normalized, "message_id": messageId, "text": text],
            timeout: 30
        )
        return [
            "kind": "whatsapp_message_edited",
            "chat_id": normalized,
            "message_id": messageId,
            "delivery_status": "sent",
            "result": response.object(),
        ]
    }

    /// Revoke ("delete for everyone"). Own messages revoke directly; someone
    /// else's message additionally needs group-admin rights, in which case
    /// the stored author rides along in the revoke key.
    func deleteMessage(
        chatId: String,
        messageId: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw WhatsAppConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let normalized = try requireWritableChat(chatId, config: config)
        var params: [String: any Sendable] = ["chat": normalized, "message_id": messageId]
        if let author = storedAuthorId(chatId: normalized, providerMessageId: messageId) {
            params["sender"] = author
        }
        let response = try await callHelper(
            method: WhatsAppRPCMethod.messageRevoke,
            params: params,
            timeout: 30
        )
        return [
            "kind": "whatsapp_message_deleted",
            "chat_id": normalized,
            "message_id": messageId,
            "delivery_status": "sent",
            "result": response.object(),
        ]
    }

    /// Send a file from an allowlisted attachment root (image, video, audio,
    /// or document — the helper picks the WhatsApp media class by MIME).
    func sendAttachment(
        chatId: String,
        path: String,
        caption: String?,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw WhatsAppConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let normalized = try requireWritableChat(chatId, config: config)
        guard config.isAttachmentPathAllowed(path) else {
            throw WhatsAppConnectionServiceError.attachmentNotAllowed(path)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let size = attributes?[.size] as? Int, size > config.maxAttachmentBytes {
            throw WhatsAppConnectionServiceError.attachmentTooLarge(config.maxAttachmentBytes)
        }
        var params: [String: any Sendable] = ["to": normalized, "path": path]
        let trimmedCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCaption.isEmpty { params["caption"] = trimmedCaption }
        // Upload + send round-trips the file to WhatsApp's media servers.
        let response = try await callHelper(
            method: WhatsAppRPCMethod.sendAttachment,
            params: params,
            timeout: 180
        )
        let result = response.object()
        recordOutbound(
            chatId: normalized,
            content: trimmedCaption.isEmpty
                ? "[attachment] \((path as NSString).lastPathComponent)"
                : trimmedCaption,
            result: result
        )
        return [
            "kind": "whatsapp_attachment_sent",
            "chat_id": normalized,
            "delivery_status": "sent",
            "message": result,
        ]
    }

    /// Delivers an agent-produced shared artifact as a media send during an
    /// auto-reply. The source lives in the trusted host artifacts store, which
    /// sits outside the attachment fence, so the file is staged into the first
    /// allowed media root and then pushed through the regular `sendAttachment`
    /// gates (attachments toggle, write allowlist, size cap). The staged copy
    /// is removed afterwards either way.
    func sendArtifactReply(chatId: String, hostPath: String, caption: String?) async throws {
        let config = configuration()
        guard config.attachmentIngestionEnabled,
            let root = config.allowedAttachmentRoots.first
        else {
            throw WhatsAppConnectionServiceError.attachmentNotAllowed(hostPath)
        }
        let filename = (hostPath as NSString).lastPathComponent
        let stagingDir = URL(fileURLWithPath: root)
            .appendingPathComponent("agent-replies", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let staged = stagingDir.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: hostPath), to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await sendAttachment(
            chatId: chatId,
            path: staged.path,
            caption: caption,
            confirmSend: true
        )
    }

    func setReaction(
        chatId: String,
        messageId: String,
        reaction: String,
        adding: Bool,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw WhatsAppConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let normalized = try requireWritableChat(chatId, config: config)
        let trimmedReaction = reaction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adding || !trimmedReaction.isEmpty else {
            throw WhatsAppConnectionServiceError.emptyMessage
        }
        var params: [String: any Sendable] = [
            "chat": normalized,
            "message_id": messageId,
            // WhatsApp removes a reaction by sending an empty emoji.
            "emoji": adding ? trimmedReaction : "",
        ]
        // The reaction key needs the target message's original sender; for
        // inbound messages we stored, resolve it from the local store (the
        // helper falls back to the chat JID when omitted).
        if let sender = storedAuthorId(chatId: normalized, providerMessageId: messageId) {
            params["sender"] = sender
        }
        let response = try await callHelper(method: WhatsAppRPCMethod.react, params: params, timeout: 30)
        return [
            "kind": adding ? "whatsapp_reaction_added" : "whatsapp_reaction_removed",
            "chat_id": normalized,
            "delivery_status": "sent",
            "result": response.object(),
        ]
    }

    func sendTyping(chatId: String, confirmSend: Bool) async throws -> [String: Any] {
        guard confirmSend else { throw WhatsAppConnectionServiceError.sendConfirmationRequired }
        let config = configuration()
        let normalized = try requireWritableChat(chatId, config: config)
        let response = try await callHelper(
            method: WhatsAppRPCMethod.typing,
            params: ["chat": normalized, "state": "composing"],
            timeout: 15
        )
        return [
            "kind": "whatsapp_typing",
            "chat_id": normalized,
            "delivery_status": "sent",
            "result": response.object(),
        ]
    }

    private func storedAuthorId(chatId: String, providerMessageId: String) -> String? {
        storedMessageRow(chatId: chatId, providerMessageId: providerMessageId)?.authorId
    }

    private func storedMessageRow(
        chatId: String,
        providerMessageId: String
    ) -> AgentChannelStoredMessage? {
        guard let messageStore else { return nil }
        guard (try? messageStore.openIfNeeded()) != nil else { return nil }
        let rows = (try? messageStore.recentMessages(
            connectionId: Self.nativeConnectionId,
            roomId: chatId,
            limit: 100
        )) ?? []
        return rows.first { $0.providerMessageId == providerMessageId }
    }

    // MARK: - Receive (watch stream)

    static let watchSkipReason = "whatsapp_event_not_ingestible"

    /// Run one live receive session against the helper's `watch.subscribe`
    /// stream. The stream is live-only (no backfill cursor — WhatsApp Web
    /// history sync is out of scope for v1); WAMID dedupe makes helper
    /// restarts harmless for anything redelivered.
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
            throw WhatsAppConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()
        let config = configuration()
        guard config.canStartReceive() else { return }

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

        // First subscribe can be slow: the helper connects and authenticates
        // the WhatsApp Web socket.
        var subscribeParams: [String: any Sendable] = [:]
        if config.attachmentIngestionEnabled {
            let mediaDir = WhatsAppConnectionConfiguration.mediaDirectoryURL()
            OsaurusPaths.ensureExistsSilent(mediaDir)
            subscribeParams["download_media"] = true
            subscribeParams["max_media_bytes"] = config.maxAttachmentBytes
            subscribeParams["media_dir"] = mediaDir.path
        }
        let subscribed = try await callHelper(
            method: WhatsAppRPCMethod.watchSubscribe,
            params: subscribeParams,
            timeout: 60
        )
        let selfJID = subscribed.string("self_jid") ?? ""
        let selfLID = subscribed.string("self_lid") ?? ""
        await onReady()

        var sessionError: Error?
        for await (method, paramsJSON) in notifications {
            if Task.isCancelled { break }
            switch method {
            case WhatsAppRPCNotification.message:
                guard
                    let payload = (try? JSONSerialization.jsonObject(with: paramsJSON))
                        as? [String: Any]
                else { continue }
                let summary = try await handleWatchEvent(payload, selfJID: selfJID, selfLID: selfLID)
                await onBatch(summary)
            case WhatsAppRPCNotification.error:
                let object = (try? JSONSerialization.jsonObject(with: paramsJSON)) as? [String: Any]
                let detail = (object?["detail"] as? String)
                    ?? (object?["reason"] as? String)
                    ?? "unknown watch error"
                if (object?["reason"] as? String) == "logged_out" {
                    // Terminal: the phone unlinked this device. Clear the
                    // cached link so the runtime stops instead of retrying.
                    linkStatusLock.withLock { lastProbedLinkStatus = .empty }
                    AgentChannelCredentialAvailability.shared.invalidate(.whatsapp)
                }
                sessionError = WhatsAppConnectionServiceError.helper(
                    "The WhatsApp watch stream failed: \(WhatsAppRPCSecurity.redact(detail))"
                )
            case WhatsAppRPCNotification.helperTerminated:
                sessionError = WhatsAppConnectionServiceError.helper(
                    "The WhatsApp helper exited during receive."
                )
            case WhatsAppRPCNotification.status:
                // connected / disconnected keepalives; whatsmeow reconnects
                // internally, so these are informational only.
                continue
            default:
                continue
            }
            if sessionError != nil { break }
        }

        if Task.isCancelled { return }
        throw sessionError
            ?? WhatsAppConnectionServiceError.helper(
                "The WhatsApp watch stream ended unexpectedly."
            )
    }

    /// Process one watch `message` notification payload: filter to
    /// allowlisted chats, normalize, authorize, record (WAMID dedupe), and
    /// dispatch.
    @discardableResult
    func handleWatchEvent(
        _ payload: [String: Any],
        selfJID: String = "",
        selfLID: String = ""
    ) async throws -> AgentChannelReceiveBatchSummary {
        guard let messageStore else {
            throw WhatsAppConnectionServiceError.messageStoreUnavailable
        }
        try messageStore.openIfNeeded()
        // Re-read configuration per event so allowlist edits apply to a
        // running session without an app restart.
        let config = configuration()
        let empty = AgentChannelReceiveBatchSummary(
            received: 0, stored: 0, dispatchAttempted: 0, dispatchSuppressed: 0
        )
        guard config.canStartReceive() else { return empty }

        // The watch stream covers every chat on the account; rows from chats
        // outside the read allowlist are dropped before authorization so
        // non-allowlisted conversations never reach storage or Activity.
        let roomId = WhatsAppConnectionConfiguration.normalizedId(
            (payload["chat"] as? String) ?? ""
        )
        guard !roomId.isEmpty, config.canRead(chatId: roomId) else {
            watchStatsLock.withLock { watchDroppedNonAllowlistedRows += 1 }
            return empty
        }

        guard let event = normalizeInbound(payload, selfJID: selfJID, selfLID: selfLID) else {
            if let id = (payload["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !id.isEmpty
            {
                await activityCenter.record(
                    connectionId: Self.nativeConnectionId,
                    providerEventId: id,
                    stage: .rejected,
                    reason: Self.watchSkipReason
                )
            }
            return empty
        }

        return try await ingest(events: [event], config: config, messageStore: messageStore)
    }

    func watchDroppedNonAllowlistedCount() -> Int {
        watchStatsLock.withLock { watchDroppedNonAllowlistedRows }
    }

    /// Kill the helper child process (if any). Called when receive stops or
    /// the app exits so no orphaned `osaurus-wa` process keeps a WhatsApp
    /// Web socket open.
    func shutdownTransport() async {
        await transport.shutdown()
    }

    private func ingest(
        events: [WhatsAppNormalizedInboundEvent],
        config: WhatsAppConnectionConfiguration,
        messageStore: AgentChannelMessageStore
    ) async throws -> AgentChannelReceiveBatchSummary {
        var inserted = 0
        var dispatchAttempted = 0
        var dispatchSuppressed = 0
        var readReceiptTargets: [WhatsAppNormalizedInboundEvent] = []
        let authorizationService = AgentChannelConnectionService(
            discordService: .shared,
            whatsappService: self
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
                if config.sendReadReceipts, receive.messageInserted, !event.isSelfMessage {
                    readReceiptTargets.append(event)
                }
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

        sendReadReceiptsIfEnabled(for: readReceiptTargets)

        return AgentChannelReceiveBatchSummary(
            received: events.count,
            stored: inserted,
            dispatchAttempted: dispatchAttempted,
            dispatchSuppressed: dispatchSuppressed
        )
    }

    /// Best-effort blue ticks for freshly stored allowlisted messages. Runs
    /// detached so a slow helper round-trip never stalls the watch loop.
    private func sendReadReceiptsIfEnabled(for events: [WhatsAppNormalizedInboundEvent]) {
        guard !events.isEmpty else { return }
        // The read-receipt key needs the original sender, so batch per
        // (chat, sender) pair.
        var grouped: [String: (chat: String, sender: String, ids: [String])] = [:]
        for event in events {
            guard let sender = event.senderId else { continue }
            let key = event.roomId + "|" + sender
            grouped[key, default: (event.roomId, sender, [])].ids.append(event.providerMessageId)
        }
        guard !grouped.isEmpty else { return }
        let transport = self.transport
        Task.detached(priority: .utility) {
            for entry in grouped.values {
                _ = try? await transport.call(
                    method: WhatsAppRPCMethod.read,
                    params: [
                        "chat": entry.chat,
                        "sender": entry.sender,
                        "message_ids": entry.ids,
                    ],
                    timeout: 15
                )
            }
        }
    }

    private func relayInboundEvent(
        _ event: WhatsAppNormalizedInboundEvent,
        config: WhatsAppConnectionConfiguration
    ) async -> AgentChannelInboundRelaySubmission {
        let settings = config.inboundDispatch
        guard settings.isConfigured else {
            return .suppressed("inbound_dispatch_not_configured")
        }
        // Mentions are detectable in groups (the helper reports mentioned
        // JIDs); a DM is inherently addressed to the account.
        if settings.requireMention, event.isGroup, !event.mentionsSelf {
            return .suppressed("mention_required")
        }
        guard let senderId = event.senderId else {
            return .suppressed("inbound_sender_missing")
        }
        let identity = ChannelIdentity(
            kind: .whatsapp,
            installationId: Self.nativeConnectionId,
            groupId: event.roomId,
            sender: ChannelSenderMetadata(senderId: senderId, displayName: event.authorName),
            trustLevel: .verified
        )
        let responder: AgentChannelInboundReplyHandler?
        let attachmentResponder: AgentChannelInboundAttachmentReplyHandler?
        if settings.autoReplyEnabled {
            responder = { [weak self] reply in
                guard let self else {
                    throw WhatsAppConnectionServiceError.helper(
                        "WhatsApp connection was released before replying."
                    )
                }
                _ = try await self.sendMessage(
                    chatId: event.roomId,
                    content: reply,
                    confirmSend: true
                )
            }
            attachmentResponder = { [weak self] path, caption in
                guard let self else {
                    throw WhatsAppConnectionServiceError.helper(
                        "WhatsApp connection was released before replying."
                    )
                }
                try await self.sendArtifactReply(
                    chatId: event.roomId,
                    hostPath: path,
                    caption: caption
                )
            }
        } else {
            responder = nil
            attachmentResponder = nil
        }
        return await AgentChannelInboundRelay.shared.submit(
            AgentChannelInboundRelayRequest(
                identity: identity,
                connectionId: Self.nativeConnectionId,
                providerEventId: event.providerEventId,
                providerRoute: AgentChannelProviderRoute(
                    conversationId: event.roomId,
                    displayName: "WhatsApp \(event.roomId)"
                ),
                content: event.content,
                attachments: event.attachments,
                settings: settings,
                sourceLabel: "WhatsApp chat \(event.roomId), sender \(senderId)",
                reply: responder,
                replyAttachment: attachmentResponder
            )
        )
    }

    // MARK: - Normalization

    /// Normalize one helper `message` notification into an inbound event.
    /// Returns nil for rows with no ingestible content.
    func normalizeInbound(
        _ payload: [String: Any],
        selfJID: String = "",
        selfLID: String = ""
    ) -> WhatsAppNormalizedInboundEvent? {
        guard let id = (payload["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty
        else { return nil }
        let roomId = WhatsAppConnectionConfiguration.normalizedId(
            (payload["chat"] as? String) ?? ""
        )
        guard !roomId.isEmpty else { return nil }

        let text = ((payload["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaType = ((payload["media_type"] as? String) ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        // Media keeps the `[image]`-style placeholder in the content (with
        // the caption when present); the downloaded payload — when ingestion
        // is on and the helper fetched it — rides along as an attachment.
        let content: String
        if !text.isEmpty && !mediaType.isEmpty {
            content = "[\(mediaType)] \(text)"
        } else if !text.isEmpty {
            content = text
        } else if !mediaType.isEmpty {
            content = "[\(mediaType)]"
        } else {
            return nil
        }
        guard content.utf16.count <= Self.maxInboundContentLength else { return nil }

        let senderId = ((payload["sender_number"] as? String) ?? (payload["sender"] as? String))
            .map(WhatsAppConnectionConfiguration.normalizedId)
            .flatMap { $0.isEmpty ? nil : $0 }
        let isGroup = (payload["is_group"] as? Bool) ?? roomId.hasSuffix("@g.us")
        let mentions = (payload["mentions"] as? [String]) ?? []
        // Self can be mentioned by phone JID or by LID (the helper resolves
        // LIDs it can map, but an unmapped LID mention must still count).
        let selfIds = [selfJID, selfLID]
            .map(WhatsAppConnectionConfiguration.normalizedId)
            .filter { !$0.isEmpty }
        let mentionsSelf = !selfIds.isEmpty
            && mentions.contains {
                selfIds.contains(WhatsAppConnectionConfiguration.normalizedId($0))
            }

        let timestamp = (payload["timestamp"] as? Int64)
            ?? (payload["timestamp"] as? Int).map(Int64.init)
        let providerTimestamp = timestamp.map {
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0)))
        }

        var attachments: [AgentChannelStoredAttachment] = []
        if let mediaPath = (payload["media_path"] as? String), !mediaPath.isEmpty {
            attachments.append(
                AgentChannelStoredAttachment(
                    providerId: mediaPath,
                    kind: Self.attachmentKind(mediaType),
                    filename: (payload["filename"] as? String)
                        ?? (mediaPath as NSString).lastPathComponent,
                    contentType: payload["media_mime"] as? String,
                    sizeBytes: (payload["media_size"] as? Int)
                )
            )
        }

        let quotedMessageId = (payload["quote_id"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return WhatsAppNormalizedInboundEvent(
            providerEventId: id,
            roomId: roomId,
            providerMessageId: id,
            content: content,
            senderId: senderId,
            authorName: (payload["push_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isSelfMessage: (payload["is_from_me"] as? Bool) ?? false,
            isGroup: isGroup,
            mentionsSelf: mentionsSelf,
            providerTimestamp: providerTimestamp,
            attachments: attachments,
            quotedMessageId: quotedMessageId,
            quotedSenderId: quotedMessageId == nil
                ? nil
                : (payload["quote_sender"] as? String)
                    .map(WhatsAppConnectionConfiguration.normalizedId)
                    .flatMap { $0.isEmpty ? nil : $0 },
            quotedText: quotedMessageId == nil
                ? nil
                : (payload["quote_text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func attachmentKind(_ mediaType: String) -> AgentChannelStoredAttachmentKind {
        switch mediaType {
        case "image", "sticker": return .image
        case "video": return .video
        case "audio": return .audio
        default: return .file
        }
    }

    // MARK: - Helper invocation

    private func callHelper(
        method: String,
        params: [String: any Sendable],
        timeout: TimeInterval = 15
    ) async throws -> WhatsAppRPCResponse {
        do {
            return try await transport.call(method: method, params: params, timeout: timeout)
        } catch let error as WhatsAppRPCError {
            throw WhatsAppConnectionServiceError.helper(error.localizedDescription)
        }
    }

    private func recordOutbound(chatId: String, content: String, result: [String: Any]) {
        guard let messageStore else { return }
        let providerMessageId = (result["message_id"] as? String) ?? UUID().uuidString
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
                NSLog("[WhatsApp] Failed to record outbound message: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Validation

    private func requireReadableChat(
        _ chatId: String,
        config: WhatsAppConnectionConfiguration
    ) throws -> String {
        let normalized = try requireChatId(chatId)
        guard config.canRead(chatId: normalized) else {
            throw WhatsAppConnectionServiceError.chatNotReadable(normalized)
        }
        return normalized
    }

    private func requireWritableChat(
        _ chatId: String,
        config: WhatsAppConnectionConfiguration
    ) throws -> String {
        let normalized = try requireChatId(chatId)
        guard config.writeEnabled else {
            throw WhatsAppConnectionServiceError.writeDisabled
        }
        guard config.canWrite(chatId: normalized) else {
            throw WhatsAppConnectionServiceError.chatNotWritable(normalized)
        }
        return normalized
    }

    private func requireChatId(_ chatId: String) throws -> String {
        let normalized = WhatsAppConnectionConfiguration.normalizedId(chatId)
        guard WhatsAppConnectionConfiguration.isValidChatId(normalized) else {
            throw WhatsAppConnectionServiceError.invalidChatId(chatId)
        }
        return normalized
    }

    private func validateMessageContent(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WhatsAppConnectionServiceError.emptyMessage
        }
        let maxInput = AgentChannelMessageFormatter.plainTextChunkLimit
            * AgentChannelMessageFormatter.maxChunksPerSend
        guard trimmed.utf16.count <= maxInput else {
            throw WhatsAppConnectionServiceError.messageTooLong
        }
        return trimmed
    }

    private static func storedMessage(
        _ event: WhatsAppNormalizedInboundEvent
    ) -> AgentChannelStoredMessage {
        AgentChannelStoredMessage(
            connectionId: nativeConnectionId,
            roomId: event.roomId,
            providerMessageId: event.providerMessageId,
            direction: .inbound,
            // A WhatsApp quoted reply threads under the quoted message id.
            threadId: event.quotedMessageId,
            authorId: event.senderId,
            authorName: event.authorName,
            content: event.content,
            attachments: event.attachments,
            providerTimestamp: event.providerTimestamp
        )
    }

    private static func storedMessageDictionary(_ message: AgentChannelStoredMessage) -> [String: Any] {
        var row: [String: Any] = [
            "id": message.providerMessageId,
            "chat_id": message.roomId,
            "content": message.content,
            "timestamp": message.providerTimestamp ?? "",
            "author": [
                "id": message.authorId ?? "",
                "display_name": message.authorName ?? "",
            ],
            "direction": message.direction.rawValue,
            // Feed this to `reply_thread` to quote-reply to this message.
            "reply_thread_id": "\(message.roomId):\(message.providerMessageId)",
        ]
        if let threadId = message.threadId, !threadId.isEmpty {
            row["quoted_message_id"] = threadId
        }
        if !message.attachments.isEmpty {
            row["attachments"] = message.attachments.map { attachment in
                [
                    "path": attachment.providerId,
                    "kind": attachment.kind.rawValue,
                    "filename": attachment.filename ?? "",
                    "content_type": attachment.contentType ?? "",
                    "size_bytes": attachment.sizeBytes ?? 0,
                ] as [String: Any]
            }
        }
        return row
    }
}

/// Tiny lock-protected box so the blocking link probe can move a value out
/// of a detached task without capturing a mutable local.
private final class WhatsAppLinkStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: WhatsAppLinkStatus = .empty

    func set(_ value: WhatsAppLinkStatus) {
        lock.withLock { status = value }
    }

    func get() -> WhatsAppLinkStatus {
        lock.withLock { status }
    }
}
