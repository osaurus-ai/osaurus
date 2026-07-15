//
//  AgentChannelEvalHarness.swift
//  OsaurusCore
//
//  Deterministic, model-free driver for the `agent_channels` eval domain.
//  Runs the REAL Slack/Telegram connection services against fake provider
//  clients (no network) and the isolated config/message stores, and pins
//  the policy contracts the suite README documents: room allowlists,
//  sender allowlists, confirm-send gating, and the external-surface (MCP)
//  denial of the whole agent_channel_* tool family.
//
//  Lives in OsaurusCore because every service, protocol, and config store
//  involved is internal runtime surface; the evals kit sees only this
//  facade and the scenario outcome.
//

import Foundation

/// Outcome of one agent-channels policy scenario.
public struct AgentChannelScenarioOutcome: Sendable, Codable {
    public let passed: Bool
    /// Human-readable per-check lines (both passes and failures), in
    /// execution order — the forensic trail for the report.
    public let checks: [String]
    /// The subset of checks that failed. Empty iff `passed`.
    public let failures: [String]

    public init(passed: Bool, checks: [String], failures: [String]) {
        self.passed = passed
        self.checks = checks
        self.failures = failures
    }
}

/// MainActor because config-store writes and service singletons follow the
/// same isolation conventions as the rest of the eval facades.
@MainActor
public enum AgentChannelEvalHarness {

    // MARK: - Fakes

    /// Records outbound sends; serves canned pages for reads. Every method
    /// that reaches the network in production just returns fixture data.
    private final class FakeSlackClient: SlackAPIClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _sendRequests: [SlackOutboundMessageRequest] = []
        private var _fetchedChannelIds: [String] = []

        var sendRequests: [SlackOutboundMessageRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _sendRequests
        }

