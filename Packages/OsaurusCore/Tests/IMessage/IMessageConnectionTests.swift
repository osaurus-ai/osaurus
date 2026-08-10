//
//  IMessageConnectionTests.swift
//  osaurusTests
//
//  Fixture coverage for the native iMessage agent channel: JSON-RPC framing,
//  configuration policy (allowlists, clamps, attachment fencing, advanced
//  gating), the connection service against a fake helper transport, the
//  watch-based receive pipeline (resume, dedupe, cursor advancement), and
//  the watch transport runtime.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Pure framing / redaction

struct IMessageRPCFramingTests {

    @Test func encodeRequestProducesNewlineFramedJSONRPC() throws {
        let frame = try IMessageRPCFraming.encodeRequest(
            id: 7,
            method: "send",
            params: ["chat_id": "iMessage;-;+15551234567", "text": "hi"]
        )

        #expect(frame.last == 0x0A)
        let object =
            try JSONSerialization.jsonObject(with: frame.dropLast()) as? [String: Any] ?? [:]
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 7)
        #expect(object["method"] as? String == "send")
        let params = object["params"] as? [String: Any]
        #expect(params?["chat_id"] as? String == "iMessage;-;+15551234567")
        // Exactly one line: embedded newlines would break the framing.
        #expect(!frame.dropLast().contains(0x0A))
    }

    /// Live-captured `imsg status --json` output from the pinned 0.13.4
    /// release (trimmed `message`/`selectors` fields only). Locks the parser
    /// to the real schema: `version`, `advanced_features`, `rpc_methods`,
    /// `sip` — there is no sign-in or full-disk-access key.
    @Test func capabilitiesParseRealStatusPayload() {
        let payload = """
            {"selectors":{},"rpc_methods":["chats.list","chats.create","messages.history",\
            "send","send.rich","send.attachment","poll.send","tapback","typing","read",\
            "message.edit","message.unsend","group.rename","group.addParticipant",\
            "group.removeParticipant","group.leave","handles.check"],\
            "bridge_version":0,"version":"0.13.4","sip":"enabled","read_receipts":false,\
            "typing_indicators":false,"basic_features":true,"advanced_features":false,\
            "message":"System Integrity Protection (SIP) is enabled.","v2_ready":false}
            """
        let capabilities = IMessageCapabilities.parse(statusJSON: Data(payload.utf8))
        #expect(capabilities?.probed == true)
        #expect(capabilities?.helperVersion == "0.13.4")
        #expect(capabilities?.bridgeAvailable == false)
        #expect(capabilities?.sipStatus == "enabled")
        #expect(capabilities?.rpcMethods.contains("message.edit") == true)
        // Bridge inactive: advanced methods are advertised but not usable.
        #expect(capabilities?.supportsAdvanced("message.edit") == false)

        #expect(IMessageCapabilities.parse(statusJSON: Data("not json".utf8)) == nil)
        #expect(IMessageCapabilities.parse(statusJSON: Data("{}".utf8)) == nil)
    }

    /// Every RPC method name Osaurus dispatches must exist in the pinned
    /// helper's advertised surface; a rename upstream must fail this lock
    /// instead of silently degrading to "method not found" at runtime.
    @Test func dispatchedMethodNamesMatchPinnedHelperSurface() {
        let advertised: Set<String> = [
            "chats.list", "chats.create", "chats.delete", "chats.markUnread",
            "messages.stats", "messages.history", "watch.subscribe", "watch.unsubscribe",
            "send", "send.rich", "send.attachment", "send.sticker", "messages.scheduled",
            "poll.send", "messages.poll.send", "poll.vote", "messages.poll.vote",
            "poll.unvote", "polls.unvote", "messages.poll.unvote", "tapback", "typing",
            "read", "message.edit", "message.unsend", "message.delete",
            "message.notifyAnyways", "message.send_status", "group.rename",
            "group.setIcon", "group.addParticipant", "group.removeParticipant",
            "group.leave", "contacts.shouldShareContact", "contacts.shareContactCard",
            "handles.check",
        ]
        let dispatched = [
            IMessageRPCMethod.listChats,
            IMessageRPCMethod.watchSubscribe,
            IMessageRPCMethod.watchUnsubscribe,
            IMessageRPCMethod.send,
            IMessageRPCMethod.sendRich,
            IMessageRPCMethod.edit,
            IMessageRPCMethod.unsend,
            IMessageRPCMethod.tapback,
            IMessageRPCMethod.typing,
            IMessageRPCMethod.sendAttachment,
            IMessageRPCMethod.poll,
            IMessageRPCMethod.groupRename,
            IMessageRPCMethod.groupAddParticipant,
            IMessageRPCMethod.groupRemoveParticipant,
        ]
        for method in dispatched {
            #expect(advertised.contains(method), "\(method) is not an imsg RPC method")
        }
    }

    @Test func encodeRequestOmitsEmptyParams() throws {
        let frame = try IMessageRPCFraming.encodeRequest(id: 1, method: "status", params: [:])
        let object =
            try JSONSerialization.jsonObject(with: frame.dropLast()) as? [String: Any] ?? [:]
        #expect(object["params"] == nil)
    }

    @Test func parseResponseLineDecodesResultErrorAndNotification() throws {
        let success = IMessageRPCFraming.parseResponseLine(
            Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#.utf8)
        )
        #expect(success?.id == 3)
        #expect(success?.errorCode == nil)
        let result =
            try JSONSerialization.jsonObject(with: #require(success?.resultJSON)) as? [String: Any]
        #expect(result?["ok"] as? Bool == true)

        let failure = IMessageRPCFraming.parseResponseLine(
            Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"no such method"}}"#.utf8)
        )
        #expect(failure?.id == 4)
        #expect(failure?.errorCode == -32601)
        #expect(failure?.errorMessage == "no such method")

        // Notifications (no id) still parse; the reader routes them to the
        // notification handler by method instead of dropping them.
        let notification = IMessageRPCFraming.parseResponseLine(
            Data(#"{"jsonrpc":"2.0","method":"message","params":{}}"#.utf8)
        )
        #expect(notification != nil)
        #expect(notification?.id == nil)

        #expect(IMessageRPCFraming.parseResponseLine(Data("not json".utf8)) == nil)
    }

    @Test func parseNotificationLineExtractsMethodAndParams() throws {
        let line = Data(
            #"{"jsonrpc":"2.0","method":"message","params":{"subscription":1,"message":{"guid":"g-1"}}}"#
                .utf8
        )
        let notification = try #require(IMessageRPCFraming.parseNotificationLine(line))
        #expect(notification.method == "message")
        let params =
            try JSONSerialization.jsonObject(with: notification.paramsJSON) as? [String: Any]
        #expect(params?["subscription"] as? Int == 1)
        #expect((params?["message"] as? [String: Any])?["guid"] as? String == "g-1")

        // Responses (with an id) are never notifications.
        #expect(
            IMessageRPCFraming.parseNotificationLine(
                Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8)
            ) == nil
        )
        #expect(IMessageRPCFraming.parseNotificationLine(Data("not json".utf8)) == nil)
    }

    @Test func redactionReplacesHomeDirectoryWithTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let redacted = IMessageRPCSecurity.redact("open failed: \(home)/Library/Messages/chat.db")
        #expect(!redacted.contains(home))
        #expect(redacted.contains("~/Library/Messages/chat.db"))
    }
}

