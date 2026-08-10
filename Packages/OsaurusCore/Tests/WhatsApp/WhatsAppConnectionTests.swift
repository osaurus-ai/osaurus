//
//  WhatsAppConnectionTests.swift
//  osaurusTests
//
//  Fixture coverage for the native WhatsApp agent channel: JSON-RPC framing
//  and status parsing, configuration policy (id normalization, allowlists,
//  clamps), the connection service against a fake helper transport, the
//  live watch receive pipeline (allowlist filter, WAMID dedupe, self-message
//  policy, mentions), and the watch transport runtime preflights.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Pure framing / status parsing

struct WhatsAppRPCFramingTests {

    @Test func encodeRequestProducesNewlineFramedJSONRPC() throws {
        let frame = try WhatsAppRPCFraming.encodeRequest(
            id: 7,
            method: "send",
            params: ["to": "+15551234567", "text": "hi"]
        )

        #expect(frame.last == 0x0A)
        let object =
            try JSONSerialization.jsonObject(with: frame.dropLast()) as? [String: Any] ?? [:]
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 7)
        #expect(object["method"] as? String == "send")
        let params = object["params"] as? [String: Any]
        #expect(params?["to"] as? String == "+15551234567")
        // Exactly one line: embedded newlines would break the framing.
        #expect(!frame.dropLast().contains(0x0A))
    }

    @Test func encodeRequestOmitsEmptyParams() throws {
        let frame = try WhatsAppRPCFraming.encodeRequest(id: 1, method: "status", params: [:])
        let object =
            try JSONSerialization.jsonObject(with: frame.dropLast()) as? [String: Any] ?? [:]
        #expect(object["params"] == nil)
    }

    @Test func parseResponseLineDecodesResultErrorAndNotification() throws {
        let success = WhatsAppRPCFraming.parseResponseLine(
            Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#.utf8)
        )
        #expect(success?.id == 3)
        #expect(success?.errorCode == nil)
        let result =
            try JSONSerialization.jsonObject(with: #require(success?.resultJSON)) as? [String: Any]
        #expect(result?["ok"] as? Bool == true)

        let failure = WhatsAppRPCFraming.parseResponseLine(
            Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"no such method"}}"#.utf8)
        )
        #expect(failure?.id == 4)
        #expect(failure?.errorCode == -32601)
        #expect(failure?.errorMessage == "no such method")

        let notification = WhatsAppRPCFraming.parseNotificationLine(
            Data(#"{"jsonrpc":"2.0","method":"message","params":{"id":"WAMID-1"}}"#.utf8)
        )
        #expect(notification?.method == "message")

        // Responses (with an id) are never notifications.
        #expect(
            WhatsAppRPCFraming.parseNotificationLine(
                Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8)
            ) == nil
        )
        #expect(WhatsAppRPCFraming.parseResponseLine(Data("not json".utf8)) == nil)
    }

    /// Locks the link-status parser to the helper's `status --json` schema
    /// (`version`, `linked`, `self_jid`, `self_number`, `rpc_methods`).
    @Test func linkStatusParsesHelperStatusPayload() {
        let payload = """
            {"version":"0.1.0","linked":true,"self_jid":"15550001111.0:1@s.whatsapp.net",\
            "self_number":"+15550001111","session_store":"whatsapp/session",\
            "rpc_methods":["status","login.start","login.cancel","logout","chats.list",\
            "send","react","typing","read","watch.subscribe"]}
            """
        let status = WhatsAppLinkStatus.parse(statusJSON: Data(payload.utf8))
        #expect(status?.probed == true)
        #expect(status?.linked == true)
        #expect(status?.helperVersion == "0.1.0")
        #expect(status?.selfNumber == "+15550001111")
        #expect(status?.rpcMethods.contains("watch.subscribe") == true)

        #expect(WhatsAppLinkStatus.parse(statusJSON: Data("not json".utf8)) == nil)
        #expect(WhatsAppLinkStatus.parse(statusJSON: Data("{}".utf8)) == nil)
    }

    /// Every RPC method name Osaurus dispatches must exist in the helper's
    /// advertised surface (`rpcMethods` in helpers/osaurus-wa/main.go); a
    /// rename must fail this lock instead of degrading to "method not found".
    @Test func dispatchedMethodNamesMatchHelperSurface() {
        let advertised: Set<String> = [
            "status", "login.start", "login.cancel",
            "login.passkey_response", "login.passkey_confirm",
            "logout", "chats.list",
            "send", "send.attachment", "message.edit", "message.revoke",
            "react", "typing", "read", "watch.subscribe",
        ]
        let dispatched = [
            WhatsAppRPCMethod.status,
            WhatsAppRPCMethod.loginStart,
            WhatsAppRPCMethod.loginCancel,
            WhatsAppRPCMethod.loginPasskeyResponse,
            WhatsAppRPCMethod.loginPasskeyConfirm,
            WhatsAppRPCMethod.logout,
            WhatsAppRPCMethod.listChats,
            WhatsAppRPCMethod.send,
            WhatsAppRPCMethod.sendAttachment,
            WhatsAppRPCMethod.messageEdit,
            WhatsAppRPCMethod.messageRevoke,
            WhatsAppRPCMethod.react,
            WhatsAppRPCMethod.typing,
            WhatsAppRPCMethod.read,
            WhatsAppRPCMethod.watchSubscribe,
        ]
        for method in dispatched {
            #expect(advertised.contains(method), "\(method) is not an osaurus-wa RPC method")
        }
    }

    /// WhatsApp's passkey linking gate: `passkey` notifications are
    /// non-terminal pairing events (the stream must stay open through the
    /// WebAuthn round-trip), and the response/confirm wrappers dispatch to
    /// the helper's passkey methods with the pasted JSON trimmed.
    @Test func pairingStreamsPasskeyStagesWithoutTerminating() async throws {
        let transport = FakeWhatsAppTransport()
        let service = WhatsAppConnectionService(transport: transport)
        transport.setResponse(for: "login.start", result: ["started": true])

        let stream = try await service.startPairing()
        transport.emitNotification(method: "qr", params: ["code": "2@abc", "timeout_ms": 60000])
        transport.emitNotification(
            method: "passkey",
            params: ["stage": "challenge", "public_key_json": "{\"rpId\":\"whatsapp.com\"}"]
        )
        transport.emitNotification(method: "passkey", params: ["stage": "confirm", "code": "ABCD-EFGH"])
        transport.emitNotification(
            method: "login", params: ["status": "success", "self_number": "+15550001111"]
        )

        var events: [WhatsAppPairingEvent] = []
        for await event in stream { events.append(event) }
        #expect(
            events == [
                .qr(code: "2@abc"),
                .passkeyChallenge(publicKeyJSON: "{\"rpId\":\"whatsapp.com\"}"),
                .passkeyCode(code: "ABCD-EFGH"),
                .success(selfNumber: "+15550001111"),
            ]
        )

        try await service.submitPasskeyResponse(" {\"id\":\"x\"} \n")
        let responseCalls = transport.calls(for: "login.passkey_response")
        #expect(responseCalls.count == 1)
        #expect(responseCalls.first?["response_json"] as? String == "{\"id\":\"x\"}")

        try await service.confirmPasskeyCode()
        #expect(transport.calls(for: "login.passkey_confirm").count == 1)

        await #expect(throws: WhatsAppConnectionServiceError.self) {
            try await service.submitPasskeyResponse("   ")
        }
    }

    @Test func redactionReplacesHomeDirectoryWithTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let redacted = WhatsAppRPCSecurity.redact("open failed: \(home)/.osaurus/whatsapp/session")
        #expect(!redacted.contains(home))
        #expect(redacted.contains("~/.osaurus/whatsapp/session"))
    }

    /// The Activity scope filter and every service-side record share one
    /// native connection id; drift would silently empty the WhatsApp filter.
    @Test func nativeConnectionIdMatchesActivityScopeContract() {
        #expect(WhatsAppConnectionService.nativeConnectionId == "whatsapp")
        #expect(AgentChannelConnection.nativeWhatsAppConnectionId == "whatsapp")
    }
}

