//
//  SlackConnectionTests.swift
//  osaurusTests
//
//  Unit and security coverage for the native Slack Agent Channel adapter.
//

import Foundation
import CryptoKit
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SlackConnectionTests {

    @Test func configurationPersistsAllowlistsButNeverSecrets() async throws {
        try await withIsolatedSlackStores { credentials in
            let botToken = "xoxb-slack-bot-token-super-secret"
            let signingSecret = "slack-signing-secret-super-secret"
            let appToken = "xapp-slack-app-token-super-secret"
            let service = SlackConnectionService(client: FakeSlackAPIClient(), credentialStore: credentials)
            try service.saveBotToken(botToken)
            try service.saveSigningSecret(signingSecret)
            try service.saveAppToken(appToken)
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: [" T12345 ", "T12345"],
                    readableChannelIds: ["C23456"],
                    writableChannelIds: ["C34567"],
                    senderAllowlist: [" U55555 ", "U55555"],
                    writeEnabled: true,
                    defaultReadLimit: 250
                )
            )

            let saved = SlackConnectionConfigurationStore.load()
            #expect(saved.configuredTeamIds == ["T12345"])
            #expect(saved.senderAllowlist == ["U55555"])
            #expect(saved.defaultReadLimit == 100)
            #expect(!SlackConnectionConfiguration.isValidSlackId("T١٢٣"))

            let disk = try String(
                contentsOf: SlackConnectionConfigurationStore.configurationFileURL(),
                encoding: .utf8
            )
            #expect(disk.contains("C23456"))
            #expect(!disk.contains(botToken))
            #expect(!disk.contains(signingSecret))
            #expect(!disk.contains(appToken))
            #expect(!disk.localizedCaseInsensitiveContains("bot_token"))
            #expect(!disk.localizedCaseInsensitiveContains("signing_secret"))
            #expect(!disk.localizedCaseInsensitiveContains("app_token"))
        }
    }

    @Test func diagnosticsRedactsSavedSecretsEchoedByTransportError() async throws {
        try await withIsolatedSlackStores { credentials in
            let botToken = "xoxb-slack-bot-token-super-secret"
            let signingSecret = "slack-signing-secret-super-secret"
            let appToken = "xapp-slack-app-token-super-secret"
            let fake = FakeSlackAPIClient()
            await fake.setAuthFailureEchoingSecrets(
                botToken: botToken,
                signingSecret: signingSecret,
                appToken: appToken
            )
            let service = SlackConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken(botToken)
            try service.saveSigningSecret(signingSecret)
            try service.saveAppToken(appToken)

            let diagnostics = await service.diagnostics()

            #expect(diagnostics.botTokenSaved)
            #expect(diagnostics.signingSecretSaved)
            #expect(diagnostics.appTokenSaved)
            #expect(diagnostics.status == "token_invalid_or_unavailable")
            let failures = diagnostics.failures.joined(separator: " ")
            #expect(failures.contains("[REDACTED:SLACK_BOT_TOKEN]"))
            #expect(failures.contains("[REDACTED:SLACK_SIGNING_SECRET]"))
            #expect(failures.contains("[REDACTED:SLACK_APP_TOKEN]"))
            #expect(!failures.contains(botToken))
            #expect(!failures.contains(signingSecret))
            #expect(!failures.contains(appToken))
            #expect(!String(describing: diagnostics.dictionary).contains(botToken))
            #expect(!String(describing: diagnostics.dictionary).contains(signingSecret))
            #expect(!String(describing: diagnostics.dictionary).contains(appToken))
        }
    }

    @Test func diagnosticsPersistsBotIdentityForInboundSelfFiltering() async throws {
        try await withIsolatedSlackStores { credentials in
            let service = SlackConnectionService(client: FakeSlackAPIClient(), credentialStore: credentials)
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(readableChannelIds: ["C23456"])
            )

            let diagnostics = await service.diagnostics()
            let saved = SlackConnectionConfigurationStore.load()

            #expect(diagnostics.identity?.userId == "U12345")
            #expect(diagnostics.identity?.botId == "B12345")
            #expect(saved.botUserId == "U12345")
            #expect(saved.botId == "B12345")
        }
    }

    @Test func saveConfigurationPreservesPersistedBotIdentity() async throws {
        try await withIsolatedSlackStores { credentials in
            let service = SlackConnectionService(client: FakeSlackAPIClient(), credentialStore: credentials)
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "AOSABOT"
                )
            )

            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"]
                )
            )

            let saved = SlackConnectionConfigurationStore.load()
            #expect(saved.botUserId == "UOSABOT")
            #expect(saved.botId == "BOSABOT")
            #expect(saved.apiAppId == "AOSABOT")
        }
    }

    @Test func diagnosticsWarnWhenReceiveCredentialsHaveNoSenderAllowlist() async throws {
        try await withIsolatedSlackStores { credentials in
            let service = SlackConnectionService(client: FakeSlackAPIClient(), credentialStore: credentials)
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveAppToken("xapp-slack-app-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(readableChannelIds: ["C23456"])
            )

            let diagnostics = await service.diagnostics()

            #expect(diagnostics.status == "connected_receive_needs_sender_allowlist")
            #expect(diagnostics.failures.contains {
                $0.localizedCaseInsensitiveContains("no authorized sender IDs")
            })
        }
    }

    @Test func signatureVerifierAuthorizesSlackSignedRequestOnlyWithinTolerance() throws {
        let signingSecret = "8f742231b10e8888abcd99yyyzzz85a5"
        let timestamp = "1531420618"
        let body = Data(
            """
            token=xyzz0WbapA4vBCDEFasx0Fqz&team_id=T1DC2J9E1&team_domain=testteamnow&channel_id=C2147483705&channel_name=test&user_id=U2147483697&user_name=Steve&command=/weather&text=94070&response_url=https://hooks.slack.com/commands/1234/5678&trigger_id=13345224609.738474920.8088930838d88f008e0
            """.utf8
        )
        let signature = "v0=4d19b371acb8c24626ae294d086e5dc1513e8e0c04781438c439143315cb807e"

        #expect(SlackSignatureVerifier.isAuthorized(
            signingSecret: signingSecret,
            timestamp: timestamp,
            body: body,
            signature: signature,
            now: Date(timeIntervalSince1970: 1_531_420_618)
        ))
        #expect(!SlackSignatureVerifier.isAuthorized(
            signingSecret: signingSecret,
            timestamp: timestamp,
            body: body,
            signature: signature,
            now: Date(timeIntervalSince1970: 1_531_421_000)
        ))
        #expect(!SlackSignatureVerifier.isAuthorized(
            signingSecret: signingSecret,
            timestamp: timestamp,
            body: Data("tampered".utf8),
            signature: signature,
            now: Date(timeIntervalSince1970: 1_531_420_618)
        ))
    }

    @Test func apiClientRedactsTokenEchoedBySlackErrorBody() async throws {
        let token = "xoxb-slack-bot-token-super-secret"
        let session = SlackHTTPStubProtocol.session(
            statusCode: 200,
            body: #"{"ok":false,"error":"invalid_auth \#(token)"}"#
        )
        let client = SlackAPIClient(
            baseURL: URL(string: "https://slack.test/api")!,
            sessionProvider: { session }
        )

        do {
            _ = try await client.authTest(token: token)
            Issue.record("Slack request should have failed")
        } catch let error as SlackAPIError {
            #expect(error.localizedDescription.contains("[REDACTED:SLACK_BOT_TOKEN]"))
            #expect(!error.localizedDescription.contains(token))
        }
    }

    @Test func apiClientUsesConservativeMentionControlsWhenSendingMessage() async throws {
        let token = "xoxb-slack-bot-token-super-secret"
        let session = SlackHTTPStubProtocol.session(
            statusCode: 200,
            body: """
            {
              "ok": true,
              "channel": "C34567",
              "ts": "1718800000.000100",
              "message": {
                "type": "message",
                "user": "U12345",
                "text": "Hello @channel <@U23456>",
                "ts": "1718800000.000100"
              }
            }
            """
        )
        let client = SlackAPIClient(
            baseURL: URL(string: "https://slack.test/api")!,
            sessionProvider: { session }
        )

        _ = try await client.sendMessage(
            SlackOutboundMessageRequest(
                channelId: "C34567",
                content: "Hello @channel <@U23456>",
                threadTs: nil
            ),
            token: token
        )

        let body = try #require(SlackHTTPStubProtocol.lastRequestJSONBody())
        #expect(body["parse"] as? String == "none")
        #expect(body["link_names"] as? Bool == false)
        #expect(body["reply_broadcast"] as? Bool == false)
        #expect(body["unfurl_links"] as? Bool == false)
        #expect(body["unfurl_media"] as? Bool == false)
    }

    @Test func apiClientHonorsBoundedConversationListLimit() async throws {
        let token = "xoxb-slack-bot-token-super-secret"
        let session = SlackHTTPStubProtocol.session(
            statusCode: 200,
            body: #"{"ok":true,"channels":[]}"#
        )
        let client = SlackAPIClient(
            baseURL: URL(string: "https://slack.test/api")!,
            sessionProvider: { session }
        )

        _ = try await client.conversations(token: token, limit: 10, cursor: nil)

        let form = SlackHTTPStubProtocol.lastRequestFormBody()
        #expect(form["limit"] == "10")
        #expect(form["exclude_archived"] == "true")
        #expect(SlackHTTPStubProtocol.lastRawRequestBody()
            .contains("types=public_channel%2Cprivate_channel%2Cmpim%2Cim"))
    }

    @Test func apiClientMapsSlackRateLimitWithRetryAfterHint() async throws {
        let token = "xoxb-slack-bot-token-super-secret"
        let session = SlackHTTPStubProtocol.session(
            statusCode: 429,
            body: #"{"ok":false,"error":"ratelimited"}"#,
            headers: ["Retry-After": "7"]
        )
        let client = SlackAPIClient(
            baseURL: URL(string: "https://slack.test/api")!,
            sessionProvider: { session }
        )

        do {
            _ = try await client.messages(channelId: "C23456", token: token, limit: 1, cursor: nil)
            Issue.record("Slack request should have been rate limited")
        } catch let error as SlackAPIError {
            #expect(error == .rateLimited(
                "Slack rate limited this request. Retry after 7 seconds.",
                retryAfter: 7
            ))
        }
    }

    @Test func readChannelReturnsBoundedMessagesForAllowlistedSlackChannel() async throws {
        try await withIsolatedSlackStores { credentials in
            let fake = FakeSlackAPIClient()
            await fake.setMessages([
                "C23456": [
                    .fixture(ts: "1718800000.000100", text: "eval reports landed"),
                    .fixture(ts: "1718800001.000200", text: "review requested"),
                ],
            ])
            let service = SlackConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    defaultReadLimit: 2
                )
            )

            let result = try await service.readChannel(channelId: "C23456", limit: nil)
            #expect(result["channel_id"] as? String == "C23456")
            #expect(result["partial"] as? Bool == false)
            #expect(result["next_cursor"] == nil)
            let messages = try #require(result["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(messages.first?["content"] as? String == "eval reports landed")
            #expect(messages.first?["thread_id"] as? String == "C23456:1718800000.000100")
        }
    }

    @Test func readChannelFollowsCursorsToFillRequestedLimit() async throws {
        try await withIsolatedSlackStores { credentials in
            let fake = FakeSlackAPIClient()
            await fake.setMessagePages(
                [
                    SlackMessagePage(messages: [
                        .fixture(ts: "1718800003.000400", text: "newest"),
                        .fixture(ts: "1718800002.000300", text: "newer"),
                    ]),
                    SlackMessagePage(messages: [
                        .fixture(ts: "1718800001.000200", text: "older"),
                        .fixture(ts: "1718800000.000100", text: "oldest"),
                    ]),
                ],
                channelId: "C23456"
            )
            let service = SlackConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"]
                )
            )

            let result = try await service.readChannel(channelId: "C23456", limit: 4)

            let messages = try #require(result["messages"] as? [[String: Any]])
            #expect(messages.count == 4)
            #expect(messages.first?["content"] as? String == "newest")
            #expect(messages.last?["content"] as? String == "oldest")
            #expect(result["partial"] as? Bool == false)
            #expect(result["next_cursor"] == nil)
            #expect(await fake.messageCursorsRequested() == [nil, "cursor-1"])
        }
    }

    @Test func readChannelExposesContinuationCursorWhenMoreHistoryRemains() async throws {
        try await withIsolatedSlackStores { credentials in
            let fake = FakeSlackAPIClient()
            await fake.setMessagePages(
                [
                    SlackMessagePage(messages: [
                        .fixture(ts: "1718800003.000400", text: "newest"),
                        .fixture(ts: "1718800002.000300", text: "newer"),
                    ]),
                    SlackMessagePage(messages: [
                        .fixture(ts: "1718800001.000200", text: "older"),
                    ]),
                ],
                channelId: "C23456"
            )
            let service = SlackConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"]
                )
            )

            let result = try await service.readChannel(channelId: "C23456", limit: 2)

            let messages = try #require(result["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(result["partial"] as? Bool == true)
            #expect(result["next_cursor"] as? String == "cursor-1")
            #expect(await fake.messageCursorsRequested() == [nil])
        }
    }

    @Test func listChannelsFollowsConversationCursorsAcrossPages() async throws {
        try await withIsolatedSlackStores { credentials in
            let fake = FakeSlackAPIClient()
            await fake.setConversationPages([
                [SlackConversation(id: "C11111", name: "one", isChannel: true, isMember: true)],
                [SlackConversation(id: "C22222", name: "two", isChannel: true, isMember: true)],
            ])
            let service = SlackConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C11111"]
                )
            )

            let rows = try await service.listChannels(teamId: "T12345")

            #expect(rows.count == 2)
            #expect(rows.compactMap { $0["id"] as? String } == ["C11111", "C22222"])
            #expect(await fake.conversationCursorsRequested() == [nil, "cursor-1"])
        }
    }

    @Test func apiClientSendsCursorAndParsesNextCursor() async throws {
        let token = "xoxb-slack-bot-token-super-secret"
        let session = SlackHTTPStubProtocol.session(
            statusCode: 200,
            body: #"{"ok":true,"messages":[],"has_more":true,"response_metadata":{"next_cursor":"bmV4dDoxMjM="}}"#
        )
        let client = SlackAPIClient(
            baseURL: URL(string: "https://slack.test/api")!,
            sessionProvider: { session }
        )

        let page = try await client.messages(channelId: "C23456", token: token, limit: 5, cursor: "abc123")

        let form = SlackHTTPStubProtocol.lastRequestFormBody()
        #expect(form["cursor"] == "abc123")
        #expect(page.nextCursor == "bmV4dDoxMjM=")
        #expect(page.hasMore)
    }

    @Test func apiClientNormalizesEmptyNextCursorToNil() async throws {
        let token = "xoxb-slack-bot-token-super-secret"
        let session = SlackHTTPStubProtocol.session(
            statusCode: 200,
            body: #"{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}"#
        )
        let client = SlackAPIClient(
            baseURL: URL(string: "https://slack.test/api")!,
            sessionProvider: { session }
        )

        let page = try await client.conversations(token: token, limit: 10, cursor: nil)

        let form = SlackHTTPStubProtocol.lastRequestFormBody()
        #expect(form["cursor"] == nil)
        #expect(page.nextCursor == nil)
        #expect(page.conversations.isEmpty)
    }

    @Test func readAndSendRecordSlackMessagesInAgentChannelStore() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeSlackAPIClient()
            await fake.setMessages([
                "C23456": [
                    .fixture(ts: "1718800000.000100", text: "eval reports landed"),
                    .fixture(ts: "1718800001.000200", text: "review requested"),
                ],
            ])
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    writableChannelIds: ["C23456"],
                    writeEnabled: true,
                    defaultReadLimit: 2
                )
            )

            _ = try await service.readChannel(channelId: "C23456", limit: nil)
            _ = try await service.readChannel(channelId: "C23456", limit: nil)
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 2)

            _ = try await service.sendMessage(
                channelId: "C23456",
                content: "Ship it",
                confirmSend: true
            )
            let rows = try store.recentMessages(connectionId: "slack", roomId: "C23456", limit: 10)
            #expect(rows.contains { $0.providerMessageId == "1718800001.000100" && $0.direction == .outbound })
            #expect(rows.allSatisfy { !$0.payloadJSON.localizedCaseInsensitiveContains("xoxb-slack") })
        }
    }

    @Test func slackInboundEventNormalizationCapturesMentionThreadAndStoreDedupe() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = SlackConnectionService(
                client: FakeSlackAPIClient(),
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT"
                )
            )
            let envelope = SlackEventEnvelope(
                token: "legacy-verification-secret",
                teamId: "T12345",
                apiAppId: "A12345",
                event: SlackEventMessage(
                    type: "app_mention",
                    subtype: nil,
                    channel: "C23456",
                    user: "U55555",
                    botId: nil,
                    text: "<@UOSABOT> can you check this?",
                    ts: "1718800001.000200",
                    threadTs: "1718800000.000100",
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "Ev12345",
                eventTime: 1_718_800_001
            )

            let normalized = try #require(try service.recordInboundEvent(envelope))
            #expect(normalized.providerEventId == "Ev12345")
            #expect(normalized.roomId == "C23456")
            #expect(normalized.threadId == "C23456:1718800000.000100")
            #expect(normalized.isThreadReply)
            #expect(normalized.isMention)
            #expect(normalized.mentionedUserIds == ["UOSABOT"])
            #expect(!normalized.payloadJSON.contains("legacy-verification-secret"))
            #expect(try service.recordInboundEvent(envelope) == nil)
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 1)
        }
    }

    @Test func slackInboundEventRequiresSignedBodyForWebhookEntryPoint() async throws {
        try await withIsolatedSlackStores { credentials in
            let signingSecret = "slack-signing-secret-super-secret"
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = SlackConnectionService(
                client: FakeSlackAPIClient(),
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveSigningSecret(signingSecret)
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT"
                )
            )
            let envelope = SlackEventEnvelope(
                token: "legacy-verification-secret",
                teamId: "T12345",
                apiAppId: "A12345",
                event: SlackEventMessage(
                    type: "app_mention",
                    subtype: nil,
                    channel: "C23456",
                    user: "U55555",
                    botId: nil,
                    text: "<@UOSABOT> signed event",
                    ts: "1718800001.000200",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvSigned12345",
                eventTime: 1_718_800_001
            )
            let body = try JSONEncoder().encode(envelope)
            let timestamp = "1718800001"
            let signature = slackSignature(secret: signingSecret, timestamp: timestamp, body: body)

            let normalized = try #require(try service.recordVerifiedInboundEvent(
                body: body,
                timestamp: timestamp,
                signature: signature,
                now: Date(timeIntervalSince1970: 1_718_800_001)
            ))

            #expect(normalized.providerEventId == "EvSigned12345")
            #expect(!normalized.payloadJSON.contains("legacy-verification-secret"))
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 1)

            do {
                _ = try service.recordVerifiedInboundEvent(
                    body: body,
                    timestamp: timestamp,
                    signature: "v0=bad",
                    now: Date(timeIntervalSince1970: 1_718_800_001)
                )
                Issue.record("Slack webhook entry should reject invalid signatures")
            } catch let error as SlackConnectionServiceError {
                #expect(error == .signatureVerificationFailed)
            }
        }
    }

    @Test func signedSlackInboundEventRequiresReadableChannelAllowlistBeforeStorage() async throws {
        try await withIsolatedSlackStores { credentials in
            let signingSecret = "slack-signing-secret-super-secret"
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = SlackConnectionService(
                client: FakeSlackAPIClient(),
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveSigningSecret(signingSecret)
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C99999"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT"
                )
            )
            let envelope = SlackEventEnvelope(
                token: nil,
                teamId: "T12345",
                apiAppId: "A12345",
                event: SlackEventMessage(
                    type: "app_mention",
                    subtype: nil,
                    channel: "C23456",
                    user: "U55555",
                    botId: nil,
                    text: "<@UOSABOT> signed but not allowlisted",
                    ts: "1718800001.000300",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvSignedDenied12345",
                eventTime: 1_718_800_001
            )
            let body = try JSONEncoder().encode(envelope)
            let timestamp = "1718800001"
            let signature = slackSignature(secret: signingSecret, timestamp: timestamp, body: body)

            let normalized = try service.recordVerifiedInboundEvent(
                body: body,
                timestamp: timestamp,
                signature: signature,
                now: Date(timeIntervalSince1970: 1_718_800_001)
            )

            #expect(normalized == nil)
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 0)
        }
    }

    @Test func slackInboundEventRequiresSenderAllowlistBeforeStorage() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = SlackConnectionService(
                client: FakeSlackAPIClient(),
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["UAUTHORIZED"],
                    botUserId: "UOSABOT"
                )
            )
            let envelope = SlackEventEnvelope(
                token: nil,
                teamId: "T12345",
                apiAppId: "A12345",
                event: SlackEventMessage(
                    type: "app_mention",
                    subtype: nil,
                    channel: "C23456",
                    user: "U55555",
                    botId: nil,
                    text: "<@UOSABOT> should not dispatch",
                    ts: "1718800001.000400",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvSenderDenied12345",
                eventTime: 1_718_800_001
            )

            #expect(try service.recordInboundEvent(envelope) == nil)
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 0)
            let audits = try store.recentAuditEvents(connectionId: "slack", roomId: "C23456", limit: 10)
            let denied = try #require(audits.first)
            #expect(denied.authorizationDecision == "deny")
            #expect(denied.reason == "sender_not_allowlisted")
        }
    }

    @Test func slackInboundEventMentionAndSelfMessagePolicyAvoidsOverTriggering() async throws {
        try await withIsolatedSlackStores { credentials in
            let service = SlackConnectionService(client: FakeSlackAPIClient(), credentialStore: credentials)
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "AOSABOT"
                )
            )

            let thirdPartyMention = SlackEventEnvelope(
                token: nil,
                teamId: "T12345",
                apiAppId: "A12345",
                event: SlackEventMessage(
                    type: "message",
                    subtype: nil,
                    channel: "C23456",
                    user: "U55555",
                    botId: nil,
                    text: "cc <@UOTHER|teammate>",
                    ts: "1718800002.000200",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvOtherMention",
                eventTime: 1_718_800_002
            )
            let normalized = try #require(service.normalizeInboundEvent(thirdPartyMention))
            #expect(normalized.mentionedUserIds == ["UOTHER"])
            #expect(!normalized.isMention)

            let ownBotDirectMessage = SlackEventEnvelope(
                token: nil,
                teamId: "T12345",
                apiAppId: "AOSABOT",
                event: SlackEventMessage(
                    type: "message",
                    subtype: nil,
                    channel: "C23456",
                    user: nil,
                    botId: "BOSABOT",
                    text: "self echo without subtype",
                    ts: "1718800003.000100",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvSelfBotDirect",
                eventTime: 1_718_800_003
            )
            #expect(service.normalizeInboundEvent(ownBotDirectMessage) == nil)

            let ownBotMessage = SlackEventEnvelope(
                token: nil,
                teamId: "T12345",
                apiAppId: "AOSABOT",
                event: SlackEventMessage(
                    type: "message",
                    subtype: "bot_message",
                    channel: "C23456",
                    user: nil,
                    botId: "BOSABOT",
                    text: "self echo",
                    ts: "1718800003.000200",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvSelfBot",
                eventTime: 1_718_800_003
            )
            #expect(service.normalizeInboundEvent(ownBotMessage) == nil)
        }
    }

    @Test func slackInboundEventRejectsUnconfiguredTeamAndMissingBotIdentity() async throws {
        try await withIsolatedSlackStores { credentials in
            let service = SlackConnectionService(client: FakeSlackAPIClient(), credentialStore: credentials)
            let envelope = SlackEventEnvelope(
                token: nil,
                teamId: "TOTHER",
                apiAppId: "A12345",
                event: SlackEventMessage(
                    type: "app_mention",
                    subtype: nil,
                    channel: "C23456",
                    user: "U55555",
                    botId: nil,
                    text: "<@UOSABOT> hello",
                    ts: "1718800003.000400",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvWrongTeam",
                eventTime: 1_718_800_003
            )

            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT"
                )
            )
            #expect(service.normalizeInboundEvent(envelope) == nil)

            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["TOTHER"],
                    readableChannelIds: ["C23456"]
                )
            )
            #expect(service.normalizeInboundEvent(envelope) == nil)
        }
    }

    @Test func slackInboundEventDedupesMessageAndAppMentionForSameSlackMessage() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = SlackConnectionService(
                client: FakeSlackAPIClient(),
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT"
                )
            )
            let appMention = SlackEventEnvelope(
                token: nil,
                teamId: "T12345",
                apiAppId: "A12345",
                event: SlackEventMessage(
                    type: "app_mention",
                    subtype: nil,
                    channel: "C23456",
                    user: "U55555",
                    botId: nil,
                    text: "<@UOSABOT> same message",
                    ts: "1718800004.000200",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvAppMention",
                eventTime: 1_718_800_004
            )
            let messageEcho = SlackEventEnvelope(
                token: nil,
                teamId: "T12345",
                apiAppId: "A12345",
                event: SlackEventMessage(
                    type: "message",
                    subtype: nil,
                    channel: "C23456",
                    user: "U55555",
                    botId: nil,
                    text: "<@UOSABOT> same message",
                    ts: "1718800004.000200",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvMessageEcho",
                eventTime: 1_718_800_004
            )

            #expect(try service.recordInboundEvent(appMention) != nil)
            #expect(try service.recordInboundEvent(messageEcho) == nil)
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 1)
        }
    }

    @Test func socketModeRuntimeAcksAuthorizedEnvelopeAndStoresMessage() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeSlackAPIClient()
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveAppToken("xapp-slack-app-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "A12345"
                )
            )
            let socket = FakeSlackSocketModeWebSocket(messages: [
                Self.socketModeEnvelope(
                    envelopeId: "env-1",
                    eventId: "EvSOCKET1",
                    userId: "U55555",
                    text: "<@UOSABOT> eval report ready"
                ),
            ])
            let runtime = SlackSocketModeTransportRuntime(
                service: service,
                client: fake,
                webSocketFactory: FakeSlackSocketModeWebSocketFactory(socket: socket)
            )

            let result = await runtime.runStep(maxMessages: 1)

            #expect(result.disposition == .succeeded)
            #expect(result.received == 1)
            #expect(result.stored == 1)
            #expect(await fake.lastOpenedAppToken() == "xapp-slack-app-token-super-secret")
            #expect(await socket.sentTexts().contains(#"{"envelope_id":"env-1"}"#))
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 1)
        }
    }

    @Test func socketModeRuntimePersistsMissingBotIdentityBeforeReceiving() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeSlackAPIClient()
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveAppToken("xapp-slack-app-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"]
                )
            )
            let socket = FakeSlackSocketModeWebSocket(messages: [
                Self.socketModeEnvelope(
                    envelopeId: "env-identity",
                    eventId: "EvSOCKETIDENTITY",
                    userId: "U55555",
                    text: "<@U12345> first setup event"
                ),
            ])
            let runtime = SlackSocketModeTransportRuntime(
                service: service,
                client: fake,
                webSocketFactory: FakeSlackSocketModeWebSocketFactory(socket: socket)
            )

            let result = await runtime.runStep(maxMessages: 1)

            #expect(result.disposition == .succeeded)
            #expect(result.stored == 1)
            let saved = SlackConnectionConfigurationStore.load()
            #expect(saved.botUserId == "U12345")
            #expect(saved.botId == "B12345")
            #expect(await fake.lastOpenedAppToken() == "xapp-slack-app-token-super-secret")
            #expect(await socket.sentTexts().contains(#"{"envelope_id":"env-identity"}"#))
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 1)
        }
    }

    @Test func socketModeRuntimeStoresEnvelopeBeforeSendingAck() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeSlackAPIClient()
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveAppToken("xapp-slack-app-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "A12345"
                )
            )
            struct AckDeliveryFailure: Error {}
            let socket = FakeSlackSocketModeWebSocket(
                messages: [
                    Self.socketModeEnvelope(
                        envelopeId: "env-ack-order",
                        eventId: "EvACKORDER",
                        userId: "U55555",
                        text: "<@UOSABOT> stored before ack"
                    ),
                ],
                sendError: AckDeliveryFailure()
            )
            let runtime = SlackSocketModeTransportRuntime(
                service: service,
                client: fake,
                webSocketFactory: FakeSlackSocketModeWebSocketFactory(socket: socket)
            )

            let result = await runtime.runStep(maxMessages: 1, jitter: 0.5)

            // The envelope must be persisted before the ack is attempted: an ack
            // delivery failure surfaces as a failed step (Slack will redeliver and
            // event-id dedupe absorbs the retry), but the message is already stored.
            #expect(result.disposition == .failed)
            #expect(await socket.sentTexts().isEmpty)
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 1)
        }
    }

    @Test func socketModeRuntimeTreatsRefreshRequestedDisconnectAsCleanReconnect() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeSlackAPIClient()
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveAppToken("xapp-slack-app-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "A12345"
                )
            )
            let socket = FakeSlackSocketModeWebSocket(messages: [
                #"{"type":"disconnect","reason":"refresh_requested"}"#,
            ])
            let runtime = SlackSocketModeTransportRuntime(
                service: service,
                client: fake,
                webSocketFactory: FakeSlackSocketModeWebSocketFactory(socket: socket)
            )

            let refresh = await runtime.runStep(jitter: 0.5)

            // A planned refresh is routine operation, not a failure.
            #expect(refresh.disposition == .succeeded)
            #expect(refresh.health.status == .healthy)
            #expect(refresh.health.severity == .info)
            #expect(refresh.health.consecutiveFailures == 0)
            #expect(refresh.retryDelay == 1)
            #expect(refresh.health.summary.localizedCaseInsensitiveContains("refresh"))

            // And it must not carry a failure penalty into the next step:
            // the first real failure after a refresh gets first-failure backoff.
            struct SocketOpenFailure: Error {}
            await fake.failSocketOpen(SocketOpenFailure())
            let failure = await runtime.runStep(jitter: 0.5)
            #expect(failure.disposition == .failed)
            #expect(failure.health.consecutiveFailures == 1)
            #expect(failure.retryDelay == 1)
        }
    }

    @Test func socketModeRuntimeStillFailsOnUnplannedDisconnectReasons() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeSlackAPIClient()
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveAppToken("xapp-slack-app-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "A12345"
                )
            )
            let socket = FakeSlackSocketModeWebSocket(messages: [
                #"{"type":"disconnect","reason":"link_disabled"}"#,
            ])
            let runtime = SlackSocketModeTransportRuntime(
                service: service,
                client: fake,
                webSocketFactory: FakeSlackSocketModeWebSocketFactory(socket: socket)
            )

            let result = await runtime.runStep(jitter: 0.5)

            #expect(result.disposition == .failed)
            #expect(result.health.status == .failed)
            #expect(result.health.consecutiveFailures == 1)
        }
    }

    @Test func socketModeRuntimeHonorsSlackRetryAfterOnRateLimit() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeSlackAPIClient()
            await fake.failSocketOpen(
                SlackAPIError.rateLimited(
                    "Slack rate limited this request. Retry after 45 seconds.",
                    retryAfter: 45
                )
            )
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveAppToken("xapp-slack-app-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "A12345"
                )
            )
            let runtime = SlackSocketModeTransportRuntime(
                service: service,
                client: fake,
                webSocketFactory: FakeSlackSocketModeWebSocketFactory(
                    socket: FakeSlackSocketModeWebSocket(messages: [])
                )
            )

            let now = Date(timeIntervalSince1970: 1_800_002_000)
            let result = await runtime.runStep(now: now, jitter: 0.5)

            // First-failure backoff would be ~1s; Slack asked for 45s.
            #expect(result.disposition == .failed)
            #expect(result.retryDelay == 45)
            #expect(result.health.status == .degraded)
            #expect(result.health.severity == .warning)
            #expect(result.health.nextRetryAt == now.addingTimeInterval(45))
        }
    }

    @Test func socketModeRuntimeRedactsSecretsInFailureHealthDetail() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let botToken = "xoxb-slack-bot-token-super-secret"
            let appToken = "xapp-slack-app-token-super-secret"
            let fake = FakeSlackAPIClient()
            await fake.failSocketOpen(
                SlackAPIError.requestFailed("transport echoed \(botToken) and \(appToken)")
            )
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveBotToken(botToken)
            try service.saveAppToken(appToken)
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "A12345"
                )
            )
            let runtime = SlackSocketModeTransportRuntime(
                service: service,
                client: fake,
                webSocketFactory: FakeSlackSocketModeWebSocketFactory(
                    socket: FakeSlackSocketModeWebSocket(messages: [])
                )
            )

            let result = await runtime.runStep(jitter: 0.5)

            #expect(result.disposition == .failed)
            let detail = try #require(result.health.detail)
            #expect(detail.contains("[REDACTED:SLACK_BOT_TOKEN]"))
            #expect(detail.contains("[REDACTED:SLACK_APP_TOKEN]"))
            #expect(!detail.contains(botToken))
            #expect(!detail.contains(appToken))
        }
    }

    @Test func socketModeRunLoopBacksOffAcrossFailuresAndRecovers() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            struct SocketOpenFailure: Error {}
            let fake = FakeSlackAPIClient()
            await fake.failSocketOpen(SocketOpenFailure())
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveAppToken("xapp-slack-app-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "A12345"
                )
            )
            let sleeper = RecordingTransportSleeper()
            let runtime = SlackSocketModeTransportRuntime(
                service: service,
                client: fake,
                webSocketFactory: FakeSlackSocketModeWebSocketFactory(
                    socket: FakeSlackSocketModeWebSocket(messages: [])
                ),
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

            // The loop keeps retrying on its own with exponential backoff.
            let delays = await sleeper.recordedDelays()
            #expect(Array(delays.prefix(3)) == [1, 2, 4])

            // Once Slack accepts connections again the loop recovers without
            // outside intervention and the failure penalty resets.
            await fake.clearSocketOpenFailure()
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

    @Test func socketModeStopCancelsInFlightReceiveAndReturnsPromptly() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeSlackAPIClient()
            let service = SlackConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveAppToken("xapp-slack-app-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT",
                    botId: "BOSABOT",
                    apiAppId: "A12345"
                )
            )
            let socket = HangingSlackSocketModeWebSocket()
            let runtime = SlackSocketModeTransportRuntime(
                service: service,
                client: fake,
                webSocketFactory: AnySlackSocketModeWebSocketFactory(socket: socket),
                healthCenter: AgentChannelTransportHealthCenter(),
                sleeper: RecordingTransportSleeper()
            )

            await runtime.start(pollInterval: 1)
            let receiveParked = await waitForTransportCondition {
                socket.isReceiveInFlight()
            }
            #expect(receiveParked)

            // Stopping while a receive is parked on the socket must cancel the
            // in-flight read instead of waiting for it to complete.
            await runtime.stop()

            #expect(socket.wasCancelled())
            let health = await runtime.health()
            #expect(health.status == .idle)
            #expect(health.isRunning == false)
        }
    }

    @Test func transportSupervisorStopsSlackRuntimeWhenBotTokenIsRemoved() async {
        let runtime = SlackReceiveTransportRuntimeSpy()
        let hasBotToken = SlackTokenPresenceBox(true)
        let supervisor = AgentChannelTransportSupervisor(
            slackConfiguration: {
                SlackConnectionConfiguration(
                    readableChannelIds: ["C12345"],
                    senderAllowlist: ["U12345"]
                )
            },
            slackHasBotToken: { hasBotToken.value() },
            slackHasAppToken: { true },
            slackRuntime: runtime,
            telegramConfiguration: { TelegramConnectionConfiguration() },
            telegramHasBotToken: { false },
            telegramRuntime: SlackReceiveTransportRuntimeSpy()
        )
        let stopDate = Date(timeIntervalSince1970: 1_800_001_000)

        await supervisor.startFromLaunch()
        hasBotToken.set(false)
        await supervisor.refreshSlackRuntime(now: stopDate)

        #expect(await runtime.startCount() == 1)
        #expect(await runtime.stopCount() == 1)
        #expect(await runtime.lastStopDate() == stopDate)
    }

    @Test func transportSupervisorStopsSlackRuntimeWhenAppTokenIsRemoved() async {
        let runtime = SlackReceiveTransportRuntimeSpy()
        let hasAppToken = SlackTokenPresenceBox(true)
        let supervisor = AgentChannelTransportSupervisor(
            slackConfiguration: {
                SlackConnectionConfiguration(
                    readableChannelIds: ["C12345"],
                    senderAllowlist: ["U12345"]
                )
            },
            slackHasBotToken: { true },
            slackHasAppToken: { hasAppToken.value() },
            slackRuntime: runtime,
            telegramConfiguration: { TelegramConnectionConfiguration() },
            telegramHasBotToken: { false },
            telegramRuntime: SlackReceiveTransportRuntimeSpy()
        )
        let stopDate = Date(timeIntervalSince1970: 1_800_001_200)

        await supervisor.startFromLaunch()
        hasAppToken.set(false)
        await supervisor.refreshSlackRuntime(now: stopDate)

        #expect(await runtime.startCount() == 1)
        #expect(await runtime.stopCount() == 1)
        #expect(await runtime.lastStopDate() == stopDate)
    }

    @Test func slackInboundDispatchSurvivesPassiveSnapshotCollision() async throws {
        try await withIsolatedSlackStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let service = SlackConnectionService(
                client: FakeSlackAPIClient(),
                credentialStore: credentials,
                messageStore: store
            )
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    senderAllowlist: ["U55555"],
                    botUserId: "UOSABOT"
                )
            )
            _ = try store.recordMessages([
                AgentChannelStoredMessage(
                    connectionId: "slack",
                    roomId: "C23456",
                    providerMessageId: "1718800005.000200",
                    direction: .inbound,
                    threadId: "C23456:1718800005.000200",
                    authorId: "U55555",
                    authorName: "Mika",
                    content: "<@UOSABOT> cached before event",
                    providerTimestamp: "1718800005.000200"
                ),
            ])
            let envelope = SlackEventEnvelope(
                token: nil,
                teamId: "T12345",
                apiAppId: "A12345",
                event: SlackEventMessage(
                    type: "app_mention",
                    subtype: nil,
                    channel: "C23456",
                    user: "U55555",
                    botId: nil,
                    text: "<@UOSABOT> cached before event",
                    ts: "1718800005.000200",
                    threadTs: nil,
                    channelType: "channel"
                ),
                type: "event_callback",
                eventId: "EvPassiveCollision",
                eventTime: 1_718_800_005
            )

            #expect(try service.recordInboundEvent(envelope) != nil)
            #expect(try service.recordInboundEvent(envelope) == nil)
            #expect(try store.messageCount(connectionId: "slack", roomId: "C23456") == 1)
        }
    }

    @Test func agentChannelReadToolDispatchesThroughSlackConnection() async throws {
        try await withIsolatedSlackStores { credentials in
            let fake = FakeSlackAPIClient()
            await fake.setMessages([
                "C23456": [.fixture(ts: "1718800000.000100", text: "hello from Slack")],
            ])
            let slackService = SlackConnectionService(client: fake, credentialStore: credentials)
            try slackService.saveBotToken("xoxb-slack-bot-token-super-secret")
            try slackService.saveConfiguration(
                SlackConnectionConfiguration(readableChannelIds: ["C23456"])
            )
            let channelService = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeDiscordAPIClientForSlackTests(),
                    credentialStore: FakeDiscordCredentialStoreForSlackTests()
                ),
                slackService: slackService
            )
            let tool = AgentChannelReadMessagesTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON: #"{"connection_id":"slack","room_id":"C23456"}"#
            )

            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["connection_id"] as? String == "slack")
            #expect(payload["standard_kind"] as? String == "channel_messages")
            #expect(payload["kind"] as? String == "slack_recent_messages")
        }
    }

    @Test func agentChannelReadToolRejectsRoomsOutsideSlackReadAllowlist() async throws {
        try await withIsolatedSlackStores { credentials in
            let slackService = SlackConnectionService(client: FakeSlackAPIClient(), credentialStore: credentials)
            try slackService.saveBotToken("xoxb-slack-bot-token-super-secret")
            try slackService.saveConfiguration(
                SlackConnectionConfiguration(readableChannelIds: ["C23456"])
            )
            let channelService = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeDiscordAPIClientForSlackTests(),
                    credentialStore: FakeDiscordCredentialStoreForSlackTests()
                ),
                slackService: slackService
            )
            let tool = AgentChannelReadMessagesTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON: #"{"connection_id":"slack","room_id":"C99999"}"#
            )
            #expect(EnvelopeAssertions.failureKind(result) == "rejected")
            #expect(EnvelopeAssertions.failureMessage(result)?.contains("not allowlisted") == true)
        }
    }

    @Test func agentChannelSendToolRequiresConfirmSendForSlack() async throws {
        try await withIsolatedSlackStores { credentials in
            let fake = FakeSlackAPIClient()
            let slackService = SlackConnectionService(client: fake, credentialStore: credentials)
            try slackService.saveBotToken("xoxb-slack-bot-token-super-secret")
            try slackService.saveConfiguration(
                SlackConnectionConfiguration(
                    writableChannelIds: ["C34567"],
                    writeEnabled: true
                )
            )
            let channelService = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeDiscordAPIClientForSlackTests(),
                    credentialStore: FakeDiscordCredentialStoreForSlackTests()
                ),
                slackService: slackService
            )
            let tool = AgentChannelSendMessageTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON:
                    #"{"connection_id":"slack","room_id":"C34567","content":"Ship it","confirm_send":false}"#
            )
            #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
            #expect(await fake.sentMessageCount() == 0)
        }
    }

    @Test func agentChannelSendToolPostsOnlyWhenSlackWriteEnabledAllowlistedAndConfirmed() async throws {
        try await withIsolatedSlackStores { credentials in
            let fake = FakeSlackAPIClient()
            let slackService = SlackConnectionService(client: fake, credentialStore: credentials)
            try slackService.saveBotToken("xoxb-slack-bot-token-super-secret")
            try slackService.saveConfiguration(
                SlackConnectionConfiguration(
                    writableChannelIds: ["C34567"],
                    writeEnabled: true
                )
            )
            let channelService = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeDiscordAPIClientForSlackTests(),
                    credentialStore: FakeDiscordCredentialStoreForSlackTests()
                ),
                slackService: slackService
            )
            let tool = AgentChannelSendMessageTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON:
                    #"{"connection_id":"slack","room_id":"C34567","content":"Ship it","confirm_send":true}"#
            )
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["standard_kind"] as? String == "message_sent")
            #expect(payload["kind"] as? String == "slack_message_sent")
            #expect(await fake.sentMessageCount() == 1)
            #expect(await fake.lastSentContent() == "Ship it")
        }
    }

    @Test func slackSendRejectsBroadcastMentionByDefaultBeforeNetworkCall() async throws {
        try await withIsolatedSlackStores { credentials in
            let fake = FakeSlackAPIClient()
            let service = SlackConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    writableChannelIds: ["C34567"],
                    writeEnabled: true
                )
            )

            #expect(throws: SlackConnectionServiceError.broadcastMentionDenied) {
                try service.draftMessage(channelId: "C34567", content: "Heads up <!channel>")
            }
            #expect(throws: SlackConnectionServiceError.broadcastMentionDenied) {
                try service.draftMessage(channelId: "C34567", content: "Heads up <!subteam^S12345|@ops>")
            }
            #expect(await fake.sentMessageCount() == 0)
        }
    }

    @Test func slackThreadReplyUsesChannelAndThreadTimestamp() async throws {
        try await withIsolatedSlackStores { credentials in
            let fake = FakeSlackAPIClient()
            let service = SlackConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("xoxb-slack-bot-token-super-secret")
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    writableChannelIds: ["C34567"],
                    writeEnabled: true
                )
            )

            let result = try await service.replyToThread(
                threadId: "C34567:1718800000.000100",
                content: "Thread reply",
                confirmSend: true
            )

            #expect(result["kind"] as? String == "slack_thread_reply_sent")
            #expect(result["thread_ts"] as? String == "1718800000.000100")
            #expect(await fake.lastThreadTs() == "1718800000.000100")
        }
    }

    @Test func nativeSlackConnectionIsListedAndReserved() async throws {
        try await withIsolatedSlackStores { credentials in
            let slackService = SlackConnectionService(client: FakeSlackAPIClient(), credentialStore: credentials)
            try slackService.saveBotToken("xoxb-slack-bot-token-super-secret")
            try slackService.saveConfiguration(
                SlackConnectionConfiguration(
                    readableChannelIds: ["C23456"],
                    writableChannelIds: ["C34567"],
                    writeEnabled: true
                )
            )
            let channelService = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeDiscordAPIClientForSlackTests(),
                    credentialStore: FakeDiscordCredentialStoreForSlackTests()
                ),
                slackService: slackService
            )

            let slackRow = try #require(
                channelService.listConnections().first { $0["id"] as? String == "slack" }
            )
            #expect(slackRow["kind"] as? String == "slack")
            #expect(slackRow["configured"] as? Bool == true)
            #expect(slackRow["secret_names"] as? [String] == ["bot_token", "signing_secret", "app_token"])

            let manager = AgentChannelConnectionManager()
            #expect(throws: AgentChannelConnectionManagerError.reservedConnectionId("slack")) {
                try manager.upsertConnection(
                    AgentChannelConnection(
                        id: "slack",
                        name: "Shadow Slack",
                        kind: .customHTTP,
                        supportedActions: [.diagnostics],
                        customHTTP: AgentChannelCustomHTTPConfiguration(
                            baseURL: "https://hooks.example.test",
                            actions: [String: AgentChannelCustomHTTPAction]()
                        )
                    )
                )
            }
        }
    }

    private static func socketModeEnvelope(
        envelopeId: String,
        eventId: String,
        userId: String,
        text: String
    ) -> String {
        """
        {
          "envelope_id": "\(envelopeId)",
          "type": "events_api",
          "payload": {
            "team_id": "T12345",
            "api_app_id": "A12345",
            "event_id": "\(eventId)",
            "event_time": 1782427200,
            "type": "event_callback",
            "event": {
              "type": "app_mention",
              "channel": "C23456",
              "user": "\(userId)",
              "text": "\(text)",
              "ts": "1718800000.000100",
              "channel_type": "channel"
            }
          }
        }
        """
    }

    private func withIsolatedSlackStores(
        _ body: @Sendable (any SlackCredentialStorage) async throws -> Void
    ) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let previousDirectory = SlackConnectionConfigurationStore.overrideDirectory
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-slack-tests-\(UUID().uuidString)", isDirectory: true)
            let credentials = FakeSlackCredentialStore()
            SlackConnectionConfigurationStore.overrideDirectory = directory
            defer {
                SlackConnectionConfigurationStore.overrideDirectory = previousDirectory
                try? FileManager.default.removeItem(at: directory)
            }
            try await body(credentials)
        }
    }

    private func slackSignature(secret: String, timestamp: String, body: Data) -> String {
        var base = Data("v0:\(timestamp):".utf8)
        base.append(body)
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: base, using: key)
        return "v0=" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class FakeSlackCredentialStore: SlackCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBotToken: String?
    private var storedSigningSecret: String?
    private var storedAppToken: String?

    func saveBotToken(_ token: String) -> Bool {
        save(token, assign: { storedBotToken = $0 })
    }

    func botToken() -> String? {
        lock.withLock { storedBotToken }
    }

    func hasBotToken() -> Bool {
        botToken() != nil
    }

    func deleteBotToken() -> Bool {
        lock.withLock { storedBotToken = nil }
        return true
    }

    func saveSigningSecret(_ secret: String) -> Bool {
        save(secret, assign: { storedSigningSecret = $0 })
    }

    func signingSecret() -> String? {
        lock.withLock { storedSigningSecret }
    }

    func hasSigningSecret() -> Bool {
        signingSecret() != nil
    }

    func deleteSigningSecret() -> Bool {
        lock.withLock { storedSigningSecret = nil }
        return true
    }

    func saveAppToken(_ token: String) -> Bool {
        save(token, assign: { storedAppToken = $0 })
    }

    func appToken() -> String? {
        lock.withLock { storedAppToken }
    }

    func hasAppToken() -> Bool {
        appToken() != nil
    }

    func deleteAppToken() -> Bool {
        lock.withLock { storedAppToken = nil }
        return true
    }

    private func save(_ value: String, assign: (String) -> Void) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        lock.withLock { assign(trimmed) }
        return true
    }
}