// MARK: - Tapback normalization (pure)

struct IMessageTapbackNormalizationTests {

    @Test func emojiAliasesAndKindNamesResolveToCanonicalKinds() {
        // Every presentation an agent plausibly passes — the Unicode emoji
        // Messages renders, :alias: names, and the kind names themselves —
        // must land on one of the six kinds the pinned helper accepts.
        let cases: [(String, String)] = [
            ("❤️", "love"), ("❤", "love"), (":heart:", "love"), ("love", "love"),
            ("👍", "like"), ("+1", "like"), (":thumbsup:", "like"), ("LIKE", "like"),
            ("👎", "dislike"), ("-1", "dislike"), ("thumbsdown", "dislike"),
            ("😂", "laugh"), ("haha", "laugh"), (":joy:", "laugh"),
            ("‼️", "emphasize"), ("💯", "emphasize"), ("exclamation", "emphasize"),
            ("❓", "question"), ("?", "question"), (":thinking_face:", "question"),
        ]
        for (input, expected) in cases {
            #expect(
                AgentChannelReactionNormalizer.imessageTapbackKind(input) == expected,
                "\(input) should normalize to \(expected)"
            )
        }
    }

    @Test func unsupportedReactionsHaveNoTapbackEquivalent() {
        for input in ["🌮", "custom_emoji", "", "   ", String(repeating: "x", count: 65)] {
            #expect(AgentChannelReactionNormalizer.imessageTapbackKind(input) == nil)
        }
    }

    @Test func canonicalKindSetMatchesPinnedHelperSurface() {
        #expect(
            AgentChannelReactionNormalizer.imessageTapbackKinds
                == ["love", "like", "dislike", "laugh", "emphasize", "question"]
        )
    }

    /// The Activity scope filter and every service-side record share one
    /// native connection id; drift would silently empty the iMessage filter.
    @Test func nativeConnectionIdMatchesActivityScopeContract() {
        #expect(IMessageConnectionService.nativeConnectionId == "imessage")
        #expect(AgentChannelConnection.nativeIMessageConnectionId == "imessage")
    }
}

// MARK: - Configuration policy

struct IMessageConfigurationTests {

    @Test func defaultsAreFailClosed() {
        let config = IMessageConnectionConfiguration()
        #expect(!config.writeEnabled)
        #expect(!config.receivePollingEnabled)
        #expect(!config.attachmentIngestionEnabled)
        #expect(!config.advancedActionsEnabled)
        #expect(config.enabledAdvancedActions.isEmpty)
        #expect(!config.canStartReceive())
        #expect(!config.canWrite(chatId: "iMessage;-;+15551234567"))
        #expect(!config.isAttachmentPathAllowed(Self.defaultRoot + "/file.png"))
    }

    @Test func normalizationLowercasesEmailHandlesButPreservesChatGUIDs() {
        let config = IMessageConnectionConfiguration(
            readableChatIds: [" iMessage;-;+15551234567 ", "iMessage;-;+15551234567", ""],
            senderAllowlist: [" Name@Example.COM ", "name@example.com", "+15551234567"]
        )
        // GUID case preserved (chat.db GUIDs are case-sensitive); duplicates
        // and empties dropped.
        #expect(config.readableChatIds == ["iMessage;-;+15551234567"])
        // Email handles lowercase for stable matching; phone left alone.
        #expect(config.senderAllowlist == ["name@example.com", "+15551234567"])
        // Group GUIDs contain ";" and never get email-style lowercasing even
        // if a participant email appears inside.
        #expect(
            IMessageConnectionConfiguration.normalizedId("iMessage;+;Name@Example.com")
                == "iMessage;+;Name@Example.com"
        )
        #expect(!IMessageConnectionConfiguration.isValidChatId("   "))
    }

    @Test func limitsClampToSafeRanges() {
        let config = IMessageConnectionConfiguration(
            defaultReadLimit: 100_000,
            pollIntervalSeconds: 0,
            maxAttachmentBytes: 0
        )
        #expect(config.defaultReadLimit == 100)
        #expect(config.pollIntervalSeconds == 1)
        #expect(config.maxAttachmentBytes == 1_024)
        #expect(IMessageConnectionConfiguration.clampReadLimit(-3) == 1)
        #expect(IMessageConnectionConfiguration.clampPollInterval(9_999) == 60)
        #expect(
            IMessageConnectionConfiguration.clampAttachmentBytes(.max) == 100 * 1_024 * 1_024
        )
    }

    @Test func attachmentPathGateBlocksTraversalAndForeignRoots() {
        let config = IMessageConnectionConfiguration(
            attachmentIngestionEnabled: true,
            allowedAttachmentRoots: [Self.defaultRoot]
        )
        #expect(config.isAttachmentPathAllowed(Self.defaultRoot + "/ab/cd/image.heic"))
        #expect(config.isAttachmentPathAllowed(Self.defaultRoot))
        #expect(!config.isAttachmentPathAllowed("/etc/passwd"))
        // Prefix-shadowing sibling directory must not match.
        #expect(!config.isAttachmentPathAllowed(Self.defaultRoot + "-evil/file.png"))
        // Traversal collapses outside the root during standardization.
        #expect(!config.isAttachmentPathAllowed(Self.defaultRoot + "/../../.ssh/id_ed25519"))
    }

    @Test func attachmentPathGateResolvesSymlinksBeforeRootCheck() throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("osaurus-imsg-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: workDir) }
        let root = workDir.appendingPathComponent("allowed", isDirectory: true)
        let outside = workDir.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let link = root.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: secret)
        let real = root.appendingPathComponent("real.txt")
        try Data("ok".utf8).write(to: real)

        let config = IMessageConnectionConfiguration(
            attachmentIngestionEnabled: true,
            allowedAttachmentRoots: [root.path]
        )
        // A symlink planted inside the allowlisted root must not smuggle a
        // file from outside it.
        #expect(!config.isAttachmentPathAllowed(link.path))
        #expect(config.isAttachmentPathAllowed(real.path))
    }

    @Test func advancedActionsNeedMasterGateAndIndividualEnablement() {
        let masterOff = IMessageConnectionConfiguration(
            advancedActionsEnabled: false,
            enabledAdvancedActions: [.edit]
        )
        #expect(!masterOff.isAdvancedActionEnabled(.edit))

        let masterOn = IMessageConnectionConfiguration(
            advancedActionsEnabled: true,
            enabledAdvancedActions: [.edit, .edit, .poll]
        )
        #expect(masterOn.isAdvancedActionEnabled(.edit))
        #expect(masterOn.isAdvancedActionEnabled(.poll))
        #expect(!masterOn.isAdvancedActionEnabled(.unsend))
        #expect(masterOn.enabledAdvancedActions == [.edit, .poll])
    }

    @Test func receiveRequiresStoragePollingChatsAndSenders() {
        let ready = IMessageConnectionConfiguration(
            readableChatIds: ["iMessage;-;+15551234567"],
            senderAllowlist: ["+15551234567"],
            receiveStorageEnabled: true,
            receivePollingEnabled: true
        )
        #expect(ready.canStartReceive())
        #expect(
            !IMessageConnectionConfiguration(
                readableChatIds: ["iMessage;-;+15551234567"],
                senderAllowlist: [],
                receiveStorageEnabled: true,
                receivePollingEnabled: true
            ).canStartReceive()
        )
        #expect(
            !IMessageConnectionConfiguration(
                readableChatIds: [],
                senderAllowlist: ["+15551234567"],
                receiveStorageEnabled: true,
                receivePollingEnabled: true
            ).canStartReceive()
        )
    }

    private static let defaultRoot =
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Messages/Attachments"
}

