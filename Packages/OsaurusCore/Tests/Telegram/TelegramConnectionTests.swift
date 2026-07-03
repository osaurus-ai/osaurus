//
//  TelegramConnectionTests.swift
//  osaurusTests
//
//  Fixture coverage for the native Telegram agent channel.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct TelegramConnectionTests {

    @Test func configurationPersistsAllowlistsButNeverBotToken() async throws {
        try await withIsolatedTelegramStores { credentials in
            let token = "123456:telegram-bot-token-super-secret"
            try TelegramConnectionService(client: FakeTelegramAPIClient(), credentialStore: credentials)
                .saveBotToken(token)
            try TelegramConnectionService(client: FakeTelegramAPIClient(), credentialStore: credentials)
                .saveConfiguration(
                    TelegramConnectionConfiguration(
                        readableChatIds: [" -100111222333 ", "-100111222333", "@Ops_Channel"],
                        writableChatIds: ["-100444555666"],
                        senderAllowlist: [" 7 ", "7"],
                        writeEnabled: true,
                        defaultReadLimit: 250,
                        longPollingTimeoutSeconds: 0
                    )
                )

            let saved = TelegramConnectionConfigurationStore.load()
            #expect(saved.readableChatIds == ["-100111222333", "@ops_channel"])
            #expect(saved.senderAllowlist == ["7"])
            #expect(saved.defaultReadLimit == 100)
            #expect(saved.longPollingTimeoutSeconds == 1)
            #expect(!TelegramConnectionConfiguration.isValidChatId("١٢٣٤"))

            let disk = try String(
                contentsOf: TelegramConnectionConfigurationStore.configurationFileURL(),
                encoding: .utf8
            )
            #expect(disk.contains("-100111222333"))
            #expect(!disk.contains(token))
            #expect(!disk.localizedCaseInsensitiveContains("bot_token"))
        }
    }

    @Test func connectionManagerRejectsNativeTelegramId() async throws {
        try await withIsolatedTelegramStores { _ in
            let manager = AgentChannelConnectionManager()

            #expect(throws: AgentChannelConnectionManagerError.reservedConnectionId("telegram")) {
                try manager.upsertConnection(
                    AgentChannelConnection(
                        id: "telegram",
                        name: "Shadow Telegram",
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

    @Test func apiClientRedactsTokenEchoedByTelegramErrorBody() async throws {
        let token = "123456:telegram-bot-token-super-secret"
        let session = TelegramHTTPStubProtocol.session(
            statusCode: 403,
            body: #"{"ok":false,"error_code":403,"description":"Telegram echoed \#(token)"}"#
        )
        let client = TelegramAPIClient(
            baseURL: URL(string: "https://telegram.test")!,
            sessionProvider: { session }
        )

        do {
            _ = try await client.getChat(chatId: "-100111222333", token: token)
            Issue.record("Telegram request should have failed")
        } catch let error as TelegramAPIError {
            #expect(error.localizedDescription.contains("[REDACTED:TELEGRAM_BOT_TOKEN]"))
            #expect(!error.localizedDescription.contains(token))
        }
    }

    @Test func apiClientMapsLongPollConflictToTypedError() async throws {
        let token = "123456:telegram-bot-token-super-secret"
        let session = TelegramHTTPStubProtocol.session(
            statusCode: 409,
            body: #"{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}"#
        )
        let client = TelegramAPIClient(
            baseURL: URL(string: "https://telegram.test")!,
            sessionProvider: { session }
        )

        do {
            _ = try await client.getUpdates(offset: 99, limit: 250, timeout: 99, token: token)
            Issue.record("Telegram getUpdates should have failed with conflict")
        } catch let error as TelegramAPIError {
            #expect(error == .conflict("Conflict: terminated by other getUpdates request"))
        }

        let body = try #require(TelegramHTTPStubProtocol.lastRequestJSONBody())
        #expect(body["offset"] as? Int == 99)
        #expect(body["limit"] as? Int == 100)
        #expect(body["timeout"] as? Int == 50)
    }

    @Test func apiClientSendsPlainTextWithoutParseMode() async throws {
        let token = "123456:telegram-bot-token-super-secret"
        let session = TelegramHTTPStubProtocol.session(
            statusCode: 200,
            body: """
                {
                  "ok": true,
                  "result": {
                    "message_id": 77,
                    "date": 1782427200,
                    "chat": { "id": -100111222333, "type": "group", "title": "Ops" },
                    "from": { "id": 42, "is_bot": true, "first_name": "Osaurus", "username": "osaurus_bot" },
                    "text": "Hello <b>ops</b>"
                  }
                }
                """
        )
        let client = TelegramAPIClient(
            baseURL: URL(string: "https://telegram.test")!,
            sessionProvider: { session }
        )

        _ = try await client.sendMessage(
            chatId: "-100111222333",
            text: "Hello <b>ops</b>",
            replyToMessageId: 12,
            token: token
        )

        let body = try #require(TelegramHTTPStubProtocol.lastRequestJSONBody())
        #expect(body["chat_id"] as? String == "-100111222333")
        #expect(body["text"] as? String == "Hello <b>ops</b>")
        #expect(body["reply_to_message_id"] as? Int == 12)
        #expect(body["parse_mode"] == nil)
    }

    @Test func diagnosticsWarnWhenLongPollingHasNoSenderAllowlist() async throws {
        try await withIsolatedTelegramStores { credentials in
            let service = TelegramConnectionService(client: FakeTelegramAPIClient(), credentialStore: credentials)
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )

            let diagnostics = await service.diagnostics()

            #expect(diagnostics.status == "connected_receive_needs_sender_allowlist")
            #expect(diagnostics.failures.contains {
                $0.localizedCaseInsensitiveContains("no authorized sender IDs")
            })
        }
    }

    @Test func webhookPayloadNormalizesStoresAndDeduplicatesUpdates() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = TelegramConnectionService(
                client: FakeTelegramAPIClient(),
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(readableChatIds: ["-100111222333"], senderAllowlist: ["7"])
            )

            let data = Data(Self.updateJSON(updateId: 9001, messageId: 501, text: "deploy finished").utf8)
            let first = try await service.processWebhookPayload(
                data,
                secretTokenHeader: "hook-secret",
                expectedSecretToken: "hook-secret"
            )
            await #expect(throws: TelegramConnectionServiceError.invalidWebhookSecret) {
                _ = try await service.processWebhookPayload(
                    data,
                    secretTokenHeader: "wrong-secret",
                    expectedSecretToken: "hook-secret"
                )
            }
            let duplicate = try await service.processWebhookPayload(data)

            #expect(first.source == "webhook")
            #expect(first.stored == 1)
            #expect(first.results.first?.status == .accepted)
            #expect(duplicate.stored == 0)
            #expect(duplicate.results.first?.status == .duplicate)
            #expect(try store.messageCount(connectionId: "telegram", roomId: "-100111222333") == 1)
            #expect(try store.cursor(connectionId: "telegram", roomId: "__telegram_updates__") == nil)
        }
    }

    @Test func longPollUsesStoredOffsetAndUpdatesCursor() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            try store.upsertCursor(
                connectionId: "telegram",
                roomId: "__telegram_updates__",
                cursor: "42"
            )

            let fake = FakeTelegramAPIClient()
            await fake.setUpdates([
                .fixture(updateId: 42, messageId: 10, chatId: -100111222333, text: "from poll")
            ])
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(readableChatIds: ["-100111222333"], senderAllowlist: ["7"])
            )

            let result = try await service.pollUpdates(limit: 10, timeout: 0)

            #expect(result.source == "long_poll")
            #expect(result.stored == 1)
            #expect(await fake.lastUpdateOffset() == 42)
            #expect(try store.cursor(connectionId: "telegram", roomId: "__telegram_updates__") == "43")
        }
    }

    @Test func transportRuntimeUsesStoredOffsetBoundedPollingAndHealth() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }
            try store.upsertCursor(
                connectionId: "telegram",
                roomId: "__telegram_updates__",
                cursor: "42"
            )

            let fake = FakeTelegramAPIClient()
            await fake.setUpdates([
                .fixture(updateId: 42, messageId: 10, chatId: -100111222333, text: "from runtime")
            ])
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true,
                    longPollingLimit: 250,
                    longPollingTimeoutSeconds: 99
                )
            )
            let healthCenter = AgentChannelTransportHealthCenter()
            let runtime = TelegramLongPollTransportRuntime(
                service: service,
                healthCenter: healthCenter
            )

            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let result = await runtime.runStep(now: now, jitter: 0.5)

            #expect(result.disposition == .succeeded)
            #expect(result.received == 1)
            #expect(result.stored == 1)
            #expect(result.dispatchAttempted == 0)
            #expect(result.dispatchSuppressed == 1)
            #expect(result.health.status == .healthy)
            #expect(result.health.lastSuccessAt == now)
            #expect(await fake.lastUpdateOffset() == 42)
            #expect(await fake.lastUpdateLimit() == 100)
            #expect(await fake.lastUpdateTimeout() == 50)
            #expect(try store.cursor(connectionId: "telegram", roomId: "__telegram_updates__") == "43")
            let published = await healthCenter.state(
                connectionId: "telegram",
                transportId: TelegramLongPollTransportRuntime.transportId
            )
            #expect(published == result.health)
        }
    }

    @Test func transportRuntimeSurfacesTelegram409ConflictAsHealthState() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeTelegramAPIClient()
            await fake.failGetUpdatesWithConflict("Conflict: terminated by other getUpdates request")
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )
            let healthCenter = AgentChannelTransportHealthCenter()
            let runtime = TelegramLongPollTransportRuntime(
                service: service,
                healthCenter: healthCenter,
                backoffPolicy: AgentChannelTransportBackoffPolicy(
                    initialDelay: 4,
                    multiplier: 2,
                    maxDelay: 30,
                    jitterFraction: 0.25
                )
            )

            let now = Date(timeIntervalSince1970: 1_800_000_100)
            let result = await runtime.runStep(now: now, jitter: 0.5)

            #expect(result.disposition == .conflict)
            #expect(result.received == 0)
            #expect(result.stored == 0)
            #expect(result.dispatchAttempted == 0)
            #expect(result.retryDelay == 4)
            #expect(result.health.status == .conflict)
            #expect(result.health.severity == .error)
            #expect(result.health.nextRetryAt == now.addingTimeInterval(4))
            #expect(result.health.detail?.contains("Conflict") == true)
            #expect(try store.messageCount(connectionId: "telegram") == 0)
            #expect(try store.cursor(connectionId: "telegram", roomId: "__telegram_updates__") == nil)
            let published = await healthCenter.state(
                connectionId: "telegram",
                transportId: TelegramLongPollTransportRuntime.transportId
            )
            #expect(published == result.health)
        }
    }

    @Test func diagnosticsFlagRegisteredWebhookAsLongPollConflictTrap() async throws {
        try await withIsolatedTelegramStores { credentials in
            let token = "123456:telegram-bot-token-super-secret"
            let fake = FakeTelegramAPIClient()
            await fake.setWebhookInfo(
                TelegramWebhookInfo(
                    url: "https://hooks.example.test/telegram/\(token)",
                    pendingUpdateCount: 12
                )
            )
            let service = TelegramConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken(token)
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )

            let diagnostics = await service.diagnostics()

            #expect(diagnostics.status == "connected_long_poll_webhook_conflict")
            #expect(diagnostics.webhook?.registered == true)
            #expect(diagnostics.webhook?.pendingUpdateCount == 12)
            #expect(diagnostics.webhook?.redactedURL.contains("[REDACTED:TELEGRAM_BOT_TOKEN]") == true)
            #expect(diagnostics.webhook?.redactedURL.contains(token) == false)
            let failure = try #require(
                diagnostics.failures.first { $0.localizedCaseInsensitiveContains("webhook") }
            )
            #expect(failure.contains("409"))
            #expect(!failure.contains(token))
            let row = try #require(diagnostics.dictionary["webhook"] as? [String: Any])
            #expect(row["registered"] as? Bool == true)
        }
    }

    @Test func diagnosticsIgnoreWebhookWhenLongPollingDisabled() async throws {
        try await withIsolatedTelegramStores { credentials in
            let fake = FakeTelegramAPIClient()
            await fake.setWebhookInfo(TelegramWebhookInfo(url: "https://hooks.example.test/telegram"))
            let service = TelegramConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: false
                )
            )

            let diagnostics = await service.diagnostics()

            #expect(diagnostics.status == "connected_read_only")
            #expect(diagnostics.webhook?.registered == true)
            #expect(!diagnostics.failures.contains { $0.localizedCaseInsensitiveContains("webhook") })
        }
    }

    @Test func diagnosticsExplainEmptyReadsWhenLongPollingDisabled() async throws {
        try await withIsolatedTelegramStores { credentials in
            let fake = FakeTelegramAPIClient()
            let service = TelegramConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: false
                )
            )

            let diagnostics = await service.diagnostics()

            #expect(diagnostics.status == "connected_read_only")
            #expect(diagnostics.failures.isEmpty)
            let note = try #require(
                diagnostics.notes.first { $0.localizedCaseInsensitiveContains("long polling") }
            )
            #expect(note.localizedCaseInsensitiveContains("disabled"))
            let rows = try #require(diagnostics.dictionary["notes"] as? [String])
            #expect(rows == diagnostics.notes)
        }
    }

    @Test func diagnosticsOmitEmptyReadsNoteWhenLongPollingEnabled() async throws {
        try await withIsolatedTelegramStores { credentials in
            let fake = FakeTelegramAPIClient()
            let service = TelegramConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )

            let diagnostics = await service.diagnostics()

            #expect(diagnostics.status == "connected_read_only")
            #expect(diagnostics.notes.isEmpty)
            #expect(diagnostics.dictionary["notes"] == nil)
        }
    }

    @Test func clearWebhookDeletesRegisteredWebhookAndReturnsClearedInfo() async throws {
        try await withIsolatedTelegramStores { credentials in
            let fake = FakeTelegramAPIClient()
            await fake.setWebhookInfo(TelegramWebhookInfo(url: "https://hooks.example.test/telegram"))
            let service = TelegramConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("123456:telegram-bot-token-super-secret")

            let cleared = try await service.clearWebhook()

            #expect(await fake.deleteWebhookCallCount() == 1)
            #expect(!cleared.isRegistered)
        }
    }

    @Test func transportRuntimeEnrichesConflictDetailWithWebhookAdvice() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let token = "123456:telegram-bot-token-super-secret"
            let fake = FakeTelegramAPIClient()
            await fake.failGetUpdatesWithConflict("Conflict: terminated by other getUpdates request")
            await fake.setWebhookInfo(
                TelegramWebhookInfo(url: "https://hooks.example.test/telegram/\(token)")
            )
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken(token)
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )
            let runtime = TelegramLongPollTransportRuntime(
                service: service,
                healthCenter: AgentChannelTransportHealthCenter()
            )

            let result = await runtime.runStep(now: Date(timeIntervalSince1970: 1_800_000_300), jitter: 0.5)

            #expect(result.disposition == .conflict)
            #expect(result.health.status == .conflict)
            let detail = try #require(result.health.detail)
            #expect(detail.localizedCaseInsensitiveContains("webhook is registered"))
            #expect(detail.contains("[REDACTED:TELEGRAM_BOT_TOKEN]"))
            #expect(!detail.contains(token))
        }
    }

    @Test func transportRuntimeReportsCompetingPollerWhenNoWebhookRegistered() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeTelegramAPIClient()
            await fake.failGetUpdatesWithConflict("Conflict: terminated by other getUpdates request")
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )
            let runtime = TelegramLongPollTransportRuntime(
                service: service,
                healthCenter: AgentChannelTransportHealthCenter()
            )

            let result = await runtime.runStep(now: Date(timeIntervalSince1970: 1_800_000_350), jitter: 0.5)

            #expect(result.disposition == .conflict)
            let detail = try #require(result.health.detail)
            #expect(detail.localizedCaseInsensitiveContains("another getupdates consumer"))
        }
    }

    @Test func transportRuntimeHonorsTelegramRetryAfterOnRateLimit() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeTelegramAPIClient()
            await fake.failGetUpdatesWithRateLimit("Too Many Requests: retry after 30", retryAfter: 30)
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )
            let runtime = TelegramLongPollTransportRuntime(
                service: service,
                healthCenter: AgentChannelTransportHealthCenter()
            )

            let now = Date(timeIntervalSince1970: 1_800_000_400)
            let result = await runtime.runStep(now: now, jitter: 0.5)

            // First-failure backoff would be ~1s; Telegram asked for 30s.
            #expect(result.disposition == .failed)
            #expect(result.retryDelay == 30)
            #expect(result.health.status == .degraded)
            #expect(result.health.severity == .warning)
            #expect(result.health.nextRetryAt == now.addingTimeInterval(30))
        }
    }

    @Test func longPollRunLoopBacksOffAcrossFailuresAndRecovers() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeTelegramAPIClient()
            await fake.failGetUpdatesPersistently(
                .requestFailed("Telegram getUpdates transport failure")
            )
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )
            let sleeper = RecordingTransportSleeper()
            let runtime = TelegramLongPollTransportRuntime(
                service: service,
                healthCenter: AgentChannelTransportHealthCenter(),
                backoffPolicy: AgentChannelTransportBackoffPolicy(
                    initialDelay: 1,
                    multiplier: 2,
                    maxDelay: 60,
                    jitterFraction: 0
                ),
                sleeper: sleeper
            )

            await runtime.start(pollInterval: 1)
            let sawFailures = await waitForTransportCondition {
                await sleeper.recordedDelays().count >= 3
            }
            #expect(sawFailures)

            // The loop retries on its own with exponential backoff.
            let delays = await sleeper.recordedDelays()
            #expect(Array(delays.prefix(3)) == [1, 2, 4])

            // When Telegram recovers, the loop returns to healthy polling and
            // the failure penalty resets without outside intervention.
            await fake.clearPersistentGetUpdatesFailure()
            let recovered = await waitForTransportCondition {
                let health = await runtime.health()
                return health.status == .healthy && health.consecutiveFailures == 0
            }
            #expect(recovered)

            await runtime.stop()
            let stopped = await runtime.health()
            #expect(stopped.status == .idle)
            #expect(stopped.isRunning == false)
        }
    }

    @Test func longPollStopCancelsInFlightPollAndReturnsPromptly() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeTelegramAPIClient()
            await fake.hangGetUpdatesUntilCancelled()
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )
            let runtime = TelegramLongPollTransportRuntime(
                service: service,
                healthCenter: AgentChannelTransportHealthCenter(),
                sleeper: RecordingTransportSleeper()
            )

            await runtime.start(pollInterval: 1)
            let pollStarted = await waitForTransportCondition {
                await fake.getUpdatesCallCount() >= 1
            }
            #expect(pollStarted)

            // Stopping while a long poll is parked must cancel the in-flight
            // request instead of waiting out the poll timeout.
            await runtime.stop()

            let health = await runtime.health()
            #expect(health.status == .idle)
            #expect(health.isRunning == false)
        }
    }

    @Test func apiClientDecodesRetryAfterFromRateLimitEnvelope() async throws {
        let token = "123456:telegram-bot-token-super-secret"
        let session = TelegramHTTPStubProtocol.session(
            statusCode: 429,
            body: #"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 17","parameters":{"retry_after":17}}"#
        )
        let client = TelegramAPIClient(
            baseURL: URL(string: "https://telegram.test")!,
            sessionProvider: { session }
        )

        do {
            _ = try await client.getUpdates(offset: nil, limit: 10, timeout: 0, token: token)
            Issue.record("Telegram getUpdates should have been rate limited")
        } catch let error as TelegramAPIError {
            #expect(error == .rateLimited("Too Many Requests: retry after 17", retryAfter: 17))
        }
    }

    @Test func apiClientFetchesAndDeletesWebhook() async throws {
        let token = "123456:telegram-bot-token-super-secret"
        let session = TelegramHTTPStubProtocol.session(
            statusCode: 200,
            body: #"{"ok":true,"result":{"url":"https://hooks.example.test/tg","has_custom_certificate":false,"pending_update_count":3}}"#
        )
        let client = TelegramAPIClient(
            baseURL: URL(string: "https://telegram.test")!,
            sessionProvider: { session }
        )

        let info = try await client.getWebhookInfo(token: token)
        #expect(info.isRegistered)
        #expect(info.url == "https://hooks.example.test/tg")
        #expect(info.pendingUpdateCount == 3)

        let deleteSession = TelegramHTTPStubProtocol.session(
            statusCode: 200,
            body: #"{"ok":true,"result":true}"#
        )
        let deleteClient = TelegramAPIClient(
            baseURL: URL(string: "https://telegram.test")!,
            sessionProvider: { deleteSession }
        )
        #expect(try await deleteClient.deleteWebhook(token: token))
    }

    @Test func transportRuntimeStoresReceiveOnlyMessagesWithoutDispatch() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeTelegramAPIClient()
            await fake.setUpdates([
                .fixture(updateId: 51, messageId: 501, chatId: -100111222333, text: "store only")
            ])
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    writeEnabled: false,
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            )
            let runtime = TelegramLongPollTransportRuntime(
                service: service,
                healthCenter: AgentChannelTransportHealthCenter()
            )

            let result = await runtime.runStep(now: Date(timeIntervalSince1970: 1_800_000_200), jitter: 0.5)

            #expect(result.disposition == .succeeded)
            #expect(result.stored == 1)
            #expect(result.dispatchAttempted == 0)
            #expect(result.dispatchSuppressed == 1)
            #expect(try store.messageCount(connectionId: "telegram", roomId: "-100111222333") == 1)
            let stored = try #require(
                try store.recentMessages(
                    connectionId: "telegram",
                    roomId: "-100111222333",
                    limit: 1
                ).first
            )
            #expect(stored.direction == .inbound)
            #expect(stored.content == "store only")
        }
    }

    @Test func transportSupervisorStartsTelegramRuntimeOnlyWhenLongPollingIsEnabled() async {
        let runtime = SpyReceiveTransportRuntime()
        let supervisor = AgentChannelTransportSupervisor(
            telegramConfiguration: {
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            },
            telegramHasBotToken: { true },
            telegramRuntime: runtime
        )

        await supervisor.startFromLaunch()
        await supervisor.startFromLaunch()

        #expect(await runtime.startCount() == 1)
        #expect(await runtime.stopCount() == 0)
    }

    @Test func transportSupervisorDoesNotStartTelegramRuntimeWithoutSenderAllowlist() async {
        let runtime = SpyReceiveTransportRuntime()
        let supervisor = AgentChannelTransportSupervisor(
            telegramConfiguration: {
                TelegramConnectionConfiguration(
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            },
            telegramHasBotToken: { true },
            telegramRuntime: runtime
        )

        await supervisor.startFromLaunch()

        #expect(await runtime.startCount() == 0)
        #expect(await runtime.stopCount() == 0)
    }

    @Test func transportSupervisorDoesNotStartTelegramRuntimeWithoutReadableChats() async {
        let runtime = SpyReceiveTransportRuntime()
        let supervisor = AgentChannelTransportSupervisor(
            telegramConfiguration: {
                TelegramConnectionConfiguration(
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            },
            telegramHasBotToken: { true },
            telegramRuntime: runtime
        )

        await supervisor.startFromLaunch()

        #expect(await runtime.startCount() == 0)
        #expect(await runtime.stopCount() == 0)
    }

    @Test func transportSupervisorStopsTelegramRuntimeWhenLongPollingIsDisabled() async {
        let runtime = SpyReceiveTransportRuntime()
        let configuration = TelegramConfigurationBox(
            TelegramConnectionConfiguration(
                readableChatIds: ["-100111222333"],
                senderAllowlist: ["7"],
                receiveStorageEnabled: true,
                longPollingEnabled: true
            )
        )
        let supervisor = AgentChannelTransportSupervisor(
            telegramConfiguration: { configuration.value() },
            telegramHasBotToken: { true },
            telegramRuntime: runtime
        )
        let stopDate = Date(timeIntervalSince1970: 1_800_000_500)

        await supervisor.startFromLaunch()
        configuration.set(
            TelegramConnectionConfiguration(
                readableChatIds: ["-100111222333"],
                senderAllowlist: ["7"],
                receiveStorageEnabled: true,
                longPollingEnabled: false
            )
        )
        await supervisor.refreshTelegramRuntime(now: stopDate)

        #expect(await runtime.startCount() == 1)
        #expect(await runtime.stopCount() == 1)
        #expect(await runtime.lastStopDate() == stopDate)
    }

    @Test func transportSupervisorStopsTelegramRuntimeWhenBotTokenIsRemoved() async {
        let runtime = SpyReceiveTransportRuntime()
        let hasToken = TelegramTokenPresenceBox(true)
        let supervisor = AgentChannelTransportSupervisor(
            telegramConfiguration: {
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    receiveStorageEnabled: true,
                    longPollingEnabled: true
                )
            },
            telegramHasBotToken: { hasToken.value() },
            telegramRuntime: runtime
        )
        let stopDate = Date(timeIntervalSince1970: 1_800_000_700)

        await supervisor.startFromLaunch()
        hasToken.set(false)
        await supervisor.refreshTelegramRuntime(now: stopDate)

        #expect(await runtime.startCount() == 1)
        #expect(await runtime.stopCount() == 1)
        #expect(await runtime.lastStopDate() == stopDate)
    }

    @Test func normalizationSkipsUnauthorizedSelfAndBotMessages() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = TelegramConnectionService(
                client: FakeTelegramAPIClient(),
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(readableChatIds: ["-100111222333"], senderAllowlist: ["7"])
            )

            let result = try await service.processUpdates(
                [
                    .fixture(updateId: 1, messageId: 1, chatId: -100999888777, text: "blocked"),
                    .fixture(
                        updateId: 2,
                        messageId: 2,
                        chatId: -100111222333,
                        text: "self",
                        from: .fixture(id: 42, isBot: true)
                    ),
                    .fixture(
                        updateId: 3,
                        messageId: 3,
                        chatId: -100111222333,
                        text: "another bot",
                        from: .fixture(id: 99, isBot: true)
                    ),
                ],
                source: "fixture"
            )

            #expect(result.stored == 0)
            #expect(result.results.map(\.status) == [.unauthorized, .ignored, .ignored])
            #expect(result.results.map(\.reason) == [
                "room_not_allowlisted",
                "self_message_denied",
                "bot_message_denied",
            ])
            #expect(try store.messageCount(connectionId: "telegram") == 0)
        }
    }

    @Test func inboundReceiveRequiresSenderAllowlistBeforeStorage() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = TelegramConnectionService(
                client: FakeTelegramAPIClient(),
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveConfiguration(
                TelegramConnectionConfiguration(readableChatIds: ["-100111222333"], senderAllowlist: ["99"])
            )

            let result = try await service.processUpdates(
                [.fixture(updateId: 9, messageId: 9, chatId: -100111222333, text: "do the thing")],
                source: "fixture"
            )

            #expect(result.stored == 0)
            #expect(result.results.first?.status == .unauthorized)
            #expect(result.results.first?.reason == "sender_not_allowlisted")
            #expect(try store.messageCount(connectionId: "telegram") == 0)
            #expect(try store.isEventSeen(connectionId: "telegram", providerEventId: "9") == false)
        }
    }

    @Test func inboundReceiveDeniesWhenSenderAllowlistIsEmpty() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = TelegramConnectionService(
                client: FakeTelegramAPIClient(),
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveConfiguration(
                TelegramConnectionConfiguration(readableChatIds: ["-100111222333"])
            )

            let result = try await service.processUpdates(
                [.fixture(updateId: 10, messageId: 10, chatId: -100111222333, text: "no sender policy")],
                source: "fixture"
            )

            #expect(result.stored == 0)
            #expect(result.results.first?.status == .unauthorized)
            #expect(result.results.first?.reason == "sender_not_allowlisted")
            #expect(try store.messageCount(connectionId: "telegram") == 0)
            #expect(try store.isEventSeen(connectionId: "telegram", providerEventId: "10") == false)
        }
    }

    @Test func cachedBotIdentityPreservesSelfDenialWhenGetMeFails() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeTelegramAPIClient()
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7", "42"]
                )
            )

            let warm = try await service.processUpdates(
                [.fixture(updateId: 21, messageId: 21, chatId: -100111222333, text: "warm cache")],
                source: "fixture"
            )
            await fake.failNextGetMe()
            let selfMessage = try await service.processUpdates(
                [
                    .fixture(
                        updateId: 22,
                        messageId: 22,
                        chatId: -100111222333,
                        text: "self echo",
                        from: .fixture(id: 42, isBot: false)
                    ),
                ],
                source: "fixture"
            )

            #expect(warm.stored == 1)
            #expect(selfMessage.stored == 0)
            #expect(selfMessage.results.first?.status == .ignored)
            #expect(selfMessage.results.first?.reason == "self_message_denied")
            #expect(try store.messageCount(connectionId: "telegram", roomId: "-100111222333") == 1)
        }
    }

    @Test func inboundReceiveDropsEmptyAndOversizedContentBeforeStorage() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = TelegramConnectionService(
                client: FakeTelegramAPIClient(),
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveConfiguration(
                TelegramConnectionConfiguration(readableChatIds: ["-100111222333"], senderAllowlist: ["7"])
            )

            let twoCodeUnitScalar = String(UnicodeScalar(0x1F600)!)
            let result = try await service.processUpdates(
                [
                    .fixture(updateId: 31, messageId: 31, chatId: -100111222333, text: ""),
                    .fixture(
                        updateId: 32,
                        messageId: 32,
                        chatId: -100111222333,
                        text: String(repeating: "x", count: 4097)
                    ),
                    .fixture(
                        updateId: 33,
                        messageId: 33,
                        chatId: -100111222333,
                        text: String(repeating: twoCodeUnitScalar, count: 2049)
                    ),
                ],
                source: "fixture"
            )

            #expect(result.stored == 0)
            #expect(result.results.map(\.status) == [.ignored, .ignored, .ignored])
            #expect(result.results.map(\.reason) == [
                "empty_message_content",
                "message_too_long",
                "message_too_long",
            ])
            #expect(try store.messageCount(connectionId: "telegram") == 0)
            #expect(try store.isEventSeen(connectionId: "telegram", providerEventId: "31") == false)
            #expect(try store.isEventSeen(connectionId: "telegram", providerEventId: "32") == false)
            #expect(try store.isEventSeen(connectionId: "telegram", providerEventId: "33") == false)
        }
    }

    @Test func readAndSearchUseSQLiteBackedTelegramMessages() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = TelegramConnectionService(
                client: FakeTelegramAPIClient(),
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveConfiguration(
                TelegramConnectionConfiguration(readableChatIds: ["-100111222333"], senderAllowlist: ["7"])
            )
            _ = try await service.processUpdates(
                [
                    .fixture(updateId: 10, messageId: 1, chatId: -100111222333, text: "eval reports landed"),
                    .fixture(updateId: 11, messageId: 2, chatId: -100111222333, text: "ordinary update"),
                ],
                source: "fixture"
            )

            let read = try service.readChat(TelegramReadRequest(chatId: "-100111222333", limit: 5))
            let messages = try #require(read["messages"] as? [[String: Any]])
            #expect(messages.count == 2)

            let search = try service.searchMessages(
                query: "eval",
                chatIds: ["-100111222333"],
                limitPerChat: 10,
                maxMatches: 10
            )
            #expect(search["match_count"] as? Int == 1)
        }
    }

    @Test func usernameAllowlistStoresAndReadsByConfiguredHandle() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = TelegramConnectionService(
                client: FakeTelegramAPIClient(),
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["@Ops_Channel"],
                    writableChatIds: ["@Ops_Channel"],
                    senderAllowlist: ["7"],
                    writeEnabled: true
                )
            )
            _ = try await service.processUpdates(
                [
                    .fixture(
                        updateId: 20,
                        messageId: 3,
                        chatId: -100111222333,
                        text: "eval report ready",
                        chatUsername: "Ops_Channel"
                    ),
                ],
                source: "fixture"
            )

            #expect(try store.messageCount(connectionId: "telegram", roomId: "@ops_channel") == 1)

            let listed = try await service.listChats()
            let room = try #require(listed.first)
            #expect(room["id"] as? String == "@ops_channel")
            #expect(room["provider_chat_id"] as? String == "-100111222333")
            _ = try await service.sendMessage(
                TelegramWriteRequest(
                    chatId: "@OPS_CHANNEL",
                    text: "ack",
                    replyToMessageId: nil,
                    confirmSend: true
                )
            )

            let read = try service.readChat(TelegramReadRequest(chatId: "@OPS_CHANNEL", limit: 5))
            let messages = try #require(read["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(messages.contains { $0["direction"] as? String == "outbound" })

            let search = try service.searchMessages(
                query: "eval",
                chatIds: ["@OPS_CHANNEL"],
                limitPerChat: 10,
                maxMatches: 10
            )
            #expect(search["match_count"] as? Int == 1)
        }
    }

    @Test func sendMessageRequiresConfirmationMapsStatusAndRecordsOutbound() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeTelegramAPIClient()
            let service = TelegramConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("123456:telegram-bot-token-super-secret")
            try service.saveConfiguration(
                TelegramConnectionConfiguration(
                    writableChatIds: ["-100111222333"],
                    writeEnabled: true
                )
            )

            await #expect(throws: TelegramConnectionServiceError.sendConfirmationRequired) {
                _ = try await service.sendMessage(
                    TelegramWriteRequest(
                        chatId: "-100111222333",
                        text: "ship it",
                        replyToMessageId: nil,
                        confirmSend: false
                    )
                )
            }
            await #expect(throws: TelegramConnectionServiceError.messageTooLong) {
                let twoCodeUnitScalar = String(UnicodeScalar(0x1F600)!)
                _ = try await service.sendMessage(
                    TelegramWriteRequest(
                        chatId: "-100111222333",
                        text: String(repeating: twoCodeUnitScalar, count: 2049),
                        replyToMessageId: nil,
                        confirmSend: true
                    )
                )
            }

            let sent = try await service.sendMessage(
                TelegramWriteRequest(
                    chatId: "-100111222333",
                    text: "ship it",
                    replyToMessageId: 99,
                    confirmSend: true
                )
            )

            #expect(sent["delivery_status"] as? String == TelegramDeliveryStatus.sent.rawValue)
            #expect(await fake.lastSentText() == "ship it")
            #expect(await fake.lastReplyToMessageId() == 99)
            let row = try #require(
                try store.recentMessages(
                    connectionId: "telegram",
                    roomId: "-100111222333",
                    limit: 1
                ).first
            )
            #expect(row.direction == .outbound)
            #expect(row.content == "ship it")
            #expect(!row.payloadJSON.localizedCaseInsensitiveContains("telegram-bot-token-super-secret"))
        }
    }

    @Test func standardAgentChannelServiceRoutesTelegramConnection() async throws {
        try await withIsolatedTelegramStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let telegram = TelegramConnectionService(
                client: FakeTelegramAPIClient(),
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try telegram.saveBotToken("123456:telegram-bot-token-super-secret")
            try telegram.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    writableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"],
                    writeEnabled: true
                )
            )
            _ = try await telegram.processUpdates(
                [.fixture(updateId: 700, messageId: 17, chatId: -100111222333, text: "ops ready")],
                source: "fixture"
            )

            let service = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeDiscordAPIClientForTelegramTests(),
                    credentialStore: FakeDiscordCredentialStoreForTelegramTests()
                ),
                telegramService: telegram
            )

            let telegramRow = try #require(
                service.listConnections().first { $0["id"] as? String == "telegram" }
            )
            #expect(telegramRow["configured"] as? Bool == true)
            #expect(telegramRow["credential_saved"] as? Bool == true)
            let inboundAuthorization = try #require(
                telegramRow["inbound_authorization"] as? [String: Any]
            )
            #expect(inboundAuthorization["sender_allowlist"] as? [String] == ["7"])
            #expect(inboundAuthorization["room_allowlist"] as? [String] == ["-100111222333"])
            #expect(
                inboundAuthorization["dispatch_contract"] as? String
                    == "authorize_before_agent_context_or_tool_input"
            )

            let read = try await service.readMessages(
                connectionId: "telegram",
                roomId: "-100111222333",
                limit: 5
            )
            let messages = try #require(read["messages"] as? [[String: Any]])
            #expect(messages.first?["content"] as? String == "ops ready")

            await AgentChannelTransportHealthCenter.shared.clear(connectionId: "telegram")
            await AgentChannelTransportHealthCenter.shared.update(
                AgentChannelTransportHealthState(
                    connectionId: "telegram",
                    transportId: TelegramLongPollTransportRuntime.transportId,
                    provider: .telegram,
                    status: .healthy,
                    severity: .info,
                    summary: "Telegram long polling is healthy.",
                    isRunning: true,
                    receiveEnabled: true,
                    lastReceivedCount: 1,
                    lastStoredCount: 1
                )
            )
            let diagnostics = await service.diagnostics(connectionId: "telegram")
            let healthRows = try #require(diagnostics["transport_health"] as? [[String: Any]])
            #expect(healthRows.first?["transport_id"] as? String == TelegramLongPollTransportRuntime.transportId)
            #expect(healthRows.first?["status"] as? String == "healthy")
            await AgentChannelTransportHealthCenter.shared.clear(connectionId: "telegram")
        }
    }

    @Test func agentChannelReadToolRejectsChatsOutsideTelegramReadAllowlist() async throws {
        try await withIsolatedTelegramStores { credentials in
            let telegram = TelegramConnectionService(
                client: FakeTelegramAPIClient(),
                credentialStore: credentials
            )
            try telegram.saveBotToken("123456:telegram-bot-token-super-secret")
            try telegram.saveConfiguration(
                TelegramConnectionConfiguration(
                    readableChatIds: ["-100111222333"],
                    senderAllowlist: ["7"]
                )
            )
            let service = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeDiscordAPIClientForTelegramTests(),
                    credentialStore: FakeDiscordCredentialStoreForTelegramTests()
                ),
                telegramService: telegram
            )
            let tool = AgentChannelReadMessagesTool(service: service)

            let result = try await tool.execute(
                argumentsJSON: #"{"connection_id":"telegram","room_id":"-100999888777"}"#
            )

            #expect(EnvelopeAssertions.failureKind(result) == "rejected")
            #expect(EnvelopeAssertions.failureMessage(result)?.contains("not allowlisted") == true)
        }
    }

    private static func updateJSON(updateId: Int64, messageId: Int, text: String) -> String {
        """
        {
          "update_id": \(updateId),
          "message": {
            "message_id": \(messageId),
            "date": 1782427200,
            "chat": { "id": -100111222333, "type": "group", "title": "Ops" },
            "from": { "id": 7, "is_bot": false, "first_name": "Mika", "username": "mika" },
            "text": "\(text)"
          }
        }
        """
    }

    private func withIsolatedTelegramStores(
        _ body: @Sendable (any TelegramCredentialStorage) async throws -> Void
    ) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let previousTelegramDirectory = TelegramConnectionConfigurationStore.overrideDirectory
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-telegram-tests-\(UUID().uuidString)", isDirectory: true)
            let credentials = FakeTelegramCredentialStore()
            TelegramConnectionConfigurationStore.overrideDirectory = directory
            defer {
                TelegramConnectionConfigurationStore.overrideDirectory = previousTelegramDirectory
                try? FileManager.default.removeItem(at: directory)
            }
            try await body(credentials)
        }
    }
}