private final class SlackTokenPresenceBox: @unchecked Sendable {
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

private actor SlackReceiveTransportRuntimeSpy: AgentChannelReceiveTransportRuntime {
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

private actor FakeSlackAPIClient: SlackAPIClientProtocol {
    private var authFailureMessage: String?
    private var messagesByChannel: [String: [SlackMessage]] = [:]
    private var messagePagesByChannel: [String: [SlackMessagePage]] = [:]
    private var conversationPages: [[SlackConversation]]?
    private var sentMessages: [(channelId: String, content: String, threadTs: String?)] = []
    private var openedAppToken: String?
    private var socketOpenError: (any Error)?
    private var requestedMessageCursors: [String?] = []
    private var requestedConversationCursors: [String?] = []

    func setAuthFailureEchoingSecrets(botToken: String, signingSecret: String, appToken: String) {
        authFailureMessage = """
        transport included token \(botToken), signing secret \(signingSecret), and app token \(appToken)
        """
    }

    func failSocketOpen(_ error: any Error) {
        socketOpenError = error
    }

    func clearSocketOpenFailure() {
        socketOpenError = nil
    }

    func setMessages(_ messagesByChannel: [String: [SlackMessage]]) {
        self.messagesByChannel = messagesByChannel
    }

    /// Configure explicit cursor-linked message pages for a channel.
    func setMessagePages(_ pages: [SlackMessagePage], channelId: String) {
        messagePagesByChannel[channelId] = pages
    }

    /// Configure explicit cursor-linked conversation pages.
    func setConversationPages(_ pages: [[SlackConversation]]) {
        conversationPages = pages
    }

    func messageCursorsRequested() -> [String?] {
        requestedMessageCursors
    }

    func conversationCursorsRequested() -> [String?] {
        requestedConversationCursors
    }

    private static func pageIndex(for cursor: String?) -> Int {
        guard let cursor, let index = Int(cursor.replacingOccurrences(of: "cursor-", with: "")) else {
            return 0
        }
        return index
    }

    private static func cursor(forNextPageAfter index: Int, pageCount: Int) -> String? {
        index + 1 < pageCount ? "cursor-\(index + 1)" : nil
    }

    func sentMessageCount() -> Int {
        sentMessages.count
    }

    func lastSentContent() -> String? {
        sentMessages.last?.content
    }

    func lastThreadTs() -> String? {
        sentMessages.last?.threadTs
    }

    func authTest(token: String) async throws -> SlackAuthIdentity {
        if let authFailureMessage {
            throw SlackAPIError.requestFailed(authFailureMessage)
        }
        return SlackAuthIdentity(
            url: "https://example.slack.com/",
            team: "Example",
            user: "osaurus",
            teamId: "T12345",
            userId: "U12345",
            botId: "B12345"
        )
    }

    func openSocketModeConnection(appToken: String) async throws -> URL {
        openedAppToken = appToken
        if let socketOpenError {
            throw socketOpenError
        }
        return URL(string: "wss://socket-mode.slack.test/link")!
    }

    func lastOpenedAppToken() -> String? {
        openedAppToken
    }

    func conversations(token: String, limit: Int, cursor: String?) async throws -> SlackConversationPage {
        requestedConversationCursors.append(cursor)
        let pages = conversationPages ?? [
            [
                SlackConversation(
                    id: "C23456",
                    name: "dev",
                    isChannel: true,
                    isGroup: false,
                    isIM: false,
                    isMPIM: false,
                    isPrivate: false,
                    isArchived: false,
                    isMember: true
                ),
                SlackConversation(
                    id: "C34567",
                    name: "maintainers",
                    isChannel: true,
                    isGroup: false,
                    isIM: false,
                    isMPIM: false,
                    isPrivate: false,
                    isArchived: false,
                    isMember: true
                ),
            ]
        ]
        let index = min(Self.pageIndex(for: cursor), pages.count - 1)
        return SlackConversationPage(
            conversations: pages[index],
            nextCursor: Self.cursor(forNextPageAfter: index, pageCount: pages.count)
        )
    }

    func messages(channelId: String, token: String, limit: Int, cursor: String?) async throws -> SlackMessagePage {
        requestedMessageCursors.append(cursor)
        if let pages = messagePagesByChannel[channelId], !pages.isEmpty {
            let index = min(Self.pageIndex(for: cursor), pages.count - 1)
            let page = pages[index]
            let syntheticCursor = Self.cursor(forNextPageAfter: index, pageCount: pages.count)
            return SlackMessagePage(
                messages: Array(page.messages.prefix(limit)),
                hasMore: page.hasMore || syntheticCursor != nil,
                nextCursor: page.nextCursor ?? syntheticCursor
            )
        }
        return SlackMessagePage(messages: Array((messagesByChannel[channelId] ?? []).prefix(limit)))
    }

    func threadMessages(
        channelId: String,
        threadTs: String,
        token: String,
        limit: Int,
        cursor: String?
    ) async throws -> SlackMessagePage {
        SlackMessagePage(
            messages: Array(
                (messagesByChannel[channelId] ?? [])
                    .filter { ($0.threadTs ?? $0.ts) == threadTs }
                    .prefix(limit)
            )
        )
    }

    func sendMessage(_ request: SlackOutboundMessageRequest, token: String) async throws -> SlackMessage {
        sentMessages.append((channelId: request.channelId, content: request.content, threadTs: request.threadTs))
        return .fixture(
            ts: "171880000\(sentMessages.count).000100",
            text: request.content,
            threadTs: request.threadTs
        )
    }
}

private final class FakeSlackSocketModeWebSocketFactory: SlackSocketModeWebSocketFactory, @unchecked Sendable {
    private let socket: FakeSlackSocketModeWebSocket

    init(socket: FakeSlackSocketModeWebSocket) {
        self.socket = socket
    }

    func connect(to url: URL) -> any SlackSocketModeWebSocket {
        socket
    }
}

private final class FakeSlackSocketModeWebSocket: SlackSocketModeWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String]
    private var sent: [String] = []
    private var cancelled = false
    private let sendError: (any Error)?