        var fetchedChannelIds: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _fetchedChannelIds
        }

        func authTest(token: String) async throws -> SlackAuthIdentity {
            SlackAuthIdentity(
                url: nil, team: "Eval", user: "evalbot",
                teamId: "T-EVAL", userId: "U-BOT", botId: "B-BOT"
            )
        }

        func openSocketModeConnection(appToken: String) async throws -> URL {
            URL(string: "wss://eval.invalid/socket")!
        }

        func conversations(
            token: String, limit: Int, cursor: String?
        ) async throws -> SlackConversationPage {
            SlackConversationPage(conversations: [])
        }

        func messages(
            channelId: String, token: String, limit: Int, cursor: String?
        ) async throws -> SlackMessagePage {
            lock.withLock { _fetchedChannelIds.append(channelId) }
            return SlackMessagePage(
                messages: [
                    SlackMessage(
                        type: "message", user: "U-ALICE", username: "alice",
                        botId: nil, text: "fixture message", ts: "1700000000.000100",
                        threadTs: nil, replyCount: nil
                    )
                ]
            )
        }

        func threadMessages(
            channelId: String, threadTs: String, token: String, limit: Int, cursor: String?
        ) async throws -> SlackMessagePage {
            SlackMessagePage(messages: [])
        }

        func sendMessage(
            _ request: SlackOutboundMessageRequest, token: String
        ) async throws -> SlackMessage {
            lock.withLock { _sendRequests.append(request) }
            return SlackMessage(
                type: "message", user: "U-BOT", username: "evalbot", botId: "B-BOT",
                text: request.content, ts: "1700000001.000200", threadTs: request.threadTs,
                replyCount: nil
            )
        }
    }

    private final class FakeTelegramClient: TelegramAPIClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _sentTexts: [(chatId: String, text: String)] = []

        var sendCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _sentTexts.count
        }

        func getMe(token: String) async throws -> TelegramUser {
            TelegramUser(id: 1, isBot: true, firstName: "EvalBot", lastName: nil, username: "evalbot")
        }

        func getChat(chatId: String, token: String) async throws -> TelegramChat {
            TelegramChat(
                id: Int64(chatId) ?? 0, type: "group", title: "Eval Chat",
                username: nil, firstName: nil, lastName: nil
            )
        }

        func getWebhookInfo(token: String) async throws -> TelegramWebhookInfo {
            TelegramWebhookInfo(url: "")
        }

        func deleteWebhook(token: String) async throws -> Bool { true }

        func getUpdates(
            offset: Int64?, limit: Int, timeout: Int, token: String
        ) async throws -> [TelegramUpdate] { [] }

        func sendMessage(
            chatId: String, text: String, replyToMessageId: Int?, token: String
        ) async throws -> TelegramMessage {
            lock.withLock { _sentTexts.append((chatId, text)) }
            return TelegramMessage(
                messageId: 1, date: 0,
                chat: TelegramChat(
                    id: Int64(chatId) ?? 0, type: "group", title: "Eval Chat",
                    username: nil, firstName: nil, lastName: nil
                ),
                from: nil, senderChat: nil, text: text, caption: nil, replyToMessage: nil
            )
        }
    }

    private struct FakeSlackCredentials: SlackCredentialStorage {
        func saveBotToken(_ token: String) -> Bool { true }
        func botToken() -> String? { "xoxb-eval-fixture" }
        func hasBotToken() -> Bool { true }
        func deleteBotToken() -> Bool { true }
        func saveSigningSecret(_ secret: String) -> Bool { true }
        func signingSecret() -> String? { "eval-signing" }
        func hasSigningSecret() -> Bool { true }
        func deleteSigningSecret() -> Bool { true }
        func saveAppToken(_ token: String) -> Bool { true }
        func appToken() -> String? { "xapp-eval-fixture" }
        func hasAppToken() -> Bool { true }
        func deleteAppToken() -> Bool { true }
    }

    private struct FakeTelegramCredentials: TelegramCredentialStorage {
        func saveBotToken(_ token: String) -> Bool { true }
        func botToken() -> String? { "0000:eval-fixture" }
        func hasBotToken() -> Bool { true }
        func deleteBotToken() -> Bool { true }
    }

    // MARK: - Entry point

    /// Run one scenario. `provider` is `"slack"` (default) or `"telegram"`;
    /// `mcp_denial` ignores it. The Slack/Telegram config stores are seeded
    /// from the arguments and restored afterwards (they live under the
    /// eval's isolated root, but restoring keeps cases order-independent).
    public static func run(
        scenario: String,
        provider: String? = nil,
        allowedRoomIds: [String] = [],
        deniedRoomId: String? = nil,
        allowedSenderId: String? = nil,
        deniedSenderId: String? = nil
    ) async -> AgentChannelScenarioOutcome {
        var checks: [String] = []
        var failures: [String] = []

        func expect(_ condition: Bool, _ label: String) {
            if condition {
                checks.append("ok: \(label)")
            } else {
                checks.append("FAIL: \(label)")
                failures.append(label)
            }
        }

        let providerName = (provider ?? "slack").lowercased()

        switch scenario {
        case "unauthorized_room_read":
            await runUnauthorizedRoomRead(
                provider: providerName,
                allowedRoomIds: allowedRoomIds,
                deniedRoomId: deniedRoomId ?? "C-DENIED",
                expect: expect
            )
        case "sender_allowlist":
            await runSenderAllowlist(
                provider: providerName,
                allowedRoomIds: allowedRoomIds,
                allowedSenderId: allowedSenderId ?? "U-ALLOWED",
                deniedSenderId: deniedSenderId ?? "U-DENIED",
                expect: expect
            )
        case "unconfirmed_send":
            await runUnconfirmedSend(
                provider: providerName,
                allowedRoomIds: allowedRoomIds,
                expect: expect
            )
        case "mcp_denial":
            runMCPDenial(expect: expect)
        default:
            expect(false, "unknown agent_channels scenario '\(scenario)'")
        }

        return AgentChannelScenarioOutcome(
            passed: failures.isEmpty,
            checks: checks,
            failures: failures
        )
    }

    // MARK: - Scenarios

    /// Reading a room that is NOT on the read allowlist must be rejected
    /// by the service before any provider call, and must leave no message
    /// row. A read of an allowlisted room must succeed (proves the gate is
    /// an allowlist, not a broken pipe).
    private static func runUnauthorizedRoomRead(
        provider: String,
        allowedRoomIds: [String],
        deniedRoomId: String,
        expect: (Bool, String) -> Void
    ) async {
        let store = AgentChannelMessageStore()
        // Hermetic + idempotent: an in-memory store means the scenario
        // never touches the user's real channel-messages DB and a re-run
        // can't collide with its own prior event ids through the
        // production duplicate-event dedupe.
        try? store.openInMemory()

        if provider == "telegram" {
            let previous = TelegramConnectionConfigurationStore.load()
            defer { try? TelegramConnectionConfigurationStore.save(previous) }
            try? TelegramConnectionConfigurationStore.save(
                TelegramConnectionConfiguration(
                    readableChatIds: allowedRoomIds,
                    senderAllowlist: ["U-ANY"]
                )
            )
            let service = TelegramConnectionService(
                client: FakeTelegramClient(),
                credentialStore: FakeTelegramCredentials(),
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            do {
                _ = try service.readChat(TelegramReadRequest(chatId: deniedRoomId, limit: 5))
                expect(false, "read of non-allowlisted chat \(deniedRoomId) must throw")
            } catch {
                expect(true, "read of non-allowlisted chat \(deniedRoomId) rejected: \(error.localizedDescription)")
            }
            let deniedRows =
                (try? store.messageCount(
                    connectionId: TelegramConnectionService.nativeConnectionId,
                    roomId: deniedRoomId
                )) ?? -1
            expect(deniedRows == 0, "no message rows stored for denied chat (found \(deniedRows))")
            return
        }

        let previous = SlackConnectionConfigurationStore.load()
        defer { try? SlackConnectionConfigurationStore.save(previous) }
        try? SlackConnectionConfigurationStore.save(
            SlackConnectionConfiguration(
                configuredTeamIds: ["T-EVAL"],
                readableChannelIds: allowedRoomIds,
                senderAllowlist: ["U-ANY"]
            )
        )
        let client = FakeSlackClient()
        let service = SlackConnectionService(
            client: client,
            credentialStore: FakeSlackCredentials(),
            messageStore: store,
            recordMessageSnapshotsInline: true
        )
        do {
            _ = try await service.readChannel(channelId: deniedRoomId, limit: 5)
            expect(false, "read of non-allowlisted channel \(deniedRoomId) must throw")
        } catch {
            expect(true, "read of non-allowlisted channel \(deniedRoomId) rejected: \(error.localizedDescription)")
        }
        expect(
            !client.fetchedChannelIds.contains(where: {
                $0.caseInsensitiveCompare(deniedRoomId) == .orderedSame
            }),
            "provider client was never asked for the denied channel"
        )
        let deniedRows =
            (try? store.messageCount(
                connectionId: AgentChannelConnection.nativeSlackConnectionId,
                roomId: deniedRoomId
            )) ?? -1
        expect(deniedRows == 0, "no message rows stored for denied channel (found \(deniedRows))")

        if let allowed = allowedRoomIds.first {
            do {
                _ = try await service.readChannel(channelId: allowed, limit: 5)
                expect(true, "read of allowlisted channel \(allowed) succeeded")
            } catch {
                expect(false, "read of allowlisted channel \(allowed) must succeed (got \(error.localizedDescription))")
            }
        }
    }

    /// Inbound events from a non-allowlisted sender must be denied with
    /// the exact reason and store nothing; the allowlisted sender's event
    /// must be allowed and stored.
    private static func runSenderAllowlist(
        provider: String,
        allowedRoomIds: [String],
        allowedSenderId: String,
        deniedSenderId: String,
        expect: (Bool, String) -> Void
    ) async {
        let store = AgentChannelMessageStore()
        // Hermetic + idempotent: an in-memory store means the scenario
        // never touches the user's real channel-messages DB and a re-run
        // can't collide with its own prior event ids through the
        // production duplicate-event dedupe.
        try? store.openInMemory()
        let roomId = allowedRoomIds.first ?? "C-ROOM"

        let connectionId: String
        if provider == "telegram" {
            let previous = TelegramConnectionConfigurationStore.load()
            defer { try? TelegramConnectionConfigurationStore.save(previous) }
            try? TelegramConnectionConfigurationStore.save(
                TelegramConnectionConfiguration(
                    readableChatIds: allowedRoomIds.isEmpty ? [roomId] : allowedRoomIds,
                    senderAllowlist: [allowedSenderId]
                )
            )
            connectionId = TelegramConnectionService.nativeConnectionId
            await checkSenderDecisions(
                connectionId: connectionId,
                spaceId: "telegram",
                roomId: roomId,
                allowedSenderId: allowedSenderId,
                deniedSenderId: deniedSenderId,
                telegramProviderUnderTest: true,
                store: store,
                expect: expect
            )
            return
        }

        let previous = SlackConnectionConfigurationStore.load()
        defer { try? SlackConnectionConfigurationStore.save(previous) }
        try? SlackConnectionConfigurationStore.save(
            SlackConnectionConfiguration(
                configuredTeamIds: ["T-EVAL"],
                readableChannelIds: allowedRoomIds.isEmpty ? [roomId] : allowedRoomIds,
                senderAllowlist: [allowedSenderId]
            )
        )
        connectionId = AgentChannelConnection.nativeSlackConnectionId
        await checkSenderDecisions(
            connectionId: connectionId,
            spaceId: "T-EVAL",
            roomId: roomId,
            allowedSenderId: allowedSenderId,
            deniedSenderId: deniedSenderId,
            telegramProviderUnderTest: false,
            store: store,
            expect: expect
        )
    }

    private static func checkSenderDecisions(
        connectionId: String,
        spaceId: String,
        roomId: String,
        allowedSenderId: String,
        deniedSenderId: String,
        telegramProviderUnderTest: Bool,
        store: AgentChannelMessageStore,
        expect: (Bool, String) -> Void
    ) async {
        let dispatcher = AgentChannelConnectionService(
            discordService: .shared,
            slackService: SlackConnectionService(
                client: FakeSlackClient(),
                credentialStore: FakeSlackCredentials(),
                messageStore: store,
                recordMessageSnapshotsInline: true
            ),
            telegramService: TelegramConnectionService(
                client: FakeTelegramClient(),
                credentialStore: FakeTelegramCredentials(),
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
        )

        func authorize(sender: String, eventId: String) -> AgentChannelInboundAuthorizationDecision? {
            try? dispatcher.authorizeInboundMessage(
                AgentChannelInboundMessageAuthorizationRequest(
                    connectionId: connectionId,
                    providerEventId: eventId,
                    providerMessageId: "m-\(eventId)",
                    spaceId: spaceId,
                    roomId: roomId,
                    senderId: sender
                ),
                messageStore: store
            )
        }

        let allowedDecision = authorize(sender: allowedSenderId, eventId: "ev-allowed-1")
        expect(
            allowedDecision?.decision == .allow,
            "allowlisted sender \(allowedSenderId) authorized (got \(allowedDecision?.reason ?? "nil"))"
        )
        if let allowedDecision, allowedDecision.decision == .allow {
            let result = try? store.recordReceiveEvent(
                connectionId: connectionId,
                providerEventId: "ev-allowed-1",
                authorization: allowedDecision,
                message: AgentChannelStoredMessage(
                    connectionId: connectionId,
                    roomId: roomId,
                    providerMessageId: "m-ev-allowed-1",
                    direction: .inbound,
                    authorId: allowedSenderId,
                    content: "hello from allowlisted sender"
                )
            )
            expect(
                result?.messageInserted == true,
                "allowlisted sender's message stored (inserted=\(String(describing: result?.messageInserted)))"
            )
        }

        let before = (try? store.messageCount(connectionId: connectionId, roomId: roomId)) ?? -1
        let deniedDecision = authorize(sender: deniedSenderId, eventId: "ev-denied-1")
        expect(
            deniedDecision?.decision == .deny,
            "non-allowlisted sender \(deniedSenderId) denied (got \(deniedDecision?.decision.rawValue ?? "nil"))"
        )
        expect(
            deniedDecision?.reason == "sender_not_allowlisted",
            "denial reason is sender_not_allowlisted (got \(deniedDecision?.reason ?? "nil"))"
        )
        if let deniedDecision {
            let result = try? store.recordReceiveEvent(
                connectionId: connectionId,
                providerEventId: "ev-denied-1",
                authorization: deniedDecision,
                message: AgentChannelStoredMessage(
                    connectionId: connectionId,
                    roomId: roomId,
                    providerMessageId: "m-ev-denied-1",
                    direction: .inbound,
                    authorId: deniedSenderId,
                    content: "hello from denied sender"
                )
            )
            expect(
                result?.messageInserted != true,
                "denied sender's message NOT stored"
            )
        }
        let after = (try? store.messageCount(connectionId: connectionId, roomId: roomId)) ?? -1
        expect(
            before == after,
            "message count unchanged by denied event (\(before) → \(after))"
        )
        _ = telegramProviderUnderTest
    }

    /// `send_message` without `confirm_send: true` must fail BEFORE any
    /// provider dispatch; with confirmation it must go through — proving
    /// the gate is the confirmation flag, not broken plumbing.
    private static func runUnconfirmedSend(
        provider: String,
        allowedRoomIds: [String],
        expect: (Bool, String) -> Void
    ) async {
        let roomId = allowedRoomIds.first ?? "C-ROOM"

        if provider == "telegram" {
            let previous = TelegramConnectionConfigurationStore.load()
            defer { try? TelegramConnectionConfigurationStore.save(previous) }
            try? TelegramConnectionConfigurationStore.save(
                TelegramConnectionConfiguration(
                    writableChatIds: allowedRoomIds.isEmpty ? [roomId] : allowedRoomIds,
                    senderAllowlist: ["U-ANY"],
                    writeEnabled: true
                )
            )
            let client = FakeTelegramClient()
            let service = TelegramConnectionService(
                client: client,
                credentialStore: FakeTelegramCredentials(),
                messageStore: nil
            )
            do {
                _ = try await service.sendMessage(
                    TelegramWriteRequest(
                        chatId: roomId, text: "unapproved", replyToMessageId: nil,
                        confirmSend: false
                    )
                )
                expect(false, "send without confirm_send must throw")
            } catch {
                expect(true, "send without confirm_send rejected: \(error.localizedDescription)")
            }
            expect(client.sendCount == 0, "provider client recorded zero sends (\(client.sendCount))")
            do {
                _ = try await service.sendMessage(
                    TelegramWriteRequest(
                        chatId: roomId, text: "approved", replyToMessageId: nil,
                        confirmSend: true
                    )
                )
                expect(true, "confirmed send succeeded")
            } catch {
                expect(false, "confirmed send must succeed (got \(error.localizedDescription))")
            }
            expect(client.sendCount == 1, "provider client recorded exactly one send (\(client.sendCount))")
            return
        }

        let previous = SlackConnectionConfigurationStore.load()
        defer { try? SlackConnectionConfigurationStore.save(previous) }
        try? SlackConnectionConfigurationStore.save(
            SlackConnectionConfiguration(
                configuredTeamIds: ["T-EVAL"],
                writableChannelIds: allowedRoomIds.isEmpty ? [roomId] : allowedRoomIds,
                senderAllowlist: ["U-ANY"],
                writeEnabled: true
            )
        )
        let client = FakeSlackClient()
        let service = SlackConnectionService(
            client: client,
            credentialStore: FakeSlackCredentials(),
            messageStore: nil
        )
        do {
            _ = try await service.sendMessage(channelId: roomId, content: "unapproved", confirmSend: false)
            expect(false, "send without confirm_send must throw")
        } catch {
            expect(true, "send without confirm_send rejected: \(error.localizedDescription)")
        }
        expect(client.sendRequests.isEmpty, "provider client recorded zero sends (\(client.sendRequests.count))")
        do {
            _ = try await service.sendMessage(channelId: roomId, content: "approved", confirmSend: true)
            expect(true, "confirmed send succeeded")
        } catch {
            expect(false, "confirmed send must succeed (got \(error.localizedDescription))")
        }
        expect(
            client.sendRequests.count == 1,
            "provider client recorded exactly one send (\(client.sendRequests.count))"
        )
    }

    /// Every agent_channel_* tool must be in the external-surface deny set
    /// and actually refused when the external-surface task-local is bound
    /// — the deterministic core of the documented external-MCP-denial case
    /// (the live /mcp/tools + /mcp/call sweep rides in the http_api lane).
    private static func runMCPDenial(expect: (Bool, String) -> Void) {
        let family = ToolRegistry.agentChannelToolNames
        expect(!family.isEmpty, "agent_channel tool family is non-empty (\(family.count) tools)")
        for name in family.sorted() {
            expect(
                ToolRegistry.externallyDeniedToolNames.contains(name),
                "\(name) is in externallyDeniedToolNames"
            )
            let denied = ChatExecutionContext.$isExternalSurface.withValue(true) {
                ToolRegistry.isDeniedForCurrentSurface(name)
            }
            expect(denied, "\(name) is denied when the external-surface flag is bound")
            let allowedInternally = ChatExecutionContext.$isExternalSurface.withValue(false) {
                !ToolRegistry.isDeniedForCurrentSurface(name)
            }
            expect(allowedInternally, "\(name) stays available to internal surfaces")
        }
    }
}