// MARK: - Connection service against a fake helper transport

@Suite(.serialized)
struct IMessageConnectionServiceTests {

    @Test func configurationPersistsNormalizedAndRoundTrips() async throws {
        try await withIsolatedIMessageStores {
            let service = IMessageConnectionService(transport: FakeIMessageTransport())
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [" iMessage;-;+15551234567 ", "iMessage;-;+15551234567"],
                    writableChatIds: ["iMessage;-;+15551234567"],
                    senderAllowlist: ["Name@Example.COM"],
                    writeEnabled: true,
                    defaultReadLimit: 5_000,
                    pollIntervalSeconds: 120
                )
            )

            let saved = IMessageConnectionConfigurationStore.load()
            #expect(saved.readableChatIds == ["iMessage;-;+15551234567"])
            #expect(saved.senderAllowlist == ["name@example.com"])
            #expect(saved.defaultReadLimit == 100)
            #expect(saved.pollIntervalSeconds == 60)
            #expect(saved.writeEnabled)

            // No secret material belongs in this file — the channel has no
            // token, and nothing keychain-shaped should ever appear.
            let disk = try String(
                contentsOf: IMessageConnectionConfigurationStore.configurationFileURL(),
                encoding: .utf8
            )
            #expect(disk.contains("iMessage;-;+15551234567"))
            #expect(!disk.localizedCaseInsensitiveContains("token"))
        }
    }

    @Test func connectionManagerRejectsNativeIMessageId() async throws {
        try await withIsolatedIMessageStores {
            let manager = AgentChannelConnectionManager(agentExists: { _ in true })

            #expect(throws: AgentChannelConnectionManagerError.reservedConnectionId("imessage")) {
                try manager.upsertConnection(
                    AgentChannelConnection(
                        id: "imessage",
                        name: "Shadow iMessage",
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
        try await withIsolatedIMessageStores {
            let transport = FakeIMessageTransport()
            let service = IMessageConnectionService(transport: transport)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: ["iMessage;-;+15551234567"],
                    writeEnabled: false
                )
            )

            await #expect(throws: IMessageConnectionServiceError.sendConfirmationRequired) {
                _ = try await service.sendMessage(
                    chatId: "iMessage;-;+15551234567",
                    content: "hi",
                    confirmSend: false
                )
            }
            await #expect(throws: IMessageConnectionServiceError.writeDisabled) {
                _ = try await service.sendMessage(
                    chatId: "iMessage;-;+15551234567",
                    content: "hi",
                    confirmSend: true
                )
            }

            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: ["iMessage;-;+15551234567"],
                    writeEnabled: true
                )
            )
            await #expect(
                throws: IMessageConnectionServiceError.chatNotWritable("iMessage;-;+15559990000")
            ) {
                _ = try await service.sendMessage(
                    chatId: "iMessage;-;+15559990000",
                    content: "hi",
                    confirmSend: true
                )
            }
            #expect(transport.calls(for: IMessageRPCMethod.send).isEmpty)
        }
    }

    @Test func sendStripsMarkdownAndChunksLongContent() async throws {
        try await withIsolatedIMessageStores {
            let transport = FakeIMessageTransport()
            transport.setResponse(for: IMessageRPCMethod.send, result: ["guid": "sent-1"])
            let service = IMessageConnectionService(transport: transport)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: ["iMessage;-;+15551234567"],
                    writeEnabled: true
                )
            )

            _ = try await service.sendMessage(
                chatId: "iMessage;-;+15551234567",
                content: "**bold** and _italic_",
                confirmSend: true
            )
            let plain = transport.calls(for: IMessageRPCMethod.send).last?["text"] as? String
            #expect(plain == "bold and italic")

            transport.clearCalls()
            let long = String(
                repeating: "a",
                count: AgentChannelMessageFormatter.plainTextChunkLimit + 100
            )
            let result = try await service.sendMessage(
                chatId: "iMessage;-;+15551234567",
                content: long,
                confirmSend: true
            )
            let sends = transport.calls(for: IMessageRPCMethod.send)
            #expect(sends.count == 2)
            #expect(result["chunk_count"] as? Int == 2)
            #expect(sends.allSatisfy { ($0["chat_guid"] as? String) == "iMessage;-;+15551234567" })

            let overLimit = String(
                repeating: "a",
                count: AgentChannelMessageFormatter.plainTextChunkLimit
                    * AgentChannelMessageFormatter.maxChunksPerSend + 1
            )
            await #expect(throws: IMessageConnectionServiceError.messageTooLong) {
                _ = try await service.sendMessage(
                    chatId: "iMessage;-;+15551234567",
                    content: overLimit,
                    confirmSend: true
                )
            }
        }
    }

    @Test func readAndSearchEnforceReadAllowlistOverStoredMessages() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            _ = try store.recordMessages([
                AgentChannelStoredMessage(
                    connectionId: "imessage",
                    roomId: "iMessage;-;+15551234567",
                    providerMessageId: "guid-1",
                    direction: .inbound,
                    authorId: "+15551234567",
                    content: "deploy finished at noon"
                )
            ])

            let service = IMessageConnectionService(
                transport: FakeIMessageTransport(),
                messageStore: store
            )
            try service.saveConfiguration(
                IMessageConnectionConfiguration(readableChatIds: ["iMessage;-;+15551234567"])
            )

            let read = try service.readChat(chatId: "iMessage;-;+15551234567", limit: 10)
            let messages = read["messages"] as? [[String: Any]] ?? []
            #expect(messages.count == 1)
            #expect(messages.first?["content"] as? String == "deploy finished at noon")

            #expect(throws: IMessageConnectionServiceError.chatNotReadable("iMessage;-;+15559990000")) {
                _ = try service.readChat(chatId: "iMessage;-;+15559990000", limit: 10)
            }

            let search = try service.searchMessages(
                query: "DEPLOY",
                chatIds: nil,
                limitPerChat: nil,
                maxMatches: nil
            )
            #expect(search["match_count"] as? Int == 1)
            #expect(throws: IMessageConnectionServiceError.emptyMessage) {
                _ = try service.searchMessages(
                    query: "   ",
                    chatIds: nil,
                    limitPerChat: nil,
                    maxMatches: nil
                )
            }
        }
    }

    @Test func advancedActionNeedsEnablementThenLiveBridgeCapability() async throws {
        try await withIsolatedIMessageStores {
            let transport = FakeIMessageTransport()
            let service = IMessageConnectionService(transport: transport)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: ["iMessage;-;+15551234567"],
                    writeEnabled: true,
                    advancedActionsEnabled: false,
                    enabledAdvancedActions: [.edit]
                )
            )

            // Master gate off: disabled even though individually enabled.
            await #expect(throws: IMessageConnectionServiceError.advancedActionDisabled("edit")) {
                _ = try await service.editMessage(
                    chatId: "iMessage;-;+15551234567",
                    messageId: "guid-1",
                    content: "fixed",
                    confirmSend: true
                )
            }

            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: ["iMessage;-;+15551234567"],
                    writeEnabled: true,
                    advancedActionsEnabled: true,
                    enabledAdvancedActions: [.edit]
                )
            )

            // Enabled, but the helper has no injected bridge: unavailable.
            await #expect(throws: IMessageConnectionServiceError.advancedActionUnavailable("edit")) {
                _ = try await service.editMessage(
                    chatId: "iMessage;-;+15551234567",
                    messageId: "guid-1",
                    content: "fixed",
                    confirmSend: true
                )
            }
            #expect(transport.calls(for: IMessageRPCMethod.edit).isEmpty)

            // Bridge live and method reported: the call goes through.
            transport.setCapabilities(
                IMessageCapabilities(
                    helperVersion: "0.13.4-test",
                    bridgeAvailable: true,
                    rpcMethods: [IMessageRPCMethod.edit],
                    sipStatus: "disabled",
                    probed: true
                )
            )
            transport.setResponse(for: IMessageRPCMethod.edit, result: ["guid": "guid-1"])
            let result = try await service.editMessage(
                chatId: "iMessage;-;+15551234567",
                messageId: "guid-1",
                content: "fixed",
                confirmSend: true
            )
            #expect(result["kind"] as? String == "imessage_edit")
            #expect(result["delivery_status"] as? String == "sent")
            let params = transport.calls(for: IMessageRPCMethod.edit).last
            #expect(params?["message_id"] as? String == "guid-1")
            #expect(params?["text"] as? String == "fixed")
        }
    }

    @Test func attachmentSendIsFencedToAllowlistedRoots() async throws {
        try await withIsolatedIMessageStores {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-imsg-attachments-\(UUID().uuidString)").path
            let transport = FakeIMessageTransport()
            transport.setCapabilities(
                IMessageCapabilities(
                    helperVersion: "0.13.4-test",
                    bridgeAvailable: true,
                    rpcMethods: [IMessageRPCMethod.sendAttachment],
                    sipStatus: "disabled",
                    probed: true
                )
            )
            transport.setResponse(for: IMessageRPCMethod.sendAttachment, result: [:])
            let service = IMessageConnectionService(transport: transport)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: ["iMessage;-;+15551234567"],
                    writeEnabled: true,
                    attachmentIngestionEnabled: true,
                    allowedAttachmentRoots: [root],
                    advancedActionsEnabled: true,
                    enabledAdvancedActions: [.sendAttachment]
                )
            )

            await #expect(throws: IMessageConnectionServiceError.attachmentNotAllowed("/etc/passwd")) {
                _ = try await service.sendAttachment(
                    chatId: "iMessage;-;+15551234567",
                    path: "/etc/passwd",
                    confirmSend: true
                )
            }
            await #expect(
                throws: IMessageConnectionServiceError.attachmentNotAllowed(
                    root + "/../escape.png"
                )
            ) {
                _ = try await service.sendAttachment(
                    chatId: "iMessage;-;+15551234567",
                    path: root + "/../escape.png",
                    confirmSend: true
                )
            }
            #expect(transport.calls(for: IMessageRPCMethod.sendAttachment).isEmpty)

            let allowed = root + "/report.pdf"
            let result = try await service.sendAttachment(
                chatId: "iMessage;-;+15551234567",
                path: allowed,
                confirmSend: true
            )
            #expect(result["kind"] as? String == "imessage_send_attachment")
            #expect(
                transport.calls(for: IMessageRPCMethod.sendAttachment).last?["file"] as? String
                    == allowed
            )
        }
    }

    @Test func pollEffectAndGroupParametersAreValidated() async throws {
        try await withIsolatedIMessageStores {
            let transport = FakeIMessageTransport()
            transport.setCapabilities(
                IMessageCapabilities(
                    helperVersion: "0.13.4-test",
                    bridgeAvailable: true,
                    rpcMethods: [
                        IMessageRPCMethod.poll,
                        IMessageRPCMethod.sendRich,
                        IMessageRPCMethod.groupRename,
                        IMessageRPCMethod.groupAddParticipant,
                        IMessageRPCMethod.groupRemoveParticipant,
                    ],
                    sipStatus: "disabled",
                    probed: true
                )
            )
            let service = IMessageConnectionService(transport: transport)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: ["iMessage;+;chat123"],
                    writeEnabled: true,
                    advancedActionsEnabled: true,
                    enabledAdvancedActions: [.poll, .sendEffect, .groupManagement]
                )
            )

            await #expect(
                throws: IMessageConnectionServiceError.invalidAdvancedParameter(
                    "polls need 2-12 non-empty options"
                )
            ) {
                _ = try await service.createPoll(
                    chatId: "iMessage;+;chat123",
                    question: "Lunch?",
                    options: ["  ", "tacos"],
                    confirmSend: true
                )
            }
            await #expect(
                throws: IMessageConnectionServiceError.invalidAdvancedParameter(
                    "effect must not be empty"
                )
            ) {
                _ = try await service.sendEffect(
                    chatId: "iMessage;+;chat123",
                    content: "hooray",
                    effect: "   ",
                    confirmSend: true
                )
            }
            await #expect(
                throws: IMessageConnectionServiceError.invalidAdvancedParameter(
                    "group rename needs a non-empty value"
                )
            ) {
                _ = try await service.manageGroup(
                    chatId: "iMessage;+;chat123",
                    operation: .rename,
                    value: "  ",
                    confirmSend: true
                )
            }

            transport.setResponse(for: IMessageRPCMethod.poll, result: [:])
            _ = try await service.createPoll(
                chatId: "iMessage;+;chat123",
                question: "Lunch?",
                options: [" tacos ", "sushi"],
                confirmSend: true
            )
            let pollParams = transport.calls(for: IMessageRPCMethod.poll).last
            #expect(pollParams?["options"] as? [String] == ["tacos", "sushi"])

            transport.setResponse(for: IMessageRPCMethod.groupAddParticipant, result: [:])
            _ = try await service.manageGroup(
                chatId: "iMessage;+;chat123",
                operation: .addParticipant,
                value: " Name@Example.COM ",
                confirmSend: true
            )
            let groupParams = transport.calls(for: IMessageRPCMethod.groupAddParticipant).last
            #expect(groupParams?["address"] as? String == "name@example.com")
            #expect(groupParams?["chat_guid"] as? String == "iMessage;+;chat123")
        }
    }

    @Test func watchEventsAuthorizeStoreDeduplicateAndAdvanceCursor() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            try store.upsertCursor(
                connectionId: "imessage",
                roomId: IMessageConnectionService.updatesCursorRoomId,
                cursor: "40"
            )

            let chat = "iMessage;-;+15551234567"
            let service = IMessageConnectionService(
                transport: FakeIMessageTransport(),
                messageStore: store
            )
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [chat],
                    senderAllowlist: ["+15551234567"],
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )

            let authorizedRow: [String: Any] = [
                "guid": "g-41", "id": 41, "chat_guid": chat,
                "sender": "+15551234567", "text": "authorized hello",
                "is_from_me": false, "created_at": "2026-07-29T13:01:00Z",
            ]
            let authorized = try await service.handleWatchEvent(authorizedRow)
            #expect(authorized.received == 1)
            #expect(authorized.stored == 1)
            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 1)
            // Cursor persists only after the event was authorized/recorded.
            #expect(
                try store.cursor(
                    connectionId: "imessage",
                    roomId: IMessageConnectionService.updatesCursorRoomId
                ) == "41"
            )

            // Non-allowlisted sender: rejected before storage, but the cursor
            // still advances past the row.
            let stranger = try await service.handleWatchEvent([
                "guid": "g-42", "id": 42, "chat_guid": chat,
                "sender": "+19998887777", "text": "stranger danger",
                "is_from_me": false, "created_at": "2026-07-29T13:02:00Z",
            ])
            #expect(stranger.received == 1)
            #expect(stranger.stored == 0)
            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 1)
            #expect(
                try store.cursor(
                    connectionId: "imessage",
                    roomId: IMessageConnectionService.updatesCursorRoomId
                ) == "42"
            )

            // Redelivery after a reconnect backfill (crash-recovery overlap)
            // stores nothing new: dedupe is by provider event id, and the
            // cursor never moves backwards.
            let replay = try await service.handleWatchEvent(authorizedRow)
            #expect(replay.stored == 0)
            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 1)
            #expect(
                try store.cursor(
                    connectionId: "imessage",
                    roomId: IMessageConnectionService.updatesCursorRoomId
                ) == "42"
            )
        }
    }

    @Test func watchSkipsAdvanceCursorSoBackfillNeverReplaysThem() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let chat = "iMessage;-;+15551234567"
            let service = IMessageConnectionService(
                transport: FakeIMessageTransport(),
                messageStore: store
            )
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [chat],
                    senderAllowlist: ["+15551234567"],
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )

            // A chat outside the read allowlist: dropped before authorization
            // (never stored, never in Activity), cursor advanced.
            let unlisted = try await service.handleWatchEvent([
                "guid": "g-50", "id": 50, "chat_guid": "iMessage;-;+15550000000",
                "sender": "+15550000000", "text": "private conversation",
                "is_from_me": false, "created_at": "2026-07-29T13:00:00Z",
            ])
            #expect(unlisted.received == 0)

            // A tapback row in a readable chat: decoration, not content.
            let reaction = try await service.handleWatchEvent([
                "guid": "g-51", "id": 51, "chat_guid": chat,
                "sender": "+15551234567", "text": "Loved “hello”",
                "is_reaction": true,
                "is_from_me": false, "created_at": "2026-07-29T13:01:00Z",
            ])
            #expect(reaction.received == 0)

            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 0)
            #expect(
                try store.cursor(
                    connectionId: "imessage",
                    roomId: IMessageConnectionService.updatesCursorRoomId
                ) == "51"
            )
        }
    }

    @Test func watchSessionResumesFromCursorAndProcessesBackfill() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            try store.upsertCursor(
                connectionId: "imessage",
                roomId: IMessageConnectionService.updatesCursorRoomId,
                cursor: "40"
            )

            let chat = "iMessage;-;+15551234567"
            let transport = FakeIMessageTransport()
            transport.setResponse(
                for: IMessageRPCMethod.watchSubscribe,
                result: ["subscription": 1]
            )
            // The fake helper backfills one row after subscribe, then dies.
            transport.onCall(IMessageRPCMethod.watchSubscribe) {
                transport.emitNotification(
                    method: IMessageRPCNotification.message,
                    params: [
                        "subscription": 1,
                        "message": [
                            "guid": "g-41", "id": 41, "chat_guid": chat,
                            "sender": "+15551234567", "text": "missed while offline",
                            "is_from_me": false, "created_at": "2026-07-29T13:01:00Z",
                        ],
                    ]
                )
                transport.emitNotification(
                    method: IMessageRPCNotification.helperTerminated,
                    params: [:]
                )
            }
            let service = IMessageConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [chat],
                    senderAllowlist: ["+15551234567"],
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )

            let collector = WatchBatchCollector()
            await #expect(throws: IMessageConnectionServiceError.self) {
                try await service.runWatchSession(
                    onReady: { collector.markReady() },
                    onBatch: { collector.append($0) }
                )
            }

            // Resume is lossless: the subscription starts at the persisted
            // cursor, and the backfilled row lands in the store.
            #expect(collector.isReady)
            #expect(
                transport.calls(for: IMessageRPCMethod.watchSubscribe).last?["since_rowid"]
                    as? Int64 == 40
            )
            #expect(collector.batches.map(\.stored) == [1])
            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 1)
            #expect(
                try store.cursor(
                    connectionId: "imessage",
                    roomId: IMessageConnectionService.updatesCursorRoomId
                ) == "41"
            )
        }
    }

    @Test func firstWatchSessionStartsFromNowWithoutReplayingHistory() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            // No cursor: this connection has never received before.

            let transport = FakeIMessageTransport()
            transport.setResponse(
                for: IMessageRPCMethod.watchSubscribe,
                result: ["subscription": 1]
            )
            transport.onCall(IMessageRPCMethod.watchSubscribe) {
                transport.emitNotification(
                    method: IMessageRPCNotification.helperTerminated,
                    params: [:]
                )
            }
            let service = IMessageConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: ["iMessage;-;+15551234567"],
                    senderAllowlist: ["+15551234567"],
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )

            await #expect(throws: IMessageConnectionServiceError.self) {
                try await service.runWatchSession(onReady: {}, onBatch: { _ in })
            }

            // Without a cursor the subscription omits since_rowid, so the
            // helper streams "from now" and old conversations are never
            // replayed into agents.
            let params = transport.calls(for: IMessageRPCMethod.watchSubscribe).last
            #expect(params != nil)
            #expect(params?["since_rowid"] == nil)
        }
    }

    @Test func watchSessionIsANoOpUntilReceiveIsFullyConfigured() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let transport = FakeIMessageTransport()
            let service = IMessageConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: ["iMessage;-;+15551234567"],
                    senderAllowlist: [],
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )

            try await service.runWatchSession(onReady: {}, onBatch: { _ in })
            #expect(transport.calls(for: IMessageRPCMethod.watchSubscribe).isEmpty)

            let summary = try await service.handleWatchEvent([
                "guid": "g-1", "id": 1, "chat_guid": "iMessage;-;+15551234567",
                "sender": "+15551234567", "text": "hello",
                "is_from_me": false, "created_at": "2026-07-29T13:00:00Z",
            ])
            #expect(summary == AgentChannelReceiveBatchSummary(
                received: 0, stored: 0, dispatchAttempted: 0, dispatchSuppressed: 0
            ))
        }
    }

    @Test func listChatsFallsBackToConfiguredIdsWithoutHelper() async throws {
        try await withIsolatedIMessageStores {
            let transport = FakeIMessageTransport()
            transport.setHelperAvailable(false)
            let service = IMessageConnectionService(transport: transport)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: ["iMessage;-;+15551234567"],
                    writableChatIds: ["iMessage;+;chat123"],
                    writeEnabled: true
                )
            )

            let chats = try await service.listChats()
            let ids = chats.compactMap { $0["id"] as? String }
            #expect(ids.sorted() == ["iMessage;+;chat123", "iMessage;-;+15551234567"])
            let writable = chats.first { ($0["id"] as? String) == "iMessage;+;chat123" }
            #expect(writable?["write_allowed"] as? Bool == true)
            #expect(writable?["read_allowed"] as? Bool == false)
        }
    }

    @Test func dispatcherRejectsAdvancedIMessageActionsOnOtherKinds() async throws {
        try await withIsolatedIMessageStores {
            let service = AgentChannelConnectionService(
                discordService: .shared,
                imessageService: IMessageConnectionService(transport: FakeIMessageTransport())
            )

            await #expect(
                throws: AgentChannelConnectionServiceError.unsupportedKind(.discord)
            ) {
                _ = try await service.imessageSendEffect(
                    connectionId: "discord",
                    roomId: "iMessage;-;+15551234567",
                    content: "hi",
                    effect: "confetti",
                    confirmSend: true
                )
            }
        }
    }

    @Test func transportRuntimeFailsHardWhenHelperUnavailable() async throws {
        try await withIsolatedIMessageStores {
            let transport = FakeIMessageTransport()
            transport.setHelperAvailable(false)
            let runtime = IMessageWatchTransportRuntime(
                service: IMessageConnectionService(transport: transport),
                healthCenter: AgentChannelTransportHealthCenter(),
                fullDiskAccessGranted: { true }
            )

            let result = await runtime.runStep()
            #expect(result.disposition == .failed)
            #expect(result.retryDelay == 300)
            #expect(result.health.status == .failed)
            #expect(result.health.transportId == "imessage_watch")
        }
    }

    @Test func transportRuntimeWaitsForFullDiskAccessInsteadOfSpawning() async throws {
        try await withIsolatedIMessageStores {
            let transport = FakeIMessageTransport()
            let runtime = IMessageWatchTransportRuntime(
                service: IMessageConnectionService(transport: transport),
                healthCenter: AgentChannelTransportHealthCenter(),
                fullDiskAccessGranted: { false }
            )

            let result = await runtime.runStep()
            // Spawning `imsg rpc` without Full Disk Access can only fail (it
            // opens chat.db at startup) — the runtime must wait, not spawn.
            #expect(result.disposition == .skipped)
            #expect(result.retryDelay == 60)
            #expect(result.health.status == .degraded)
            #expect(transport.calls(for: IMessageRPCMethod.watchSubscribe).isEmpty)
        }
    }

    @Test func transportRuntimeProcessesWatchEventsAndBacksOffWhenHelperDies() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            try store.upsertCursor(
                connectionId: "imessage",
                roomId: IMessageConnectionService.updatesCursorRoomId,
                cursor: "0"
            )
            let chat = "iMessage;-;+15551234567"
            let transport = FakeIMessageTransport()
            transport.setResponse(
                for: IMessageRPCMethod.watchSubscribe,
                result: ["subscription": 1]
            )
            transport.onCall(IMessageRPCMethod.watchSubscribe) {
                transport.emitNotification(
                    method: IMessageRPCNotification.message,
                    params: [
                        "subscription": 1,
                        "message": [
                            "guid": "g-1", "id": 1, "chat_guid": chat,
                            "sender": "+15551234567", "text": "hello",
                            "is_from_me": false, "created_at": "2026-07-29T13:00:00Z",
                        ],
                    ]
                )
                transport.emitNotification(
                    method: IMessageRPCNotification.helperTerminated,
                    params: [:]
                )
            }
            let service = IMessageConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [chat],
                    senderAllowlist: ["+15551234567"],
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )
            let healthCenter = AgentChannelTransportHealthCenter()
            let runtime = IMessageWatchTransportRuntime(
                service: service,
                healthCenter: healthCenter,
                fullDiskAccessGranted: { true }
            )

            let result = await runtime.runStep()
            // The event was processed before the helper died…
            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 1)
            // …and the step reports the interruption with a retry delay so
            // the worker reconnects (and resubscribes from the cursor).
            #expect(result.disposition == .failed)
            #expect((result.retryDelay ?? 0) > 0)
            #expect(result.health.status == .degraded)
            #expect(result.health.consecutiveFailures == 1)
        }
    }

    @Test func diagnosticsSummarizeGatingWithoutLeakingPaths() async throws {
        try await withIsolatedIMessageStores {
            let transport = FakeIMessageTransport()
            transport.setCapabilities(
                IMessageCapabilities(
                    helperVersion: "0.13.4-test",
                    bridgeAvailable: false,
                    rpcMethods: [],
                    sipStatus: "enabled",
                    probed: true
                )
            )
            let service = IMessageConnectionService(
                transport: transport,
                integrity: FakeIntegrityProbe(
                    snapshot: IMessageSystemIntegritySnapshot(
                        sipEnabled: true,
                        libraryValidationEnabled: true
                    )
                )
            )
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: ["iMessage;-;+15551234567"],
                    advancedActionsEnabled: true,
                    enabledAdvancedActions: [.edit]
                )
            )

            let diagnostics = await service.diagnostics()
            // imsg exposes no sign-in probe, so diagnostics must report
            // unknown — never a definite signed-out claim.
            #expect(diagnostics.messagesSignedIn == nil)
            #expect(diagnostics.sipEnabled == true)
            #expect(diagnostics.libraryValidationEnabled == true)
            #expect(diagnostics.advancedActionsEnabled)
            #expect(!diagnostics.bridgeAvailable)
            #expect(!diagnostics.helperVerified)
            #expect(diagnostics.failures.contains { $0.contains("helper is not usable") })
            #expect(!diagnostics.failures.contains { $0.contains("Sign in to Messages.app") })
            #expect(diagnostics.notes.contains { $0.contains("sign-in state cannot be probed") })
            // Advanced-on + bridge-off must be called out, and the note must
            // state that Osaurus never disables the protections itself.
            #expect(diagnostics.notes.contains { $0.contains("Osaurus never changes") })
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            #expect(!diagnostics.failures.joined().contains(home))

            // receiveReady stays false until storage+polling+helper all align.
            #expect(!diagnostics.receiveReady)
        }
    }

    @Test func watchBurstsLargerThanLegacyPollPageAreLossless() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let chat = "iMessage;-;+15551234567"
            let service = IMessageConnectionService(
                transport: FakeIMessageTransport(),
                messageStore: store
            )
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [chat],
                    senderAllowlist: ["+15551234567"],
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )

            // The retired polling receive read at most 30 rows per cycle; a
            // burst beyond that page size silently lost the overflow. The
            // watch stream is per-row, so every row of a 45-message burst
            // must land and the cursor must end at the burst's last rowid.
            for index in 1 ... 45 {
                let summary = try await service.handleWatchEvent([
                    "guid": "burst-\(index)", "id": index, "chat_guid": chat,
                    "sender": "+15551234567", "text": "burst message \(index)",
                    "is_from_me": false, "created_at": "2026-07-29T13:00:00Z",
                ])
                #expect(summary.stored == 1)
            }

            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 45)
            #expect(
                try store.cursor(
                    connectionId: "imessage",
                    roomId: IMessageConnectionService.updatesCursorRoomId
                ) == "45"
            )
        }
    }

    @Test func malformedWatchRowsNeverHaltProcessingOfOtherChats() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let chatA = "iMessage;-;+15551234567"
            let chatB = "iMessage;-;+15557654321"
            let transport = FakeIMessageTransport()
            transport.setResponse(
                for: IMessageRPCMethod.watchSubscribe,
                result: ["subscription": 1]
            )
            // One session interleaves: a structurally broken notification, a
            // row from chat A missing its guid (not ingestible), a good row
            // from chat B, then helper death. The broken rows must not stop
            // chat B's message from landing — failure in one chat's rows is
            // isolated from the others.
            transport.onCall(IMessageRPCMethod.watchSubscribe) {
                transport.emitNotification(
                    method: IMessageRPCNotification.message,
                    params: ["subscription": 1]  // no `message` payload at all
                )
                transport.emitNotification(
                    method: IMessageRPCNotification.message,
                    params: [
                        "subscription": 1,
                        "message": [
                            "id": 10, "chat_guid": chatA,
                            "sender": "+15551234567", "text": "row without guid",
                            "is_from_me": false,
                        ],
                    ]
                )
                transport.emitNotification(
                    method: IMessageRPCNotification.message,
                    params: [
                        "subscription": 1,
                        "message": [
                            "guid": "g-11", "id": 11, "chat_guid": chatB,
                            "sender": "+15557654321", "text": "still delivered",
                            "is_from_me": false, "created_at": "2026-07-29T13:01:00Z",
                        ],
                    ]
                )
                transport.emitNotification(
                    method: IMessageRPCNotification.helperTerminated,
                    params: [:]
                )
            }
            let service = IMessageConnectionService(transport: transport, messageStore: store)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [chatA, chatB],
                    senderAllowlist: ["+15551234567", "+15557654321"],
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )

            await #expect(throws: IMessageConnectionServiceError.self) {
                try await service.runWatchSession(onReady: {}, onBatch: { _ in })
            }

            #expect(try store.messageCount(connectionId: "imessage", roomId: chatB) == 1)
            #expect(try store.messageCount(connectionId: "imessage", roomId: chatA) == 0)
            // The guid-less chat A row still advanced the cursor (10), and
            // chat B's row moved it to 11 — nothing gets replayed forever.
            #expect(
                try store.cursor(
                    connectionId: "imessage",
                    roomId: IMessageConnectionService.updatesCursorRoomId
                ) == "11"
            )
        }
    }

    @Test func nonAllowlistedWatchDropsAreCountedForReceiveHealth() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let chat = "iMessage;-;+15551234567"
            let service = IMessageConnectionService(
                transport: FakeIMessageTransport(),
                messageStore: store
            )
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [chat],
                    senderAllowlist: ["+15551234567"],
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )
            #expect(service.watchDroppedNonAllowlistedCount() == 0)

            // Two rows from a chat outside the readable allowlist: dropped
            // before authorization (never stored, never in Activity), but
            // counted so receive health can explain a silent Verify.
            for index in 1 ... 2 {
                _ = try await service.handleWatchEvent([
                    "guid": "foreign-\(index)", "id": index,
                    "chat_guid": "iMessage;-;+15550000000",
                    "sender": "+15550000000", "text": "not for us",
                    "is_from_me": false,
                ])
            }
            #expect(service.watchDroppedNonAllowlistedCount() == 2)
            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 0)

            // Allowlisted rows do not touch the counter.
            _ = try await service.handleWatchEvent([
                "guid": "g-3", "id": 3, "chat_guid": chat,
                "sender": "+15551234567", "text": "hello",
                "is_from_me": false,
            ])
            #expect(service.watchDroppedNonAllowlistedCount() == 2)
        }
    }

    @Test func selfMessagesDispatchOnlyWhenIgnoreSelfMessagesIsOff() async throws {
        try await withIsolatedIMessageStores {
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            let chat = "iMessage;-;+15551234567"
            let service = IMessageConnectionService(
                transport: FakeIMessageTransport(),
                messageStore: store
            )
            let selfRow: (String) -> [String: Any] = { guid in
                [
                    "guid": guid, "id": 60, "chat_guid": chat,
                    "sender": "+15551234567", "text": "note to self",
                    "is_from_me": true, "created_at": "2026-07-29T13:00:00Z",
                ]
            }

            // Default policy (ignore on): the Mac's own sent messages are
            // rejected at authorization, not stored.
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [chat],
                    senderAllowlist: ["+15551234567"],
                    ignoreSelfMessages: true,
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )
            let ignored = try await service.handleWatchEvent(selfRow("self-1"))
            #expect(ignored.stored == 0)
            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 0)

            // Operator turns Ignore Self Messages off (the single-machine
            // test loop): the same shape of row now stores and dispatches.
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    readableChatIds: [chat],
                    senderAllowlist: ["+15551234567"],
                    ignoreSelfMessages: false,
                    receiveStorageEnabled: true,
                    receivePollingEnabled: true
                )
            )
            let accepted = try await service.handleWatchEvent(selfRow("self-2"))
            #expect(accepted.stored == 1)
            #expect(try store.messageCount(connectionId: "imessage", roomId: chat) == 1)
        }
    }

    @Test func tapbackNormalizesEmojiAndRejectsUnsupportedReactions() async throws {
        try await withIsolatedIMessageStores {
            let chat = "iMessage;-;+15551234567"
            let transport = FakeIMessageTransport()
            transport.setCapabilities(
                IMessageCapabilities(
                    helperVersion: "0.13.4-test",
                    bridgeAvailable: true,
                    rpcMethods: [IMessageRPCMethod.tapback],
                    sipStatus: "disabled",
                    probed: true
                )
            )
            transport.setResponse(for: IMessageRPCMethod.tapback, result: [:])
            let service = IMessageConnectionService(transport: transport)
            try service.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: [chat],
                    writeEnabled: true,
                    advancedActionsEnabled: true,
                    enabledAdvancedActions: [.tapback]
                )
            )

            // Emoji input normalizes to the canonical kind the pinned helper
            // accepts, and add/remove maps to the upstream `remove` flag.
            _ = try await service.setTapback(
                chatId: chat, messageId: "guid-1", reaction: "👍",
                adding: true, confirmSend: true
            )
            var params = transport.calls(for: IMessageRPCMethod.tapback).last
            #expect(params?["reaction"] as? String == "like")
            #expect(params?["remove"] as? Bool == false)

            _ = try await service.setTapback(
                chatId: chat, messageId: "guid-1", reaction: ":heart:",
                adding: false, confirmSend: true
            )
            params = transport.calls(for: IMessageRPCMethod.tapback).last
            #expect(params?["reaction"] as? String == "love")
            #expect(params?["remove"] as? Bool == true)

            // Arbitrary emoji have no tapback equivalent: typed refusal
            // before any helper call, with the supported kinds in the error.
            transport.clearCalls()
            do {
                _ = try await service.setTapback(
                    chatId: chat, messageId: "guid-1", reaction: "🌮",
                    adding: true, confirmSend: true
                )
                Issue.record("expected invalidAdvancedParameter for 🌮")
            } catch let error as IMessageConnectionServiceError {
                guard case .invalidAdvancedParameter(let detail) = error else {
                    throw error
                }
                #expect(detail.contains("no iMessage tapback equivalent"))
                #expect(detail.contains("love"))
            }
            #expect(transport.calls(for: IMessageRPCMethod.tapback).isEmpty)
        }
    }

    @Test func advancedActionPoliciesGateOnToggleEnablementAndBridge() async throws {
        try await withIsolatedIMessageStores {
            let chat = "iMessage;-;+15551234567"
            let transport = FakeIMessageTransport()
            let imessageService = IMessageConnectionService(transport: transport)
            let service = AgentChannelConnectionService(
                discordService: .shared,
                imessageService: imessageService
            )
            func policy(_ action: String) async -> [String: Any]? {
                let diagnostics = await service.diagnostics(connectionId: "imessage")
                let policies = diagnostics["action_policies"] as? [[String: Any]] ?? []
                return policies.first { ($0["action"] as? String) == action }
            }

            // Master toggle off: standard mutations that map onto the bridge
            // must advertise unavailable so agents don't plan around them.
            try imessageService.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: [chat],
                    writeEnabled: true,
                    advancedActionsEnabled: false,
                    enabledAdvancedActions: [.edit]
                )
            )
            var edit = await policy("edit_message")
            #expect(edit?["status"] as? String == "unavailable")
            #expect((edit?["reason"] as? String)?.contains("master toggle") == true)

            // Master on but this action not individually enabled.
            try imessageService.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: [chat],
                    writeEnabled: true,
                    advancedActionsEnabled: true,
                    enabledAdvancedActions: [.tapback]
                )
            )
            edit = await policy("edit_message")
            #expect(edit?["status"] as? String == "unavailable")
            #expect((edit?["reason"] as? String)?.contains("not enabled") == true)

            // Enabled, but the last probe saw no injected bridge.
            try imessageService.saveConfiguration(
                IMessageConnectionConfiguration(
                    writableChatIds: [chat],
                    writeEnabled: true,
                    advancedActionsEnabled: true,
                    enabledAdvancedActions: [.edit, .tapback]
                )
            )
            edit = await policy("edit_message")
            #expect(edit?["status"] as? String == "unavailable")
            #expect((edit?["reason"] as? String)?.contains("bridge") == true)

            // Bridge live: the diagnostics call itself probes and caches the
            // capability, so the same projection now advertises available —
            // for the reaction mapping (tapback) too. Plain sends never
            // needed the bridge.
            transport.setCapabilities(
                IMessageCapabilities(
                    helperVersion: "0.13.4-test",
                    bridgeAvailable: true,
                    rpcMethods: [IMessageRPCMethod.edit, IMessageRPCMethod.tapback],
                    sipStatus: "disabled",
                    probed: true
                )
            )
            edit = await policy("edit_message")
            #expect(edit?["status"] as? String == "available")
            let reaction = await policy("add_reaction")
            #expect(reaction?["status"] as? String == "available")
            let send = await policy("send_message")
            #expect(send?["status"] as? String == "available")
        }
    }

    @Test func listConnectionsMarksIMessageConfiguredOnlyWithVerifiedHelper() async throws {
        try await withIsolatedIMessageStores {
            let transport = FakeIMessageTransport()
            let imessageService = IMessageConnectionService(transport: transport)
            let service = AgentChannelConnectionService(
                discordService: .shared,
                imessageService: imessageService
            )
            try imessageService.saveConfiguration(
                IMessageConnectionConfiguration(readableChatIds: ["iMessage;-;+15551234567"])
            )
            func imessageRow() -> [String: Any]? {
                service.listConnections().first { ($0["id"] as? String) == "imessage" }
            }

            // Allowlisted chats but no verified helper: not configured — the
            // "credential" role is played by the verified local helper.
            transport.setHelperAvailable(false)
            var row = imessageRow()
            #expect(row?["configured"] as? Bool == false)
            #expect(row?["credential_saved"] as? Bool == false)
            #expect(row?["helper_available"] as? Bool == false)

            transport.setHelperAvailable(true)
            row = imessageRow()
            #expect(row?["configured"] as? Bool == true)
            #expect(row?["credential_saved"] as? Bool == true)

            // Helper alone without any allowlisted chat is not configured.
            try imessageService.saveConfiguration(IMessageConnectionConfiguration())
            row = imessageRow()
            #expect(row?["configured"] as? Bool == false)
        }
    }

    // MARK: - Isolation helper

    private func withIsolatedIMessageStores(
        _ body: @Sendable () async throws -> Void
    ) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let previousDirectory = IMessageConnectionConfigurationStore.overrideDirectory
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-imessage-tests-\(UUID().uuidString)", isDirectory: true)
            IMessageConnectionConfigurationStore.overrideDirectory = directory
            defer {
                IMessageConnectionConfigurationStore.overrideDirectory = previousDirectory
                try? FileManager.default.removeItem(at: directory)
            }
            try await body()
        }
    }
}