private final class FakeTelegramCredentialStore: TelegramCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storedToken: String?

    func saveBotToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        lock.withLock { storedToken = trimmed }
        return true
    }

    func botToken() -> String? {
        lock.withLock { storedToken }
    }

    func hasBotToken() -> Bool {
        botToken() != nil
    }

    func deleteBotToken() -> Bool {
        lock.withLock { storedToken = nil }
        return true
    }
}

private actor FakeTelegramAPIClient: TelegramAPIClientProtocol {
    private var updates: [TelegramUpdate] = []
    private var lastOffset: Int64?
    private var lastLimit: Int?
    private var lastTimeout: Int?
    private var sentMessages: [(chatId: String, text: String, replyToMessageId: Int?)] = []
    private var getMeFailuresRemaining = 0
    private var getUpdatesConflictMessage: String?
    private var getUpdatesRateLimit: (message: String, retryAfter: Int?)?
    private var persistentGetUpdatesError: TelegramAPIError?
    private var hangGetUpdates = false
    private var getUpdatesCalls = 0
    private var webhookInfo = TelegramWebhookInfo(url: "")
    private var deleteWebhookCalls = 0

    func setUpdates(_ updates: [TelegramUpdate]) {
        self.updates = updates
    }

    func failGetUpdatesWithConflict(_ message: String) {
        getUpdatesConflictMessage = message
    }

    func failGetUpdatesWithRateLimit(_ message: String, retryAfter: Int?) {
        getUpdatesRateLimit = (message, retryAfter)
    }

    /// Fails every getUpdates call until cleared, for run-loop backoff tests.
    func failGetUpdatesPersistently(_ error: TelegramAPIError) {
        persistentGetUpdatesError = error
    }

    func clearPersistentGetUpdatesFailure() {
        persistentGetUpdatesError = nil
    }

    /// Parks getUpdates on a long sleep so tests can cancel an in-flight poll.
    func hangGetUpdatesUntilCancelled() {
        hangGetUpdates = true
    }

    func getUpdatesCallCount() -> Int {
        getUpdatesCalls
    }

    func failNextGetMe() {
        getMeFailuresRemaining += 1
    }

    func setWebhookInfo(_ info: TelegramWebhookInfo) {
        webhookInfo = info
    }

    func deleteWebhookCallCount() -> Int {
        deleteWebhookCalls
    }

    func lastUpdateOffset() -> Int64? {
        lastOffset
    }

    func lastUpdateLimit() -> Int? {
        lastLimit
    }

    func lastUpdateTimeout() -> Int? {
        lastTimeout
    }

    func lastSentText() -> String? {
        sentMessages.last?.text
    }

    func lastReplyToMessageId() -> Int? {
        sentMessages.last?.replyToMessageId
    }

    func getMe(token: String) async throws -> TelegramUser {
        if getMeFailuresRemaining > 0 {
            getMeFailuresRemaining -= 1
            throw TelegramAPIError.requestFailed("temporary getMe failure")
        }
        return TelegramUser.fixture(id: 42, isBot: true)
    }

    func getChat(chatId: String, token: String) async throws -> TelegramChat {
        TelegramChat(
            id: Int64(chatId) ?? -100111222333,
            type: "group",
            title: "Ops",
            username: chatId.hasPrefix("@") ? String(chatId.dropFirst()) : nil,
            firstName: nil,
            lastName: nil
        )
    }

    func getWebhookInfo(token: String) async throws -> TelegramWebhookInfo {
        webhookInfo
    }

    func deleteWebhook(token: String) async throws -> Bool {
        deleteWebhookCalls += 1
        webhookInfo = TelegramWebhookInfo(url: "")
        return true
    }

    func getUpdates(offset: Int64?, limit: Int, timeout: Int, token: String) async throws -> [TelegramUpdate] {
        lastOffset = offset
        lastLimit = limit
        lastTimeout = timeout
        getUpdatesCalls += 1
        if hangGetUpdates {
            // Mimics a long poll waiting on Telegram; only task cancellation
            // (CancellationError from Task.sleep) can end it.
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
        if let persistentGetUpdatesError {
            throw persistentGetUpdatesError
        }
        if let getUpdatesConflictMessage {
            self.getUpdatesConflictMessage = nil
            throw TelegramAPIError.conflict(getUpdatesConflictMessage)
        }
        if let getUpdatesRateLimit {
            self.getUpdatesRateLimit = nil
            throw TelegramAPIError.rateLimited(getUpdatesRateLimit.message, retryAfter: getUpdatesRateLimit.retryAfter)
        }
        return Array(updates.prefix(limit))
    }

    func sendMessage(
        chatId: String,
        text: String,
        replyToMessageId: Int?,
        token: String
    ) async throws -> TelegramMessage {
        sentMessages.append((chatId: chatId, text: text, replyToMessageId: replyToMessageId))
        return TelegramMessage.fixture(
            messageId: 800 + sentMessages.count,
            chatId: Int64(chatId) ?? -100111222333,
            text: text,
            from: .fixture(id: 42, isBot: true),
            replyToMessageId: replyToMessageId
        )
    }
}

private actor FakeDiscordAPIClientForTelegramTests: DiscordAPIClientProtocol {
    func currentUser(token: String) async throws -> DiscordBotIdentity {
        DiscordBotIdentity(id: "1", username: "bot", globalName: "Bot", bot: true)
    }

    func guild(id: String, token: String) async throws -> DiscordGuild {
        DiscordGuild(id: id, name: "Guild")
    }

    func channels(guildId: String, token: String) async throws -> [DiscordChannel] {
        []
    }

    func messages(channelId: String, token: String, limit: Int) async throws -> [DiscordMessage] {
        []
    }

    func sendMessage(channelId: String, content: String, token: String) async throws -> DiscordMessage {
        DiscordMessage(
            id: "1",
            channelId: channelId,
            content: content,
            timestamp: "2026-06-25T00:00:00Z",
            author: DiscordMessageAuthor(id: "1", username: "bot", globalName: "Bot", bot: true),
            attachments: []
        )
    }
}

private final class FakeDiscordCredentialStoreForTelegramTests: DiscordCredentialStorage, @unchecked Sendable {
    func saveBotToken(_ token: String) -> Bool { true }
    func botToken() -> String? { nil }
    func hasBotToken() -> Bool { false }
    func deleteBotToken() -> Bool { true }
}

private final class TelegramConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TelegramConnectionConfiguration

    init(_ configuration: TelegramConnectionConfiguration) {
        self.stored = configuration
    }

    func value() -> TelegramConnectionConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ configuration: TelegramConnectionConfiguration) {
        lock.lock()
        stored = configuration
        lock.unlock()
    }
}