    init(messages: [String], sendError: (any Error)? = nil) {
        self.messages = messages
        self.sendError = sendError
    }

    func receiveText() async throws -> String {
        try lock.withLock {
            if cancelled {
                throw CancellationError()
            }
            guard !messages.isEmpty else {
                throw CancellationError()
            }
            return messages.removeFirst()
        }
    }

    func sendText(_ text: String) async throws {
        if let sendError {
            throw sendError
        }
        lock.withLock {
            sent.append(text)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    func sentTexts() async -> [String] {
        lock.withLock { sent }
    }
}

private final class FakeDiscordCredentialStoreForSlackTests: DiscordCredentialStorage, @unchecked Sendable {
    func saveBotToken(_ token: String) -> Bool { true }
    func botToken() -> String? { nil }
    func hasBotToken() -> Bool { false }
    func deleteBotToken() -> Bool { true }
}

private actor FakeDiscordAPIClientForSlackTests: DiscordAPIClientProtocol {
    func currentUser(token: String) async throws -> DiscordBotIdentity {
        throw DiscordAPIError.invalidToken
    }

    func guild(id: String, token: String) async throws -> DiscordGuild {
        throw DiscordAPIError.notFound("unused")
    }

    func channels(guildId: String, token: String) async throws -> [DiscordChannel] {
        []
    }

    func messages(channelId: String, token: String, limit: Int) async throws -> [DiscordMessage] {
        []
    }

    func sendMessage(channelId: String, content: String, token: String) async throws -> DiscordMessage {
        throw DiscordAPIError.requestFailed("unused")
    }
}

private final class SlackHTTPStubProtocol: URLProtocol {
    nonisolated(unsafe) private static var statusCode: Int = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var headers: [String: String] = [:]
    nonisolated(unsafe) private static var requestBody = Data()

    static func session(statusCode: Int, body: String, headers: [String: String] = [:]) -> URLSession {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
        self.headers = headers
        requestBody = Data()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlackHTTPStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func lastRequestJSONBody() -> [String: Any]? {
        guard !requestBody.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
    }

    static func lastRawRequestBody() -> String {
        String(data: requestBody, encoding: .utf8) ?? ""
    }

    static func lastRequestFormBody() -> [String: String] {
        guard let body = String(data: requestBody, encoding: .utf8) else { return [:] }
        return body
            .split(separator: "&")
            .reduce(into: [String: String]()) { result, pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard let name = parts.first else { return }
                let value = parts.dropFirst().first.map(String.init) ?? ""
                result[String(name)] = value.removingPercentEncoding ?? value
            }
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
            headerFields: ["Content-Type": "application/json"].merging(Self.headers) { _, new in new }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension SlackMessage {
    static func fixture(
        ts: String,
        text: String,
        threadTs: String? = nil,
        user: String = "U55555"
    ) -> SlackMessage {
        SlackMessage(
            type: "message",
            user: user,
            username: "mike",
            botId: nil,
            text: text,
            ts: ts,
            threadTs: threadTs,
            replyCount: nil
        )
    }
}

/// Records requested sleep durations and returns immediately so run-loop tests
/// can observe backoff decisions without waiting in real time. Shared with the
/// Telegram transport tests.
final class RecordingTransportSleeper: AgentChannelTransportSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []

    func sleep(for duration: TimeInterval) async throws {
        lock.withLock { delays.append(duration) }
        try Task.checkCancellation()
        await Task.yield()
    }

    func recordedDelays() -> [TimeInterval] {
        lock.withLock { delays }
    }
}

/// A socket whose receive parks until `cancel()` is called, mimicking a real
/// WebSocket waiting for Slack traffic.
private final class HangingSlackSocketModeWebSocket: SlackSocketModeWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var cancelled = false

    func receiveText() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let resumeImmediately: Bool = lock.withLock {
                if cancelled { return true }
                continuation = cont
                return false
            }
            if resumeImmediately {
                cont.resume(throwing: CancellationError())
            }
        }
    }

    func sendText(_ text: String) async throws {}

    func cancel() {
        let held: CheckedContinuation<String, any Error>? = lock.withLock {
            cancelled = true
            let current = continuation
            continuation = nil
            return current
        }
        held?.resume(throwing: URLError(.cancelled))
    }

    func isReceiveInFlight() -> Bool {
        lock.withLock { continuation != nil }
    }

    func wasCancelled() -> Bool {
        lock.withLock { cancelled }
    }
}

private final class AnySlackSocketModeWebSocketFactory: SlackSocketModeWebSocketFactory, @unchecked Sendable {
    private let socket: any SlackSocketModeWebSocket

    init(socket: any SlackSocketModeWebSocket) {
        self.socket = socket
    }

    func connect(to url: URL) -> any SlackSocketModeWebSocket {
        socket
    }
}

/// Polls an async condition until it holds or a wall-clock timeout expires.
func waitForTransportCondition(
    timeoutSeconds: TimeInterval = 10,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}