// MARK: - Fakes

/// Scriptable in-memory stand-in for the `imsg rpc` process transport.
private final class FakeIMessageTransport: IMessageRPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var helperAvailable = true
    private var capabilities = IMessageCapabilities(
        helperVersion: "0.13.4-test",
        bridgeAvailable: false,
        rpcMethods: [],
        sipStatus: "enabled",
        probed: true
    )
    private var responses: [String: [String: Any]] = [:]
    private var errors: [String: IMessageRPCError] = [:]
    private var recordedCalls: [(method: String, params: [String: Any])] = []
    private var callObservers: [String: @Sendable () -> Void] = [:]
    private var notificationHandler: (@Sendable (String, Data) -> Void)?

    func setHelperAvailable(_ available: Bool) {
        lock.withLock { helperAvailable = available }
    }

    func setCapabilities(_ capabilities: IMessageCapabilities) {
        lock.withLock { self.capabilities = capabilities }
    }

    func setResponse(for method: String, result: [String: Any]) {
        lock.withLock { responses[method] = result }
    }

    func setError(for method: String, error: IMessageRPCError) {
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
    ) async throws -> IMessageRPCResponse {
        let (error, result, observer):
            (IMessageRPCError?, [String: Any], (@Sendable () -> Void)?) = lock.withLock {
                recordedCalls.append((method, params as [String: Any]))
                return (errors[method], responses[method] ?? [:], callObservers[method])
            }
        observer?()
        if let error { throw error }
        return IMessageRPCResponse(resultJSON: try JSONSerialization.data(withJSONObject: result))
    }

    func probeCapabilities() async -> IMessageCapabilities {
        lock.withLock { capabilities }
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

private struct FakeIntegrityProbe: IMessageSystemIntegrityProbing {
    let fixed: IMessageSystemIntegritySnapshot

    init(snapshot: IMessageSystemIntegritySnapshot) {
        self.fixed = snapshot
    }

    func snapshot() -> IMessageSystemIntegritySnapshot {
        fixed
    }
}