// MARK: - Configuration policy

struct WhatsAppConfigurationTests {

    @Test func defaultsAreFailClosed() {
        let config = WhatsAppConnectionConfiguration()
        #expect(!config.writeEnabled)
        #expect(!config.receiveEnabled)
        #expect(config.ignoreSelfMessages)
        #expect(!config.canStartReceive())
        #expect(!config.canWrite(chatId: "+15551234567"))
    }

    @Test func normalizationCanonicalizesPhonesAndLowercasesJIDs() {
        // Phone numbers reduce to +digits so every presentation matches.
        #expect(WhatsAppConnectionConfiguration.normalizedId("+1 (206) 555-1234") == "+12065551234")
        #expect(WhatsAppConnectionConfiguration.normalizedId("12065551234") == "+12065551234")
        // Group JIDs lowercase and keep their server suffix.
        #expect(
            WhatsAppConnectionConfiguration.normalizedId(" 1203630XYZ@G.US ") == "1203630xyz@g.us"
        )
        // Direct-chat JIDs (as the watch stream reports them, with optional
        // agent/device suffixes) collapse into the phone id space.
        #expect(
            WhatsAppConnectionConfiguration.normalizedId("12065551234@s.whatsapp.net")
                == "+12065551234"
        )
        #expect(
            WhatsAppConnectionConfiguration.normalizedId("12065551234.0:1@s.whatsapp.net")
                == "+12065551234"
        )
        #expect(WhatsAppConnectionConfiguration.normalizedId("   ") == "")
        #expect(!WhatsAppConnectionConfiguration.isValidChatId("   "))

        let config = WhatsAppConnectionConfiguration(
            readableChatIds: [" +1 (206) 555-1234 ", "12065551234", ""],
            senderAllowlist: ["+15551234567", "1 555 123 4567"]
        )
        #expect(config.readableChatIds == ["+12065551234"])
        #expect(config.senderAllowlist == ["+15551234567"])
        #expect(config.canRead(chatId: "1-206-555-1234"))
    }

    @Test func limitsClampToSafeRanges() {
        #expect(WhatsAppConnectionConfiguration(defaultReadLimit: 100_000).defaultReadLimit == 100)
        #expect(WhatsAppConnectionConfiguration(defaultReadLimit: -3).defaultReadLimit == 1)
        #expect(WhatsAppConnectionConfiguration.clampReadLimit(0) == 1)
    }

    @Test func receiveRequiresToggleChatsAndSenders() {
        let ready = WhatsAppConnectionConfiguration(
            readableChatIds: ["+15551234567"],
            senderAllowlist: ["+15551234567"],
            receiveEnabled: true
        )
        #expect(ready.canStartReceive())
        #expect(
            !WhatsAppConnectionConfiguration(
                readableChatIds: ["+15551234567"],
                senderAllowlist: [],
                receiveEnabled: true
            ).canStartReceive()
        )
        #expect(
            !WhatsAppConnectionConfiguration(
                readableChatIds: [],
                senderAllowlist: ["+15551234567"],
                receiveEnabled: true
            ).canStartReceive()
        )
        #expect(
            !WhatsAppConnectionConfiguration(
                readableChatIds: ["+15551234567"],
                senderAllowlist: ["+15551234567"],
                receiveEnabled: false
            ).canStartReceive()
        )
    }

    @Test func attachmentPolicyDefaultsAndClamps() {
        let config = WhatsAppConnectionConfiguration()
        #expect(!config.sendReadReceipts)
        #expect(!config.attachmentIngestionEnabled)
        // The media directory the helper downloads into is always an
        // allowed outbound root, so re-sharing received media just works.
        #expect(
            config.allowedAttachmentRoots
                == [WhatsAppConnectionConfiguration.mediaDirectoryURL().path]
        )
        #expect(
            config.maxAttachmentBytes
                == WhatsAppConnectionConfiguration.defaultMaxAttachmentBytes
        )

        // The size cap clamps to a sane floor/ceiling.
        #expect(WhatsAppConnectionConfiguration.clampAttachmentBytes(0) == 64 * 1_024)
        #expect(
            WhatsAppConnectionConfiguration.clampAttachmentBytes(10_000_000_000)
                == 100 * 1_024 * 1_024
        )

        // Root normalization drops empties, "/" and duplicates.
        #expect(
            WhatsAppConnectionConfiguration.normalizedRoots(["/tmp/a/", "/tmp/a", "/", ""])
                == ["/tmp/a"]
        )
    }

    @Test func attachmentPathFenceRequiresToggleAndContainment() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-wa-fence-\(UUID().uuidString)").path
        let enabled = WhatsAppConnectionConfiguration(
            attachmentIngestionEnabled: true,
            allowedAttachmentRoots: [root]
        )
        #expect(enabled.isAttachmentPathAllowed(root + "/photo.jpg"))
        #expect(enabled.isAttachmentPathAllowed(root))
        // Prefix collisions on a sibling directory are not containment.
        #expect(!enabled.isAttachmentPathAllowed(root + "-evil/photo.jpg"))
        #expect(!enabled.isAttachmentPathAllowed("/etc/passwd"))
        // Traversal escapes resolve outside the root and are rejected.
        #expect(!enabled.isAttachmentPathAllowed(root + "/../../etc/passwd"))

        // The master toggle is fail-closed: with attachment support off, no
        // path is allowed — not even inside a configured root.
        let disabled = WhatsAppConnectionConfiguration(
            attachmentIngestionEnabled: false,
            allowedAttachmentRoots: [root]
        )
        #expect(!disabled.isAttachmentPathAllowed(root + "/photo.jpg"))
    }

    @Test func writeGateRequiresBothToggleAndAllowlist() {
        let config = WhatsAppConnectionConfiguration(
            writableChatIds: ["+15551234567"],
            writeEnabled: true
        )
        #expect(config.canWrite(chatId: "+1 (555) 123-4567"))
        #expect(!config.canWrite(chatId: "+15559990000"))
        #expect(
            !WhatsAppConnectionConfiguration(
                writableChatIds: ["+15551234567"],
                writeEnabled: false
            ).canWrite(chatId: "+15551234567")
        )
    }
}

// MARK: - Release manifest lock

struct WhatsAppRuntimeAssetsManifestTests {

    /// `WhatsAppRuntimeAssets` digests MUST match the release manifest the
    /// download installer will consume; drift would verify one binary and
    /// download another.
    @Test func pinnedDigestsMatchReleaseManifest() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WhatsApp/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
            .deletingLastPathComponent()  // Packages/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("scripts/build/wa-helper-manifest.json")
        let manifest =
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            ?? [:]

        #expect(manifest["version"] as? String == WhatsAppRuntimeAssets.version)
        #expect(manifest["archiveURL"] as? String == WhatsAppRuntimeAssets.archiveURLString)
        #expect(manifest["archiveSHA256"] as? String == WhatsAppRuntimeAssets.archiveSHA256)
        #expect(
            manifest["executableSHA256"] as? String == WhatsAppRuntimeAssets.executableSHA256
        )
    }
}

