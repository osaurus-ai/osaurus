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

        func users(
            token: String, limit: Int, cursor: String?
        ) async throws -> SlackUserPage {
            SlackUserPage(users: [])
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
            chatId: String, text: String, replyToMessageId: Int?, parseMode: String?, token: String
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
        case "proactive_publish":
            await runProactivePublish(expect: expect)
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

    /// Proactive-publish policy pins over the REAL `AgentChannelPublishService`
    /// with an isolated in-memory ledger and a fake provider sender:
    /// no binding means no publish capability and no prompt payload;
    /// external/channel-triggered runs can never publish; an autonomous
    /// scheduled run can send only to its OWN binding; a repeated intent key
    /// produces exactly one provider write; draft and unattended-confirm
    /// modes never silently send.
    private static func runProactivePublish(expect: (Bool, String) -> Void) async {
        let ownerAgent = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let otherAgent = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        final class SendRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var sendCount: Int { lock.withLock { _count } }
            func record() { lock.withLock { _count += 1 } }
        }

        func binding(
            id: String,
            agentId: UUID,
            mode: AgentChannelBindingOutboundMode
        ) -> AgentChannelBinding {
            AgentChannelBinding(
                id: id,
                agentId: agentId,
                connectionId: "eval-conn",
                roomId: "R-EVAL",
                label: "Eval destination",
                guidance: "Use for eval reports.",
                allowedSources: [.chat, .schedule],
                outboundMode: mode
            )
        }

        let configuration = AgentChannelConfiguration(
            bindings: [
                binding(id: "own-autonomous", agentId: ownerAgent, mode: .autonomous),
                binding(id: "other-agents", agentId: otherAgent, mode: .autonomous),
                binding(id: "own-draft", agentId: ownerAgent, mode: .draft),
                binding(id: "own-confirm", agentId: ownerAgent, mode: .confirm),
            ]
        )
        let connection = AgentChannelConnection(
            id: "eval-conn",
            name: "Eval Connection",
            kind: .customHTTP,
            writeRoomAllowlist: ["R-EVAL"],
            writeEnabled: true
        )

        let recorder = SendRecorder()
        let store = AgentChannelMessageStore()
        try? store.openInMemory()
        let service = AgentChannelPublishService(
            loadConfiguration: { configuration },
            resolveConnection: { _ in connection },
            killSwitchSnapshot: { ChannelWriteKillSwitchSnapshot(writeEnabled: true) },
            sender: { _, _ in
                recorder.record()
                return "eval-msg-1"
            },
            store: store
        )

        func context(
            agentId: UUID? = nil,
            source: SessionSource?,
            isExternalSurface: Bool = false,
            isUnattendedDispatch: Bool = false
        ) -> AgentChannelPublishContext {
            AgentChannelPublishContext(
                agentId: agentId ?? ownerAgent,
                source: source,
                isExternalSurface: isExternalSurface,
                isUnattendedDispatch: isUnattendedDispatch
            )
        }

        func deniedCode(_ outcome: AgentChannelPublishOutcome) -> String? {
            if case .denied(let code, _, _) = outcome { return code }
            return nil
        }

        // 1. No binding → no publish capability and no prompt payload.
        let noBindingSection = SystemPromptComposer.channelDestinationsSection(
            bindings: [],
            source: .chat
        )
        expect(noBindingSection == nil, "agent without bindings gets no Channel Destinations prompt")
        let ghost = await service.publish(
            AgentChannelPublishRequest(bindingId: "ghost", content: "x", intentKey: "k-ghost"),
            context: context(source: .schedule)
        )
        expect(
            deniedCode(ghost) == "binding_not_found",
            "publish to an unconfigured binding denied (got \(ghost.statusLabel))"
        )

        // 2. External / channel-triggered runs can never publish.
        let external = await service.publish(
            AgentChannelPublishRequest(bindingId: "own-autonomous", content: "x", intentKey: "k-ext"),
            context: context(source: .chat, isExternalSurface: true)
        )
        expect(
            deniedCode(external) == "external_surface_denied",
            "external surface publish denied (got \(external.statusLabel))"
        )
        let channelRun = await service.publish(
            AgentChannelPublishRequest(bindingId: "own-autonomous", content: "x", intentKey: "k-chan"),
            context: context(source: .channel)
        )
        expect(
            deniedCode(channelRun) == "run_source_not_allowed",
            "channel-triggered run publish denied (got \(channelRun.statusLabel))"
        )
        expect(recorder.sendCount == 0, "no provider writes before authorized sends (\(recorder.sendCount))")

        // 3. Autonomous scheduled run: own binding sends, another agent's does not.
        let ownSend = await service.publish(
            AgentChannelPublishRequest(bindingId: "own-autonomous", content: "report", intentKey: "k-own"),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        if case .sent = ownSend {
            expect(true, "autonomous scheduled run sent to its own binding")
        } else {
            expect(false, "autonomous scheduled run sent to its own binding (got \(ownSend.statusLabel))")
        }
        let notOwned = await service.publish(
            AgentChannelPublishRequest(bindingId: "other-agents", content: "x", intentKey: "k-other"),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        expect(
            deniedCode(notOwned) == "binding_not_owned",
            "another agent's binding denied (got \(notOwned.statusLabel))"
        )

        // 4. Repeating an intent key never produces a second provider write.
        let replay = await service.publish(
            AgentChannelPublishRequest(bindingId: "own-autonomous", content: "report", intentKey: "k-own"),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        if case .duplicate = replay {
            expect(true, "replayed intent key reported as duplicate")
        } else {
            expect(false, "replayed intent key reported as duplicate (got \(replay.statusLabel))")
        }
        expect(recorder.sendCount == 1, "exactly one provider write for the repeated intent (\(recorder.sendCount))")

        // 5. Draft and unattended confirm never silently send.
        let draft = await service.publish(
            AgentChannelPublishRequest(bindingId: "own-draft", content: "draft body", intentKey: "k-draft"),
            context: context(source: .chat)
        )
        if case .draftRecorded = draft {
            expect(true, "draft mode recorded a draft")
        } else {
            expect(false, "draft mode recorded a draft (got \(draft.statusLabel))")
        }
        let queued = await service.publish(
            AgentChannelPublishRequest(bindingId: "own-confirm", content: "confirm body", intentKey: "k-confirm"),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        if case .queuedForApproval = queued {
            expect(true, "unattended confirm queued for approval")
        } else {
            expect(false, "unattended confirm queued for approval (got \(queued.statusLabel))")
        }
        expect(
            recorder.sendCount == 1,
            "draft/confirm modes performed no provider writes (\(recorder.sendCount))"
        )

        // 6. An ambiguous provider failure (the message MAY have reached the
        // provider) parks the intent as delivery_unknown; replaying the same
        // intent key after the provider "recovers" must never resend.
        let ambiguousRecorder = SendRecorder()
        let ambiguousStore = AgentChannelMessageStore()
        try? ambiguousStore.openInMemory()
        let failOnce = SendRecorder()
        let ambiguousService = AgentChannelPublishService(
            loadConfiguration: { configuration },
            resolveConnection: { _ in connection },
            killSwitchSnapshot: { ChannelWriteKillSwitchSnapshot(writeEnabled: true) },
            sender: { _, _ in
                if failOnce.sendCount == 0 {
                    failOnce.record()
                    throw URLError(.timedOut)
                }
                ambiguousRecorder.record()
                return "eval-msg-ambiguous"
            },
            store: ambiguousStore
        )
        let ambiguous = await ambiguousService.publish(
            AgentChannelPublishRequest(
                bindingId: "own-autonomous", content: "maybe sent", intentKey: "k-ambiguous"
            ),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        expect(
            deniedCode(ambiguous) == "delivery_unknown",
            "ambiguous provider failure reports delivery_unknown (got \(ambiguous.statusLabel))"
        )
        let ambiguousReplay = await ambiguousService.publish(
            AgentChannelPublishRequest(
                bindingId: "own-autonomous", content: "maybe sent", intentKey: "k-ambiguous"
            ),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        if case .duplicate(_, let status) = ambiguousReplay, status == .deliveryUnknown {
            expect(true, "replay of an unknown delivery reported as duplicate, not resent")
        } else {
            expect(
                false,
                "replay of an unknown delivery reported as duplicate, not resent (got \(ambiguousReplay.statusLabel))"
            )
        }
        expect(
            ambiguousRecorder.sendCount == 0,
            "no provider write after an unresolved unknown delivery (\(ambiguousRecorder.sendCount))"
        )
        ambiguousStore.close()

        // 7. A queued approval whose binding was repointed since must be
        // refused: the operator approved the STORED destination, not the
        // edited one.
        let staleRecorder = SendRecorder()
        let staleStore = AgentChannelMessageStore()
        try? staleStore.openInMemory()
        final class ConfigurationBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _configuration: AgentChannelConfiguration
            init(_ configuration: AgentChannelConfiguration) { _configuration = configuration }
            var configuration: AgentChannelConfiguration {
                get { lock.withLock { _configuration } }
                set { lock.withLock { _configuration = newValue } }
            }
        }
        let configurationBox = ConfigurationBox(configuration)
        let staleService = AgentChannelPublishService(
            loadConfiguration: { configurationBox.configuration },
            resolveConnection: { _ in
                AgentChannelConnection(
                    id: "eval-conn",
                    name: "Eval Connection",
                    kind: .customHTTP,
                    writeRoomAllowlist: ["R-EVAL", "R-ELSEWHERE"],
                    writeEnabled: true
                )
            },
            killSwitchSnapshot: { ChannelWriteKillSwitchSnapshot(writeEnabled: true) },
            sender: { _, _ in
                staleRecorder.record()
                return "eval-msg-stale"
            },
            store: staleStore
        )
        let staleQueued = await staleService.publish(
            AgentChannelPublishRequest(
                bindingId: "own-confirm", content: "queued body", intentKey: "k-stale"
            ),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        if case .queuedForApproval(let staleIntentId) = staleQueued {
            expect(true, "confirm intent queued for stale-approval pin")
            var repointed = configuration
            repointed.bindings = repointed.bindings.map { binding in
                guard binding.id == "own-confirm" else { return binding }
                var edited = binding
                edited.roomId = "R-ELSEWHERE"
                return edited
            }
            configurationBox.configuration = repointed
            let staleApproval = await staleService.approvePendingIntent(id: staleIntentId)
            expect(
                deniedCode(staleApproval) == "binding_route_changed",
                "approval after a binding repoint refused (got \(staleApproval.statusLabel))"
            )
        } else {
            expect(false, "confirm intent queued for stale-approval pin (got \(staleQueued.statusLabel))")
        }
        expect(
            staleRecorder.sendCount == 0,
            "no provider write through a repointed approval (\(staleRecorder.sendCount))"
        )
        staleStore.close()

        // Prompt payload: only the owner's usable bindings for the source,
        // and the publish tool is in the external-surface deny family.
        let section = SystemPromptComposer.channelDestinationsSection(
            bindings: configuration.usableBindings(agentId: ownerAgent),
            source: .schedule
        )
        expect(
            section?.contains("own-autonomous") == true,
            "prompt section lists the agent's own binding"
        )
        expect(
            section?.contains("other-agents") != true,
            "prompt section never lists another agent's binding"
        )
        expect(
            ToolRegistry.externallyDeniedToolNames.contains(AgentChannelPublishTool.toolName),
            "agent_channel_publish is externally denied"
        )

        // 8. Zero-config derived destinations: a native channel with a
        // writable room and an answering agent yields a confirm-only
        // automatic binding; removing the room from the allowlist makes a
        // queued approval refuse; a stored customization suppresses it.
        final class SourcesBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _sources: [AgentChannelAutoDestinationSource]
            init(_ sources: [AgentChannelAutoDestinationSource]) { _sources = sources }
            var sources: [AgentChannelAutoDestinationSource] {
                get { lock.withLock { _sources } }
                set { lock.withLock { _sources = newValue } }
            }
        }
        func derivedSource(rooms: [String]) -> AgentChannelAutoDestinationSource {
            AgentChannelAutoDestinationSource(
                connectionId: "eval-conn",
                displayName: "Eval Connection",
                hasCredential: true,
                writeEnabled: true,
                writableRoomIds: rooms,
                dispatch: AgentChannelInboundDispatchConfiguration(
                    enabled: true,
                    targetAgentId: ownerAgent
                )
            )
        }
        let sourcesBox = SourcesBox([derivedSource(rooms: ["R-EVAL"])])
        let derivedAutoId = AgentChannelAutoDestinationResolver.automaticBindingId(
            connectionId: "eval-conn",
            roomId: "R-EVAL",
            agentId: ownerAgent
        )
        let derivedOnly = AgentChannelAutoDestinationResolver.effectiveConfiguration(
            stored: AgentChannelConfiguration(),
            sources: sourcesBox.sources
        )
        expect(
            derivedOnly.binding(id: derivedAutoId)?.outboundMode == .confirm,
            "derived destination exists and is confirm-only"
        )
        let derivedSection = SystemPromptComposer.channelDestinationsSection(
            bindings: derivedOnly.usableBindings(agentId: ownerAgent),
            source: .schedule
        )
        expect(
            derivedSection?.contains(derivedAutoId) == true,
            "prompt section lists the derived destination"
        )
        let derivedRecorder = SendRecorder()
        let derivedStore = AgentChannelMessageStore()
        try? derivedStore.openInMemory()
        let derivedService = AgentChannelPublishService(
            loadConfiguration: {
                AgentChannelAutoDestinationResolver.effectiveConfiguration(
                    stored: AgentChannelConfiguration(),
                    sources: sourcesBox.sources
                )
            },
            resolveConnection: { _ in connection },
            killSwitchSnapshot: { ChannelWriteKillSwitchSnapshot(writeEnabled: true) },
            sender: { _, _ in
                derivedRecorder.record()
                return "eval-msg-derived"
            },
            store: derivedStore
        )
        let derivedQueued = await derivedService.publish(
            AgentChannelPublishRequest(
                bindingId: derivedAutoId, content: "derived body", intentKey: "k-derived"
            ),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        if case .queuedForApproval(let derivedIntentId) = derivedQueued {
            expect(true, "unattended publish to a derived destination queued for approval")
            sourcesBox.sources = [derivedSource(rooms: [])]
            let refusedApproval = await derivedService.approvePendingIntent(id: derivedIntentId)
            expect(
                deniedCode(refusedApproval) == "binding_removed",
                "approval refused after the room left the write allowlist (got \(refusedApproval.statusLabel))"
            )
        } else {
            expect(
                false,
                "unattended publish to a derived destination queued for approval (got \(derivedQueued.statusLabel))"
            )
        }
        expect(
            derivedRecorder.sendCount == 0,
            "no provider write through a vanished derived destination (\(derivedRecorder.sendCount))"
        )
        derivedStore.close()
        let customizedOff = AgentChannelAutoDestinationResolver.effectiveConfiguration(
            stored: AgentChannelConfiguration(
                bindings: [
                    AgentChannelBinding(
                        id: "custom-eval",
                        agentId: ownerAgent,
                        connectionId: "eval-conn",
                        roomId: "R-EVAL",
                        allowedSources: AgentChannelBindingRunSource.allCases,
                        outboundMode: .off
                    )
                ]
            ),
            sources: [derivedSource(rooms: ["R-EVAL"])]
        )
        expect(
            customizedOff.binding(id: derivedAutoId) == nil
                && customizedOff.usableBindings(agentId: ownerAgent).isEmpty,
            "a stored customization (off) suppresses the derived destination"
        )

        store.close()
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