private final class TelegramTokenPresenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        self.stored = value
    }

    func value() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private actor SpyReceiveTransportRuntime: AgentChannelReceiveTransportRuntime {
    private var starts = 0
    private var stops = 0
    private var stoppedAt: Date?

    func start(pollInterval: TimeInterval) async {
        starts += 1
    }

    func stop(now: Date) async {
        stops += 1
        stoppedAt = now
    }

    func startCount() -> Int {
        starts
    }

    func stopCount() -> Int {
        stops
    }

    func lastStopDate() -> Date? {
        stoppedAt
    }
}

private final class TelegramHTTPStubProtocol: URLProtocol {
    nonisolated(unsafe) private static var statusCode: Int = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var requestBody = Data()

    static func session(statusCode: Int, body: String) -> URLSession {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
        requestBody = Data()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelegramHTTPStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func lastRequestJSONBody() -> [String: Any]? {
        guard !requestBody.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestBody = Self.bodyData(from: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension TelegramUser {
    static func fixture(id: Int64, isBot: Bool) -> TelegramUser {
        TelegramUser(
            id: id,
            isBot: isBot,
            firstName: isBot ? "Bot" : "Mika",
            lastName: nil,
            username: isBot ? "bot" : "mika"
        )
    }
}

private extension TelegramUpdate {
    static func fixture(
        updateId: Int64,
        messageId: Int,
        chatId: Int64,
        text: String,
        from: TelegramUser = .fixture(id: 7, isBot: false),
        chatUsername: String? = nil
    ) -> TelegramUpdate {
        TelegramUpdate(
            updateId: updateId,
            message: .fixture(
                messageId: messageId,
                chatId: chatId,
                text: text,
                from: from,
                chatUsername: chatUsername
            ),
            editedMessage: nil,
            channelPost: nil,
            editedChannelPost: nil
        )
    }
}

private extension TelegramMessage {
    static func fixture(
        messageId: Int,
        chatId: Int64,
        text: String,
        from: TelegramUser?,
        replyToMessageId: Int? = nil,
        chatUsername: String? = nil
    ) -> TelegramMessage {
        TelegramMessage(
            messageId: messageId,
            date: 1_782_427_200,
            chat: TelegramChat(
                id: chatId,
                type: "group",
                title: "Ops",
                username: chatUsername,
                firstName: nil,
                lastName: nil
            ),
            from: from,
            senderChat: nil,
            text: text,
            caption: nil,
            replyToMessage: replyToMessageId.map { TelegramMessageReference(messageId: $0) }
        )
    }
}