// MARK: - Connection service against a fake helper transport

@Suite(.serialized)
struct WhatsAppConnectionServiceTests {

    private static let dmChat = "+15551234567"
    private static let groupChat = "1203630001@g.us"

    @Test func configurationPersistsNormalizedAndRoundTrips() async throws {
        try await withIsolatedWhatsAppStores {
            let service = WhatsAppConnectionService(transport: FakeWhatsAppTransport())
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [" +1 (555) 123-4567 ", "15551234567"],
                    writableChatIds: ["+15551234567"],
                    senderAllowlist: ["1 555 123 4567"],
                    writeEnabled: true,
                    defaultReadLimit: 5_000,
                    receiveEnabled: true,
                    sendReadReceipts: true,
                    attachmentIngestionEnabled: true,
                    allowedAttachmentRoots: ["/tmp/wa-media/", "/tmp/wa-media"],
                    maxAttachmentBytes: 10_000_000_000
                )
            )

            let saved = WhatsAppConnectionConfigurationStore.load()
            #expect(saved.readableChatIds == ["+15551234567"])
            #expect(saved.senderAllowlist == ["+15551234567"])
            #expect(saved.defaultReadLimit == 100)
            #expect(saved.writeEnabled)
            #expect(saved.receiveEnabled)
            #expect(saved.sendReadReceipts)
            #expect(saved.attachmentIngestionEnabled)
            #expect(saved.allowedAttachmentRoots == ["/tmp/wa-media"])
            #expect(saved.maxAttachmentBytes == 100 * 1_024 * 1_024)

            // No secret material belongs in this file — the credential is
            // the helper's linked session, not a token.
            let disk = try String(
                contentsOf: WhatsAppConnectionConfigurationStore.configurationFileURL(),
                encoding: .utf8
            )
            #expect(disk.contains("+15551234567"))
            #expect(!disk.localizedCaseInsensitiveContains("token"))
        }
    }

    @Test func connectionManagerRejectsNativeWhatsAppId() async throws {
        try await withIsolatedWhatsAppStores {
            let manager = AgentChannelConnectionManager(agentExists: { _ in true })

            #expect(throws: AgentChannelConnectionManagerError.reservedConnectionId("whatsapp")) {
                try manager.upsertConnection(
                    AgentChannelConnection(
                        id: "whatsapp",
                        name: "Shadow WhatsApp",
                        kind: .customHTTP,
                        supportedActions: [.diagnostics],
                        customHTTP: AgentChannelCustomHTTPConfiguration(
                            baseURL: "https://hooks.example.test",
                            actions: [:]
                        )
                    )
                )
            }
        }
    }

    @Test func sendRequiresConfirmationWriteEnablementAndAllowlist() async throws {
        try await withIsolatedWhatsAppStores {
            let transport = FakeWhatsAppTransport()
            let service = WhatsAppConnectionService(transport: transport)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: false
                )
            )

            await #expect(throws: WhatsAppConnectionServiceError.sendConfirmationRequired) {
                _ = try await service.sendMessage(
                    chatId: Self.dmChat, content: "hi", confirmSend: false
                )
            }
            // With the global write switch off the precise gate is
            // `.writeDisabled`; `.chatNotWritable` is for allowlist misses.
            await #expect(throws: WhatsAppConnectionServiceError.writeDisabled) {
                _ = try await service.sendMessage(
                    chatId: Self.dmChat, content: "hi", confirmSend: true
                )
            }

            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true
                )
            )
            await #expect(throws: WhatsAppConnectionServiceError.chatNotWritable("+15559990000")) {
                _ = try await service.sendMessage(
                    chatId: "+15559990000", content: "hi", confirmSend: true
                )
            }
            #expect(transport.calls(for: WhatsAppRPCMethod.send).isEmpty)
        }
    }

    @Test func sendStripsMarkdownChunksLongContentAndNormalizesRecipient() async throws {
        try await withIsolatedWhatsAppStores {
            let transport = FakeWhatsAppTransport()
            transport.setResponse(for: WhatsAppRPCMethod.send, result: ["message_id": "WAMID-1"])
            let service = WhatsAppConnectionService(transport: transport)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true
                )
            )

            _ = try await service.sendMessage(
                chatId: "+1 (555) 123-4567",
                content: "**bold** and _italic_",
                confirmSend: true
            )
            let call = transport.calls(for: WhatsAppRPCMethod.send).last
            #expect(call?["text"] as? String == "bold and italic")
            #expect(call?["to"] as? String == Self.dmChat)

            transport.clearCalls()
            let long = String(
                repeating: "a",
                count: AgentChannelMessageFormatter.plainTextChunkLimit + 100
            )
            let result = try await service.sendMessage(
                chatId: Self.dmChat, content: long, confirmSend: true
            )
            #expect(transport.calls(for: WhatsAppRPCMethod.send).count == 2)
            #expect(result["chunk_count"] as? Int == 2)

            let overLimit = String(
                repeating: "a",
                count: AgentChannelMessageFormatter.plainTextChunkLimit
                    * AgentChannelMessageFormatter.maxChunksPerSend + 1
            )
            await #expect(throws: WhatsAppConnectionServiceError.messageTooLong) {
                _ = try await service.sendMessage(
                    chatId: Self.dmChat, content: overLimit, confirmSend: true
                )
            }
        }
    }

    @Test func readAndSearchEnforceReadAllowlistOverStoredMessages() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            _ = try store.recordMessages([
                AgentChannelStoredMessage(
                    connectionId: "whatsapp",
                    roomId: Self.dmChat,
                    providerMessageId: "WAMID-1",
                    direction: .inbound,
                    authorId: Self.dmChat,
                    content: "deploy finished at noon"
                )
            ])

            let service = WhatsAppConnectionService(
                transport: FakeWhatsAppTransport(),
                messageStore: store
            )
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(readableChatIds: [Self.dmChat])
            )

            let read = try service.readChat(chatId: "1-555-123-4567", limit: 10)
            let messages = read["messages"] as? [[String: Any]] ?? []
            #expect(messages.count == 1)
            #expect(messages.first?["content"] as? String == "deploy finished at noon")

            #expect(throws: WhatsAppConnectionServiceError.chatNotReadable("+15559990000")) {
                _ = try service.readChat(chatId: "+15559990000", limit: 10)
            }

            let search = try service.searchMessages(
                query: "DEPLOY", chatIds: nil, limitPerChat: nil, maxMatches: nil
            )
            #expect(search["match_count"] as? Int == 1)
            #expect(throws: WhatsAppConnectionServiceError.emptyMessage) {
                _ = try service.searchMessages(
                    query: "   ", chatIds: nil, limitPerChat: nil, maxMatches: nil
                )
            }
        }
    }

    @Test func reactionResolvesStoredSenderAndRemovesWithEmptyEmoji() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            _ = try store.recordMessages([
                AgentChannelStoredMessage(
                    connectionId: "whatsapp",
                    roomId: Self.dmChat,
                    providerMessageId: "WAMID-1",
                    direction: .inbound,
                    authorId: Self.dmChat,
                    content: "react to me"
                )
            ])
            let transport = FakeWhatsAppTransport()
            transport.setResponse(for: WhatsAppRPCMethod.react, result: [:])
            let service = WhatsAppConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true
                )
            )

            _ = try await service.setReaction(
                chatId: Self.dmChat, messageId: "WAMID-1", reaction: "👍",
                adding: true, confirmSend: true
            )
            var params = transport.calls(for: WhatsAppRPCMethod.react).last
            #expect(params?["emoji"] as? String == "👍")
            // The reaction key carries the original message's sender,
            // resolved from the local store.
            #expect(params?["sender"] as? String == Self.dmChat)

            // Removal is an empty emoji in the WhatsApp protocol.
            _ = try await service.setReaction(
                chatId: Self.dmChat, messageId: "WAMID-1", reaction: "👍",
                adding: false, confirmSend: true
            )
            params = transport.calls(for: WhatsAppRPCMethod.react).last
            #expect(params?["emoji"] as? String == "")

            await #expect(throws: WhatsAppConnectionServiceError.emptyMessage) {
                _ = try await service.setReaction(
                    chatId: Self.dmChat, messageId: "WAMID-1", reaction: "  ",
                    adding: true, confirmSend: true
                )
            }
        }
    }

    @Test func watchEventsAuthorizeStoreAndDeduplicateByWAMID() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let service = WhatsAppConnectionService(
                transport: FakeWhatsAppTransport(),
                messageStore: store
            )
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    receiveEnabled: true
                )
            )

            let authorizedRow: [String: Any] = [
                "id": "WAMID-41", "chat": "15551234567@s.whatsapp.net",
                "sender": "15551234567@s.whatsapp.net", "sender_number": "+15551234567",
                "text": "authorized hello",
                "is_from_me": false, "is_group": false,
                "timestamp": 1_753_795_260,
            ]
            let authorized = try await service.handleWatchEvent(authorizedRow)
            #expect(authorized.received == 1)
            #expect(authorized.stored == 1)
            #expect(try store.messageCount(connectionId: "whatsapp", roomId: Self.dmChat) == 1)

            // Non-allowlisted sender in a readable chat: rejected before
            // storage.
            let stranger = try await service.handleWatchEvent([
                "id": "WAMID-42", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+19998887777", "text": "stranger danger",
                "is_from_me": false,
            ])
            #expect(stranger.received == 1)
            #expect(stranger.stored == 0)

            // Redelivery after a helper restart stores nothing new: dedupe
            // is by WAMID (provider event id).
            let replay = try await service.handleWatchEvent(authorizedRow)
            #expect(replay.stored == 0)
            #expect(try store.messageCount(connectionId: "whatsapp", roomId: Self.dmChat) == 1)
        }
    }

    @Test func watchDropsNonAllowlistedChatsBeforeAuthorizationAndCountsThem() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let service = WhatsAppConnectionService(
                transport: FakeWhatsAppTransport(),
                messageStore: store
            )
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    receiveEnabled: true
                )
            )
            #expect(service.watchDroppedNonAllowlistedCount() == 0)

            // The watch stream covers every chat on the account; foreign
            // chats are dropped before authorization (never stored, never in
            // Activity) but counted for receive health.
            for index in 1 ... 2 {
                let summary = try await service.handleWatchEvent([
                    "id": "WAMID-foreign-\(index)", "chat": "15550000000@s.whatsapp.net",
                    "sender_number": "+15550000000", "text": "not for us",
                    "is_from_me": false,
                ])
                #expect(summary.received == 0)
            }
            #expect(service.watchDroppedNonAllowlistedCount() == 2)
            #expect(try store.messageCount(connectionId: "whatsapp", roomId: Self.dmChat) == 0)

            // Allowlisted rows do not touch the counter.
            _ = try await service.handleWatchEvent([
                "id": "WAMID-1", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+15551234567", "text": "hello",
                "is_from_me": false,
            ])
            #expect(service.watchDroppedNonAllowlistedCount() == 2)
        }
    }

    @Test func selfMessagesDispatchOnlyWhenIgnoreSelfMessagesIsOff() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let service = WhatsAppConnectionService(
                transport: FakeWhatsAppTransport(),
                messageStore: store
            )
            let selfRow: (String) -> [String: Any] = { id in
                [
                    "id": id, "chat": "15551234567@s.whatsapp.net",
                    "sender_number": "+15551234567", "text": "note to self",
                    "is_from_me": true,
                ]
            }

            // Default policy (ignore on): the linked account's own messages
            // are rejected at authorization, not stored.
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    ignoreSelfMessages: true,
                    receiveEnabled: true
                )
            )
            let ignored = try await service.handleWatchEvent(selfRow("WAMID-self-1"))
            #expect(ignored.stored == 0)

            // Operator turns Ignore Self Messages off (the single-number
            // test loop): the same shape of row now stores.
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    ignoreSelfMessages: false,
                    receiveEnabled: true
                )
            )
            let accepted = try await service.handleWatchEvent(selfRow("WAMID-self-2"))
            #expect(accepted.stored == 1)
            #expect(try store.messageCount(connectionId: "whatsapp", roomId: Self.dmChat) == 1)
        }
    }

    @Test func watchSubscribePassesMediaParametersOnlyWhenIngestionIsOn() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let transport = FakeWhatsAppTransport()
            transport.setResponse(
                for: WhatsAppRPCMethod.watchSubscribe, result: ["subscribed": true]
            )
            transport.onCall(WhatsAppRPCMethod.watchSubscribe) {
                transport.emitNotification(
                    method: WhatsAppRPCNotification.helperTerminated, params: [:]
                )
            }
            let service = WhatsAppConnectionService(transport: transport, messageStore: store)

            // Ingestion off: the helper is told nothing about media and
            // keeps emitting placeholders only.
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    receiveEnabled: true
                )
            )
            await #expect(throws: WhatsAppConnectionServiceError.self) {
                try await service.runWatchSession(onReady: {}, onBatch: { _ in })
            }
            var subscribe = transport.calls(for: WhatsAppRPCMethod.watchSubscribe).last
            #expect(subscribe?["download_media"] == nil)

            // Ingestion on: download parameters bind at subscribe time.
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    receiveEnabled: true,
                    attachmentIngestionEnabled: true,
                    maxAttachmentBytes: 5 * 1_024 * 1_024
                )
            )
            transport.clearCalls()
            await #expect(throws: WhatsAppConnectionServiceError.self) {
                try await service.runWatchSession(onReady: {}, onBatch: { _ in })
            }
            subscribe = transport.calls(for: WhatsAppRPCMethod.watchSubscribe).last
            #expect(subscribe?["download_media"] as? Bool == true)
            #expect(subscribe?["max_media_bytes"] as? Int == 5 * 1_024 * 1_024)
            #expect(
                subscribe?["media_dir"] as? String
                    == WhatsAppConnectionConfiguration.mediaDirectoryURL().path
            )
        }
    }

    @Test func readReceiptsFireOnlyForStoredMessagesWhenEnabled() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let transport = FakeWhatsAppTransport()
            transport.setResponse(for: WhatsAppRPCMethod.read, result: [:])
            let service = WhatsAppConnectionService(transport: transport, messageStore: store)

            // Toggle off (the default): no read RPC ever fires.
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    receiveEnabled: true
                )
            )
            _ = try await service.handleWatchEvent([
                "id": "WAMID-RR-0", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+15551234567", "text": "no ticks",
                "is_from_me": false,
            ])
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(transport.calls(for: WhatsAppRPCMethod.read).isEmpty)

            // Toggle on: a freshly stored allowlisted message is marked
            // read (asynchronously — the receipt never blocks the ingest).
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    receiveEnabled: true,
                    sendReadReceipts: true
                )
            )
            _ = try await service.handleWatchEvent([
                "id": "WAMID-RR-1", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+15551234567", "text": "blue ticks",
                "is_from_me": false,
            ])
            var readCalls: [[String: Any]] = []
            for _ in 0 ..< 100 {
                readCalls = transport.calls(for: WhatsAppRPCMethod.read)
                if !readCalls.isEmpty { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(readCalls.count == 1)
            #expect(readCalls.last?["chat"] as? String == Self.dmChat)
            #expect(readCalls.last?["sender"] as? String == Self.dmChat)
            #expect(readCalls.last?["message_ids"] as? [String] == ["WAMID-RR-1"])

            // A WAMID replay stores nothing and therefore acks nothing.
            _ = try await service.handleWatchEvent([
                "id": "WAMID-RR-1", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+15551234567", "text": "blue ticks",
                "is_from_me": false,
            ])
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(transport.calls(for: WhatsAppRPCMethod.read).count == 1)
        }
    }

    @Test func normalizeInboundCapturesAttachmentsQuotesAndLIDSelfMentions() async throws {
        try await withIsolatedWhatsAppStores {
            let service = WhatsAppConnectionService(transport: FakeWhatsAppTransport())

            // Downloaded media rides along as a stored attachment; the
            // placeholder stays in the content.
            let media = service.normalizeInbound([
                "id": "WAMID-1", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+15551234567", "text": "vacation",
                "media_type": "image", "media_path": "/tmp/wa-media/photo.jpg",
                "media_mime": "image/jpeg", "media_size": 2_048,
                "filename": "photo.jpg", "is_from_me": false,
            ])
            #expect(media?.content == "[image] vacation")
            #expect(media?.attachments.count == 1)
            let attachment = media?.attachments.first
            #expect(attachment?.providerId == "/tmp/wa-media/photo.jpg")
            #expect(attachment?.kind == .image)
            #expect(attachment?.contentType == "image/jpeg")
            #expect(attachment?.sizeBytes == 2_048)

            // Quoted-reply metadata: the quoted sender normalizes into the
            // shared id space.
            let quoted = service.normalizeInbound([
                "id": "WAMID-2", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+15551234567", "text": "yes exactly",
                "quote_id": "WAMID-1", "quote_sender": "15559990000@s.whatsapp.net",
                "quote_text": "did you mean tuesday?", "is_from_me": false,
            ])
            #expect(quoted?.quotedMessageId == "WAMID-1")
            #expect(quoted?.quotedSenderId == "+15559990000")
            #expect(quoted?.quotedText == "did you mean tuesday?")
            // No quote id means no dangling quote fields.
            let plain = service.normalizeInbound([
                "id": "WAMID-3", "chat": "15551234567@s.whatsapp.net",
                "text": "plain", "quote_text": "orphaned", "is_from_me": false,
            ])
            #expect(plain?.quotedMessageId == nil)
            #expect(plain?.quotedText == nil)

            // Group mention by LID: the account's hidden-user address must
            // count as a self-mention even when no phone JID appears.
            let lidMention = service.normalizeInbound(
                [
                    "id": "WAMID-4", "chat": "1203630001@g.us",
                    "sender_number": "+15551234567", "text": "@hidden ping",
                    "is_group": true, "is_from_me": false,
                    "mentions": ["987654321@lid"],
                ],
                selfJID: "15550001111.0:1@s.whatsapp.net",
                selfLID: "987654321@lid"
            )
            #expect(lidMention?.mentionsSelf == true)
        }
    }

    @Test func storedRowsExposeReplyThreadIdQuoteAndAttachments() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let service = WhatsAppConnectionService(
                transport: FakeWhatsAppTransport(),
                messageStore: store
            )
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    receiveEnabled: true
                )
            )

            _ = try await service.handleWatchEvent([
                "id": "WAMID-ROW", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+15551234567", "text": "see photo",
                "media_type": "image", "media_path": "/tmp/wa-media/pic.jpg",
                "media_mime": "image/jpeg", "media_size": 512,
                "quote_id": "WAMID-EARLIER",
                "is_from_me": false, "timestamp": 1_753_795_260,
            ])

            let read = try service.readChat(chatId: Self.dmChat, limit: 10)
            let row = (read["messages"] as? [[String: Any]])?.first
            // Every row advertises the thread id an agent feeds back to
            // `reply_thread` to quote-reply to it.
            #expect(row?["reply_thread_id"] as? String == "\(Self.dmChat):WAMID-ROW")
            // A quoted reply also exposes what it quoted.
            #expect(row?["quoted_message_id"] as? String == "WAMID-EARLIER")
            let attachments = row?["attachments"] as? [[String: Any]]
            #expect(attachments?.count == 1)
            #expect(attachments?.first?["path"] as? String == "/tmp/wa-media/pic.jpg")
            #expect(attachments?.first?["kind"] as? String == "image")
        }
    }

    @Test func normalizeInboundHandlesMediaPlaceholdersAndMentions() async throws {
        try await withIsolatedWhatsAppStores {
            let service = WhatsAppConnectionService(transport: FakeWhatsAppTransport())

            // Media placeholder with caption.
            let media = service.normalizeInbound([
                "id": "WAMID-1", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+15551234567", "text": "look at this",
                "media_type": "image", "is_from_me": false,
            ])
            #expect(media?.content == "[image] look at this")

            // Media without caption keeps the placeholder alone.
            let bare = service.normalizeInbound([
                "id": "WAMID-2", "chat": "15551234567@s.whatsapp.net",
                "media_type": "audio", "is_from_me": false,
            ])
            #expect(bare?.content == "[audio]")

            // No id or no content: not ingestible.
            #expect(
                service.normalizeInbound([
                    "chat": "15551234567@s.whatsapp.net", "text": "hi",
                ]) == nil
            )
            #expect(
                service.normalizeInbound([
                    "id": "WAMID-3", "chat": "15551234567@s.whatsapp.net",
                ]) == nil
            )

            // Group mention of the linked account is detected against the
            // subscription's self JID.
            let mentioned = service.normalizeInbound(
                [
                    "id": "WAMID-4", "chat": "1203630001@g.us",
                    "sender_number": "+15551234567", "text": "@bot ping",
                    "is_group": true, "is_from_me": false,
                    "mentions": ["15550001111@s.whatsapp.net"],
                ],
                selfJID: "15550001111.0:1@s.whatsapp.net"
            )
            #expect(mentioned?.isGroup == true)
            #expect(mentioned?.mentionsSelf == true)
            #expect(mentioned?.roomId == "1203630001@g.us")
        }
    }

    @Test func watchSessionSubscribesProcessesAndThrowsWhenHelperDies() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let transport = FakeWhatsAppTransport()
            transport.setResponse(
                for: WhatsAppRPCMethod.watchSubscribe,
                result: ["subscribed": true, "self_jid": "15550001111.0:1@s.whatsapp.net"]
            )
            transport.onCall(WhatsAppRPCMethod.watchSubscribe) {
                transport.emitNotification(
                    method: WhatsAppRPCNotification.message,
                    params: [
                        "id": "WAMID-1", "chat": "15551234567@s.whatsapp.net",
                        "sender_number": "+15551234567", "text": "hello",
                        "is_from_me": false,
                    ]
                )
                transport.emitNotification(
                    method: WhatsAppRPCNotification.helperTerminated,
                    params: [:]
                )
            }
            let service = WhatsAppConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [Self.dmChat],
                    receiveEnabled: true
                )
            )

            let collector = WatchBatchCollector()
            await #expect(throws: WhatsAppConnectionServiceError.self) {
                try await service.runWatchSession(
                    onReady: { collector.markReady() },
                    onBatch: { collector.append($0) }
                )
            }

            #expect(collector.isReady)
            #expect(collector.batches.map(\.stored) == [1])
            #expect(try store.messageCount(connectionId: "whatsapp", roomId: Self.dmChat) == 1)
        }
    }

    @Test func watchSessionIsANoOpUntilReceiveIsFullyConfigured() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let transport = FakeWhatsAppTransport()
            let service = WhatsAppConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    senderAllowlist: [],
                    receiveEnabled: true
                )
            )

            try await service.runWatchSession(onReady: {}, onBatch: { _ in })
            #expect(transport.calls(for: WhatsAppRPCMethod.watchSubscribe).isEmpty)

            let summary = try await service.handleWatchEvent([
                "id": "WAMID-1", "chat": "15551234567@s.whatsapp.net",
                "sender_number": "+15551234567", "text": "hello",
                "is_from_me": false,
            ])
            #expect(
                summary
                    == AgentChannelReceiveBatchSummary(
                        received: 0, stored: 0, dispatchAttempted: 0, dispatchSuppressed: 0
                    )
            )
        }
    }

    @Test func listChatsFallsBackToConfiguredIdsWithoutHelper() async throws {
        try await withIsolatedWhatsAppStores {
            let transport = FakeWhatsAppTransport()
            transport.setHelperAvailable(false)
            let service = WhatsAppConnectionService(transport: transport)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    readableChatIds: [Self.dmChat],
                    writableChatIds: [Self.groupChat],
                    writeEnabled: true
                )
            )

            let chats = try await service.listChats()
            let ids = chats.compactMap { $0["id"] as? String }
            #expect(ids.sorted() == [Self.groupChat, Self.dmChat].sorted())
            let group = chats.first { ($0["id"] as? String) == Self.groupChat }
            #expect(group?["kind"] as? String == "group")
            #expect(group?["write_allowed"] as? Bool == true)
            #expect(group?["read_allowed"] as? Bool == false)
        }
    }

    @Test func dispatcherRoutesReplyEditAndDeleteToWhatsApp() async throws {
        try await withIsolatedWhatsAppStores {
            let transport = FakeWhatsAppTransport()
            transport.setResponse(for: WhatsAppRPCMethod.send, result: ["message_id": "WAMID-R"])
            transport.setResponse(for: WhatsAppRPCMethod.messageEdit, result: [:])
            transport.setResponse(for: WhatsAppRPCMethod.messageRevoke, result: [:])
            let whatsappService = WhatsAppConnectionService(transport: transport)
            let service = AgentChannelConnectionService(
                discordService: .shared,
                whatsappService: whatsappService
            )
            try whatsappService.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true
                )
            )

            // The native connection advertises the full action set the
            // dispatcher routes.
            let row = service.listConnections().first { ($0["id"] as? String) == "whatsapp" }
            let actions = Set(row?["standard_actions"] as? [String] ?? [])
            #expect(actions.contains("reply_thread"))
            #expect(actions.contains("edit_message"))
            #expect(actions.contains("delete_message"))

            // reply_thread with the `<chat_id>:<message_id>` thread id turns
            // into a quoted send.
            let reply = try await service.replyThread(
                connectionId: "whatsapp",
                threadId: "\(Self.dmChat):WAMID-1",
                content: "quoted reply",
                confirmSend: true
            )
            #expect(reply["standard_kind"] as? String == "thread_reply_sent")
            let sendCall = transport.calls(for: WhatsAppRPCMethod.send).last
            #expect(sendCall?["quote_id"] as? String == "WAMID-1")
            #expect(sendCall?["to"] as? String == Self.dmChat)

            _ = try await service.editMessage(
                connectionId: "whatsapp", roomId: Self.dmChat, messageId: "WAMID-R",
                content: "fixed", confirmSend: true
            )
            let editCall = transport.calls(for: WhatsAppRPCMethod.messageEdit).last
            #expect(editCall?["message_id"] as? String == "WAMID-R")
            #expect(editCall?["text"] as? String == "fixed")

            _ = try await service.deleteMessage(
                connectionId: "whatsapp", roomId: Self.dmChat, messageId: "WAMID-R",
                confirmSend: true
            )
            #expect(
                transport.calls(for: WhatsAppRPCMethod.messageRevoke).last?["message_id"]
                    as? String == "WAMID-R"
            )
        }
    }

    @Test func quotedReplyValidatesThreadIdAndCarriesStoredQuoteContext() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            _ = try store.recordMessages([
                AgentChannelStoredMessage(
                    connectionId: "whatsapp",
                    roomId: Self.dmChat,
                    providerMessageId: "WAMID-Q",
                    direction: .inbound,
                    authorId: Self.dmChat,
                    content: "original question"
                )
            ])
            let transport = FakeWhatsAppTransport()
            transport.setResponse(for: WhatsAppRPCMethod.send, result: ["message_id": "WAMID-A"])
            let service = WhatsAppConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true
                )
            )

            // Malformed thread ids fail before any gating or helper call.
            await #expect(throws: WhatsAppConnectionServiceError.invalidThreadId("no-colon")) {
                _ = try await service.replyToThread(
                    threadId: "no-colon", content: "hi", confirmSend: true
                )
            }
            await #expect(
                throws: WhatsAppConnectionServiceError.invalidThreadId("\(Self.dmChat):")
            ) {
                _ = try await service.replyToThread(
                    threadId: "\(Self.dmChat):", content: "hi", confirmSend: true
                )
            }
            #expect(transport.calls(for: WhatsAppRPCMethod.send).isEmpty)

            // A valid reply quotes the stored message: the helper receives
            // the quote id plus the original sender and text for the stanza.
            let result = try await service.replyToThread(
                threadId: "\(Self.dmChat):WAMID-Q",
                content: "the answer",
                confirmSend: true
            )
            #expect(result["quoted_message_id"] as? String == "WAMID-Q")
            #expect(result["thread_id"] as? String == "\(Self.dmChat):WAMID-Q")
            let call = transport.calls(for: WhatsAppRPCMethod.send).last
            #expect(call?["quote_id"] as? String == "WAMID-Q")
            #expect(call?["quote_sender"] as? String == Self.dmChat)
            #expect(call?["quote_text"] as? String == "original question")
        }
    }

    @Test func editRejectsUnchunkableContentAndDeleteResolvesStoredAuthor() async throws {
        try await withIsolatedWhatsAppStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            _ = try store.recordMessages([
                AgentChannelStoredMessage(
                    connectionId: "whatsapp",
                    roomId: Self.dmChat,
                    providerMessageId: "WAMID-D",
                    direction: .inbound,
                    authorId: Self.dmChat,
                    content: "delete me"
                )
            ])
            let transport = FakeWhatsAppTransport()
            transport.setResponse(for: WhatsAppRPCMethod.messageEdit, result: [:])
            transport.setResponse(for: WhatsAppRPCMethod.messageRevoke, result: [:])
            let service = WhatsAppConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true
                )
            )

            // Both actions require explicit confirmation.
            await #expect(throws: WhatsAppConnectionServiceError.sendConfirmationRequired) {
                _ = try await service.editMessage(
                    chatId: Self.dmChat, messageId: "WAMID-D", content: "x", confirmSend: false
                )
            }
            await #expect(throws: WhatsAppConnectionServiceError.sendConfirmationRequired) {
                _ = try await service.deleteMessage(
                    chatId: Self.dmChat, messageId: "WAMID-D", confirmSend: false
                )
            }

            // An edit replaces a single frame — content that would need
            // chunking cannot express itself as an edit.
            let tooLong = String(
                repeating: "a",
                count: AgentChannelMessageFormatter.plainTextChunkLimit + 1
            )
            await #expect(throws: WhatsAppConnectionServiceError.messageTooLong) {
                _ = try await service.editMessage(
                    chatId: Self.dmChat, messageId: "WAMID-D", content: tooLong,
                    confirmSend: true
                )
            }
            #expect(transport.calls(for: WhatsAppRPCMethod.messageEdit).isEmpty)

            // Revoking someone else's message rides the stored author along
            // in the revoke key (needed for group-admin revokes).
            _ = try await service.deleteMessage(
                chatId: Self.dmChat, messageId: "WAMID-D", confirmSend: true
            )
            let revoke = transport.calls(for: WhatsAppRPCMethod.messageRevoke).last
            #expect(revoke?["sender"] as? String == Self.dmChat)
        }
    }

    @Test func sendAttachmentEnforcesFenceSizeAndConfirmation() async throws {
        try await withIsolatedWhatsAppStores {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-wa-att-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let insidePath = root.appendingPathComponent("photo.jpg").path
            try Data(repeating: 0xFF, count: 128).write(to: URL(fileURLWithPath: insidePath))

            let transport = FakeWhatsAppTransport()
            transport.setResponse(
                for: WhatsAppRPCMethod.sendAttachment, result: ["message_id": "WAMID-M"]
            )
            let service = WhatsAppConnectionService(transport: transport)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true,
                    attachmentIngestionEnabled: true,
                    allowedAttachmentRoots: [root.path]
                )
            )

            await #expect(throws: WhatsAppConnectionServiceError.sendConfirmationRequired) {
                _ = try await service.sendAttachment(
                    chatId: Self.dmChat, path: insidePath, caption: nil, confirmSend: false
                )
            }
            // Outside the allowlisted roots: refused before helper dispatch.
            await #expect(
                throws: WhatsAppConnectionServiceError.attachmentNotAllowed("/etc/hosts")
            ) {
                _ = try await service.sendAttachment(
                    chatId: Self.dmChat, path: "/etc/hosts", caption: nil, confirmSend: true
                )
            }
            #expect(transport.calls(for: WhatsAppRPCMethod.sendAttachment).isEmpty)

            // Allowed path with caption dispatches to the helper.
            let result = try await service.sendAttachment(
                chatId: Self.dmChat, path: insidePath, caption: "  look  ", confirmSend: true
            )
            #expect(result["kind"] as? String == "whatsapp_attachment_sent")
            let call = transport.calls(for: WhatsAppRPCMethod.sendAttachment).last
            #expect(call?["to"] as? String == Self.dmChat)
            #expect(call?["path"] as? String == insidePath)
            #expect(call?["caption"] as? String == "look")

            // Over the size cap: refused with the configured limit. The cap
            // clamps to its floor (64 KiB), so build a file just above it.
            let bigPath = root.appendingPathComponent("big.bin").path
            try Data(repeating: 0x00, count: 64 * 1_024 + 1)
                .write(to: URL(fileURLWithPath: bigPath))
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true,
                    attachmentIngestionEnabled: true,
                    allowedAttachmentRoots: [root.path],
                    maxAttachmentBytes: 1
                )
            )
            await #expect(
                throws: WhatsAppConnectionServiceError.attachmentTooLarge(64 * 1_024)
            ) {
                _ = try await service.sendAttachment(
                    chatId: Self.dmChat, path: bigPath, caption: nil, confirmSend: true
                )
            }
        }
    }

    @Test func artifactReplyStagesIntoMediaRootAndHonorsAttachmentToggle() async throws {
        try await withIsolatedWhatsAppStores {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-wa-artreply-\(UUID().uuidString)", isDirectory: true)
            let artifactsDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-wa-artsrc-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: artifactsDir)
            }
            // The artifact lives outside the media fence, like the real
            // ~/.osaurus/artifacts store does.
            let artifactPath = artifactsDir.appendingPathComponent("cat.png").path
            try Data(repeating: 0xAB, count: 64).write(to: URL(fileURLWithPath: artifactPath))

            let transport = FakeWhatsAppTransport()
            transport.setResponse(
                for: WhatsAppRPCMethod.sendAttachment, result: ["message_id": "WAMID-A"]
            )
            let service = WhatsAppConnectionService(transport: transport)

            // Attachments toggle off: refused before any staging or dispatch.
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true,
                    attachmentIngestionEnabled: false,
                    allowedAttachmentRoots: [root.path]
                )
            )
            await #expect(throws: WhatsAppConnectionServiceError.attachmentNotAllowed(artifactPath)) {
                try await service.sendArtifactReply(
                    chatId: Self.dmChat, hostPath: artifactPath, caption: nil
                )
            }
            #expect(transport.calls(for: WhatsAppRPCMethod.sendAttachment).isEmpty)

            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(
                    writableChatIds: [Self.dmChat],
                    writeEnabled: true,
                    attachmentIngestionEnabled: true,
                    allowedAttachmentRoots: [root.path]
                )
            )
            try await service.sendArtifactReply(
                chatId: Self.dmChat, hostPath: artifactPath, caption: "your cat"
            )
            let call = transport.calls(for: WhatsAppRPCMethod.sendAttachment).last
            #expect(call?["to"] as? String == Self.dmChat)
            #expect(call?["caption"] as? String == "your cat")
            let stagedPath = try #require(call?["path"] as? String)
            #expect(stagedPath.hasPrefix(root.appendingPathComponent("agent-replies").path + "/"))
            #expect(stagedPath.hasSuffix("-cat.png"))
            // The staged copy is transient: cleaned up after the send.
            #expect(!FileManager.default.fileExists(atPath: stagedPath))
            // The original artifact is untouched.
            #expect(FileManager.default.fileExists(atPath: artifactPath))
        }
    }

    @Test func listConnectionsMarksWhatsAppConfiguredOnlyWithHelperAndChats() async throws {
        try await withIsolatedWhatsAppStores {
            let transport = FakeWhatsAppTransport()
            let whatsappService = WhatsAppConnectionService(transport: transport)
            let service = AgentChannelConnectionService(
                discordService: .shared,
                whatsappService: whatsappService
            )
            try whatsappService.saveConfiguration(
                WhatsAppConnectionConfiguration(readableChatIds: [Self.dmChat])
            )
            func whatsappRow() -> [String: Any]? {
                service.listConnections().first { ($0["id"] as? String) == "whatsapp" }
            }

            // Allowlisted chats but no helper: not configured.
            transport.setHelperAvailable(false)
            var row = whatsappRow()
            #expect(row?["configured"] as? Bool == false)
            #expect(row?["helper_available"] as? Bool == false)
            // No probe has run: the cached link status reports unlinked.
            #expect(row?["credential_saved"] as? Bool == false)

            transport.setHelperAvailable(true)
            row = whatsappRow()
            #expect(row?["configured"] as? Bool == true)

            // A successful probe flips the linked/credential projection.
            transport.setLinkStatus(
                WhatsAppLinkStatus(
                    helperVersion: "0.1.0",
                    linked: true,
                    selfJID: "15550001111.0:1@s.whatsapp.net",
                    selfNumber: "+15550001111",
                    rpcMethods: [],
                    probed: true
                )
            )
            _ = await whatsappService.probeAndCacheLinkStatus()
            row = whatsappRow()
            #expect(row?["credential_saved"] as? Bool == true)
            #expect(row?["linked"] as? Bool == true)

            // Helper alone without any allowlisted chat is not configured.
            try whatsappService.saveConfiguration(WhatsAppConnectionConfiguration())
            row = whatsappRow()
            #expect(row?["configured"] as? Bool == false)
        }
    }

    @Test func transportRuntimeFailsHardWhenHelperUnavailable() async throws {
        try await withIsolatedWhatsAppStores {
            let transport = FakeWhatsAppTransport()
            transport.setHelperAvailable(false)
            let runtime = WhatsAppWatchTransportRuntime(
                service: WhatsAppConnectionService(transport: transport),
                healthCenter: AgentChannelTransportHealthCenter()
            )

            let result = await runtime.runStep()
            #expect(result.disposition == .failed)
            #expect(result.retryDelay == 300)
            #expect(result.health.status == .failed)
            #expect(result.health.transportId == "whatsapp_watch")
        }
    }

    @Test func transportRuntimeWaitsForLinkedAccountInsteadOfSubscribing() async throws {
        try await withIsolatedWhatsAppStores {
            let transport = FakeWhatsAppTransport()
            // Helper present but no linked session in the store.
            transport.setLinkStatus(
                WhatsAppLinkStatus(
                    helperVersion: "0.1.0",
                    linked: false,
                    selfJID: nil,
                    selfNumber: nil,
                    rpcMethods: [],
                    probed: true
                )
            )
            let runtime = WhatsAppWatchTransportRuntime(
                service: WhatsAppConnectionService(transport: transport),
                healthCenter: AgentChannelTransportHealthCenter()
            )

            let result = await runtime.runStep()
            // Subscribing without a linked session can only fail — the
            // runtime must wait for the QR pairing, not spawn a doomed
            // session.
            #expect(result.disposition == .skipped)
            #expect(result.retryDelay == 60)
            #expect(result.health.status == .degraded)
            #expect(transport.calls(for: WhatsAppRPCMethod.watchSubscribe).isEmpty)
        }
    }

    @Test func diagnosticsSummarizeGatingWithoutLeakingPaths() async throws {
        try await withIsolatedWhatsAppStores {
            let transport = FakeWhatsAppTransport()
            transport.setLinkStatus(
                WhatsAppLinkStatus(
                    helperVersion: "0.1.0",
                    linked: false,
                    selfJID: nil,
                    selfNumber: nil,
                    rpcMethods: [],
                    probed: true
                )
            )
            let service = WhatsAppConnectionService(transport: transport)
            try service.saveConfiguration(
                WhatsAppConnectionConfiguration(readableChatIds: [Self.dmChat])
            )

            let diagnostics = await service.diagnostics()
            #expect(!diagnostics.linked)
            #expect(!diagnostics.receiveReady)
            // Diagnostics verify the real on-disk helper binary (the fake
            // transport only fakes RPC), so the unit environment reports the
            // helper gate; the QR-link gate is next once a helper exists.
            #expect(
                diagnostics.failures.contains {
                    $0.contains("helper is not usable") || $0.contains("QR")
                }
            )
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            #expect(!diagnostics.failures.joined().contains(home))
            #expect(!diagnostics.notes.joined().contains(home))
        }
    }

    // MARK: - Isolation helper

    private func withIsolatedWhatsAppStores(
        _ body: @Sendable () async throws -> Void
    ) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let previousDirectory = WhatsAppConnectionConfigurationStore.overrideDirectory
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-whatsapp-tests-\(UUID().uuidString)", isDirectory: true)
            WhatsAppConnectionConfigurationStore.overrideDirectory = directory
            defer {
                WhatsAppConnectionConfigurationStore.overrideDirectory = previousDirectory
                try? FileManager.default.removeItem(at: directory)
            }
            try await body()
        }
    }
}

// MARK: - Fakes

/// Scriptable in-memory stand-in for the `osaurus-wa rpc` process transport.
private final class FakeWhatsAppTransport: WhatsAppRPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var helperAvailable = true
    private var linkStatus = WhatsAppLinkStatus(
        helperVersion: "0.1.0-test",
        linked: true,
        selfJID: "15550001111.0:1@s.whatsapp.net",
        selfNumber: "+15550001111",
        rpcMethods: [],
        probed: true
    )
    private var responses: [String: [String: Any]] = [:]
    private var errors: [String: WhatsAppRPCError] = [:]
    private var recordedCalls: [(method: String, params: [String: Any])] = []
    private var callObservers: [String: @Sendable () -> Void] = [:]
    private var notificationHandler: (@Sendable (String, Data) -> Void)?

    func setHelperAvailable(_ available: Bool) {
        lock.withLock { helperAvailable = available }
    }

    func setLinkStatus(_ status: WhatsAppLinkStatus) {
        lock.withLock { linkStatus = status }
    }

    func setResponse(for method: String, result: [String: Any]) {
        lock.withLock { responses[method] = result }
    }

    func setError(for method: String, error: WhatsAppRPCError) {
        lock.withLock { errors[method] = error }
    }

    /// Run `observer` after `method` is called (e.g. emit watch
    /// notifications once the subscription is established).
    func onCall(_ method: String, _ observer: @escaping @Sendable () -> Void) {
        lock.withLock { callObservers[method] = observer }
    }

    /// Simulate a helper-initiated notification line.
    func emitNotification(method: String, params: [String: Any]) {
        let handler = lock.withLock { notificationHandler }
        let paramsJSON = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        handler?(method, paramsJSON)
    }

    func calls(for method: String) -> [[String: Any]] {
        lock.withLock { recordedCalls.filter { $0.method == method }.map(\.params) }
    }

    func clearCalls() {
        lock.withLock { recordedCalls.removeAll() }
    }

    func call(
        method: String,
        params: [String: any Sendable],
        timeout: TimeInterval
    ) async throws -> WhatsAppRPCResponse {
        let (error, result, observer):
            (WhatsAppRPCError?, [String: Any], (@Sendable () -> Void)?) = lock.withLock {
                recordedCalls.append((method, params as [String: Any]))
                return (errors[method], responses[method] ?? [:], callObservers[method])
            }
        observer?()
        if let error { throw error }
        return WhatsAppRPCResponse(resultJSON: try JSONSerialization.data(withJSONObject: result))
    }

    func probeLinkStatus() async -> WhatsAppLinkStatus {
        lock.withLock { linkStatus }
    }

    func isHelperAvailable() -> Bool {
        lock.withLock { helperAvailable }
    }

    func setNotificationHandler(
        _ handler: (@Sendable (_ method: String, _ paramsJSON: Data) -> Void)?
    ) async {
        lock.withLock { notificationHandler = handler }
    }

    func shutdown() async {}
}

/// Lock-protected collector for watch-session callbacks.
private final class WatchBatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var collected: [AgentChannelReceiveBatchSummary] = []

    var isReady: Bool { lock.withLock { ready } }
    var batches: [AgentChannelReceiveBatchSummary] { lock.withLock { collected } }

    func markReady() { lock.withLock { ready = true } }
    func append(_ batch: AgentChannelReceiveBatchSummary) {
        lock.withLock { collected.append(batch) }
    }
}
