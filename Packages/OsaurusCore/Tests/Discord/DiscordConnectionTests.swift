//
//  DiscordConnectionTests.swift
//  osaurusTests
//
//  Unit and security coverage for the native Discord connection.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DiscordConnectionTests {

    @Test func configurationPersistsAllowlistsButNeverBotToken() async throws {
        try await withIsolatedDiscordStores { credentials in
            let token = "discord-bot-token-super-secret"
            try DiscordConnectionService(client: FakeDiscordAPIClient(), credentialStore: credentials)
                .saveBotToken(token)
            let configuration = DiscordConnectionConfiguration(
                configuredGuildIds: [" 111111111111111111 ", "111111111111111111"],
                readableChannelIds: ["222222222222222222"],
                writableChannelIds: ["333333333333333333"],
                writeEnabled: true,
                defaultReadLimit: 250
            )
            try DiscordConnectionService(client: FakeDiscordAPIClient(), credentialStore: credentials)
                .saveConfiguration(configuration)

            let saved = DiscordConnectionConfigurationStore.load()
            #expect(saved.configuredGuildIds == ["111111111111111111"])
            #expect(saved.defaultReadLimit == 100)
            #expect(!DiscordConnectionConfiguration.isValidSnowflake("١١١١١١"))

            let disk = try String(
                contentsOf: DiscordConnectionConfigurationStore.configurationFileURL(),
                encoding: .utf8
            )
            #expect(disk.contains("222222222222222222"))
            #expect(!disk.contains(token))
            #expect(!disk.localizedCaseInsensitiveContains("bot_token"))
        }
    }

    @Test func diagnosticsRedactsTokenEchoedByTransportError() async throws {
        try await withIsolatedDiscordStores { credentials in
            let token = "discord-bot-token-super-secret"
            let fake = FakeDiscordAPIClient()
            await fake.setCurrentUserFailureEchoingToken()
            let service = DiscordConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken(token)
            try service.saveConfiguration(
                DiscordConnectionConfiguration(configuredGuildIds: ["111111111111111111"])
            )

            let diagnostics = await service.diagnostics()
            #expect(diagnostics.tokenSaved)
            #expect(diagnostics.status == "token_invalid_or_unavailable")
            #expect(diagnostics.failures.joined(separator: " ").contains("[REDACTED:DISCORD_BOT_TOKEN]"))
            #expect(!diagnostics.failures.joined(separator: " ").contains(token))
            #expect(!String(describing: diagnostics.dictionary).contains(token))
        }
    }

    @Test func apiClientRedactsTokenEchoedByDiscordErrorBody() async throws {
        let token = "discord-bot-token-super-secret"
        let session = DiscordHTTPStubProtocol.session(
            statusCode: 403,
            body: #"{"message":"Discord echoed \#(token)"}"#
        )
        let client = DiscordAPIClient(
            baseURL: URL(string: "https://discord.test/api/v10")!,
            sessionProvider: { session }
        )

        do {
            let _: [DiscordMessage] = try await client.messages(
                channelId: "222222222222222222",
                token: token,
                limit: 1
            )
            Issue.record("Discord request should have failed")
        } catch let error as DiscordAPIError {
            #expect(error.localizedDescription.contains("[REDACTED:DISCORD_BOT_TOKEN]"))
            #expect(!error.localizedDescription.contains(token))
        }
    }

    @Test func apiClientNeutralizesAllowedMentionsWhenSendingMessage() async throws {
        let token = "discord-bot-token-super-secret"
        let session = DiscordHTTPStubProtocol.session(
            statusCode: 200,
            body: """
                {
                  "id": "sent-1",
                  "channel_id": "333333333333333333",
                  "content": "Hello @everyone <@123456789012345678>",
                  "timestamp": "2026-06-19T20:00:00.000000+00:00",
                  "author": {
                    "id": "444444444444444444",
                    "username": "osaurus-bot",
                    "global_name": "Osaurus",
                    "bot": true
                  },
                  "attachments": []
                }
                """
        )
        let client = DiscordAPIClient(
            baseURL: URL(string: "https://discord.test/api/v10")!,
            sessionProvider: { session }
        )

        _ = try await client.sendMessage(
            channelId: "333333333333333333",
            content: "Hello @everyone <@123456789012345678>",
            token: token
        )

        let body = try #require(DiscordHTTPStubProtocol.lastRequestJSONBody())
        let allowedMentions = try #require(body["allowed_mentions"] as? [String: Any])
        let parse = try #require(allowedMentions["parse"] as? [Any])
        #expect(parse.isEmpty)
    }

    @Test func readChannelReturnsBoundedMessagesForAllowlistedChannel() async throws {
        try await withIsolatedDiscordStores { credentials in
            let fake = FakeDiscordAPIClient()
            await fake.setMessages([
                "222222222222222222": [
                    .fixture(id: "9001", channelId: "222222222222222222", content: "eval reports landed"),
                    .fixture(id: "9002", channelId: "222222222222222222", content: "review requested"),
                ]
            ])
            let service = DiscordConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    configuredGuildIds: ["111111111111111111"],
                    readableChannelIds: ["222222222222222222"],
                    defaultReadLimit: 2
                )
            )

            let result = try await service.readChannel(channelId: "222222222222222222", limit: nil)
            #expect(result["channel_id"] as? String == "222222222222222222")
            #expect(result["partial"] as? Bool == true)
            let messages = try #require(result["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(messages.first?["content"] as? String == "eval reports landed")
        }
    }

    @Test func agentChannelMessageStoreDeduplicatesProviderMessages() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }

        let message = AgentChannelStoredMessage(
            connectionId: "discord",
            roomId: "222222222222222222",
            providerMessageId: "9001",
            direction: .inbound,
            authorId: "555555555555555555",
            authorName: "Mike",
            content: "eval reports landed",
            payloadJSON: #"{"id":"9001"}"#,
            providerTimestamp: "2026-06-19T20:00:00.000000+00:00"
        )

        #expect(try store.recordMessages([message]) == 1)
        #expect(try store.recordMessages([message]) == 0)
        #expect(try store.messageCount(connectionId: "discord", roomId: "222222222222222222") == 1)

        let rows = try store.recentMessages(
            connectionId: "discord",
            roomId: "222222222222222222",
            limit: 10
        )
        #expect(rows.count == 1)
        #expect(rows.first?.direction == .inbound)
        #expect(rows.first?.payloadJSON.contains("9001") == true)
    }

    @Test func agentChannelMessageStorePrunesOldMessagesPerRoom() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }

        let messages = (1 ... 3).map { index in
            AgentChannelStoredMessage(
                connectionId: "discord",
                roomId: "222222222222222222",
                providerMessageId: "900\(index)",
                direction: .inbound,
                content: "message \(index)",
                receivedAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        #expect(try store.recordMessages(messages) == 3)
        #expect(
            try store.pruneMessages(
                connectionId: "discord",
                roomId: "222222222222222222",
                maxRows: 2
            ) == 1
        )
        let rows = try store.recentMessages(
            connectionId: "discord",
            roomId: "222222222222222222",
            limit: 10
        )
        #expect(rows.map(\.providerMessageId) == ["9003", "9002"])
    }

    @Test func agentChannelMessageStoreSkipsInvalidProviderMessageKeys() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }

        let invalid = AgentChannelStoredMessage(
            connectionId: "discord",
            roomId: "",
            providerMessageId: "9001",
            direction: .inbound,
            content: "ignored"
        )

        #expect(try store.recordMessages([invalid]) == 0)
        #expect(try store.messageCount() == 0)
    }

    @Test func agentChannelMessageStoreDeduplicatesReceiveEventsAndTracksCursor() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }

        #expect(try store.markEventSeen(connectionId: "discord", providerEventId: "gateway-seq-42"))
        #expect(try store.markEventSeen(connectionId: "discord", providerEventId: "gateway-seq-42") == false)
        #expect(try store.isEventSeen(connectionId: "discord", providerEventId: "gateway-seq-42"))

        try store.upsertCursor(
            connectionId: "discord",
            roomId: "222222222222222222",
            cursor: "after-9001"
        )
        #expect(
            try store.cursor(connectionId: "discord", roomId: "222222222222222222") == "after-9001"
        )
        #expect(try store.pruneSeenEvents(olderThan: Date().addingTimeInterval(1)) == 1)
        #expect(try store.isEventSeen(connectionId: "discord", providerEventId: "gateway-seq-42") == false)
    }

    @Test func readChannelRecordsFetchedMessagesInAgentChannelStore() async throws {
        try await withIsolatedDiscordStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeDiscordAPIClient()
            await fake.setMessages([
                "222222222222222222": [
                    .fixture(id: "9001", channelId: "222222222222222222", content: "eval reports landed"),
                    .fixture(id: "9002", channelId: "222222222222222222", content: "review requested"),
                ]
            ])
            let service = DiscordConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    readableChannelIds: ["222222222222222222"],
                    defaultReadLimit: 2
                )
            )

            _ = try await service.readChannel(channelId: "222222222222222222", limit: nil)
            _ = try await service.readChannel(channelId: "222222222222222222", limit: nil)

            #expect(try store.messageCount(connectionId: "discord", roomId: "222222222222222222") == 2)
            let rows = try store.recentMessages(
                connectionId: "discord",
                roomId: "222222222222222222",
                limit: 10
            )
            #expect(Set(rows.map(\.providerMessageId)) == ["9001", "9002"])
            #expect(rows.allSatisfy { $0.direction == .inbound })
        }
    }

    @Test func sendMessageRecordsOutboundMessageInAgentChannelStore() async throws {
        try await withIsolatedDiscordStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeDiscordAPIClient()
            let service = DiscordConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )

            _ = try await service.sendMessage(
                channelId: "333333333333333333",
                content: "Ship it",
                confirmSend: true
            )

            let row = try #require(
                try store.recentMessages(
                    connectionId: "discord",
                    roomId: "333333333333333333",
                    limit: 1
                ).first
            )
            #expect(row.providerMessageId == "sent-1")
            #expect(row.direction == .outbound)
            #expect(row.content == "Ship it")
            #expect(!row.payloadJSON.localizedCaseInsensitiveContains("discord-bot-token-super-secret"))
        }
    }

    @Test func searchMessagesRecordsScannedInboundMessagesInAgentChannelStore() async throws {
        try await withIsolatedDiscordStores { credentials in
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            defer { store.close() }

            let fake = FakeDiscordAPIClient()
            await fake.setMessages([
                "222222222222222222": [
                    .fixture(id: "9001", channelId: "222222222222222222", content: "eval reports landed"),
                    .fixture(id: "9002", channelId: "222222222222222222", content: "ordinary update"),
                ]
            ])
            let service = DiscordConnectionService(
                client: fake,
                credentialStore: credentials,
                messageStore: store,
                recordMessageSnapshotsInline: true
            )
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(readableChannelIds: ["222222222222222222"])
            )

            let result = try await service.findRecentMessages(
                query: "eval",
                channelIds: ["222222222222222222"],
                limitPerChannel: 10,
                maxMatches: 10
            )

            #expect(result["match_count"] as? Int == 1)
            #expect(try store.messageCount(connectionId: "discord", roomId: "222222222222222222") == 2)
        }
    }

    @Test func agentChannelReadToolRejectsRoomsOutsideReadAllowlist() async throws {
        try await withIsolatedDiscordStores { credentials in
            let service = DiscordConnectionService(
                client: FakeDiscordAPIClient(),
                credentialStore: credentials
            )
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(readableChannelIds: ["222222222222222222"])
            )
            let channelService = AgentChannelConnectionService(discordService: service)
            let tool = AgentChannelReadMessagesTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON: #"{"connection_id":"discord","room_id":"333333333333333333"}"#
            )
            #expect(EnvelopeAssertions.failureKind(result) == "rejected")
            #expect(EnvelopeAssertions.failureMessage(result)?.contains("not allowlisted") == true)
        }
    }

    @Test func agentChannelSendToolRequiresConfirmSendEvenWhenWriteAllowlisted() async throws {
        try await withIsolatedDiscordStores { credentials in
            let fake = FakeDiscordAPIClient()
            let service = DiscordConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let channelService = AgentChannelConnectionService(discordService: service)
            let tool = AgentChannelSendMessageTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON:
                    #"{"connection_id":"discord","room_id":"333333333333333333","content":"Ship it","confirm_send":false}"#
            )
            #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
            #expect(await fake.sentMessageCount() == 0)
        }
    }

    @Test func agentChannelSendToolPostsOnlyWhenWriteEnabledAllowlistedAndConfirmed() async throws {
        try await withIsolatedDiscordStores { credentials in
            let fake = FakeDiscordAPIClient()
            let service = DiscordConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let channelService = AgentChannelConnectionService(discordService: service)
            let tool = AgentChannelSendMessageTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON:
                    #"{"connection_id":"discord","room_id":"333333333333333333","content":"Ship it","confirm_send":true}"#
            )
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["standard_kind"] as? String == "message_sent")
            #expect(payload["kind"] as? String == "discord_message_sent")
            #expect(await fake.sentMessageCount() == 1)
            #expect(await fake.lastSentContent() == "Ship it")
        }
    }

    @Test func agentChannelSendToolRejectsMessagesAboveDiscordUTF16Limit() async throws {
        try await withIsolatedDiscordStores { credentials in
            let fake = FakeDiscordAPIClient()
            let service = DiscordConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let channelService = AgentChannelConnectionService(discordService: service)
            let tool = AgentChannelSendMessageTool(service: channelService)
            let emojiMessage = String(repeating: "😀", count: 1001)

            let result = try await tool.execute(
                argumentsJSON:
                    #"{"connection_id":"discord","room_id":"333333333333333333","content":"\#(emojiMessage)","confirm_send":true}"#
            )

            #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
            #expect(await fake.sentMessageCount() == 0)
        }
    }

    @Test func agentChannelSendToolDispatchesThroughDiscordConnection() async throws {
        try await withIsolatedDiscordStores { credentials in
            let fake = FakeDiscordAPIClient()
            let discordService = DiscordConnectionService(client: fake, credentialStore: credentials)
            try discordService.saveBotToken("discord-bot-token-super-secret")
            try discordService.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let channelService = AgentChannelConnectionService(discordService: discordService)
            let tool = AgentChannelSendMessageTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON:
                    #"{"connection_id":"discord","room_id":"333333333333333333","content":"Ship it","confirm_send":true}"#
            )
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["connection_id"] as? String == "discord")
            #expect(payload["standard_kind"] as? String == "message_sent")
            #expect(payload["kind"] as? String == "discord_message_sent")
            #expect(await fake.sentMessageCount() == 1)
        }
    }

    @Test func nativeDiscordConnectionIdIsCaseInsensitive() async throws {
        try await withIsolatedDiscordStores { credentials in
            let fake = FakeDiscordAPIClient()
            let discordService = DiscordConnectionService(client: fake, credentialStore: credentials)
            try discordService.saveBotToken("discord-bot-token-super-secret")
            try discordService.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let channelService = AgentChannelConnectionService(discordService: discordService)
            let tool = AgentChannelSendMessageTool(service: channelService)

            let result = try await tool.execute(
                argumentsJSON:
                    #"{"connection_id":"Discord","room_id":"333333333333333333","content":"Ship it","confirm_send":true}"#
            )
            let payload = try #require(EnvelopeAssertions.successPayload(result))
            #expect(payload["connection_id"] as? String == "discord")
            #expect(await fake.sentMessageCount() == 1)
        }
    }

    @Test func customAgentChannelCanBeDefinedWithPureJSON() async throws {
        try await withIsolatedDiscordStores { credentials in
            let json = """
                {
                  "schemaVersion": 1,
                  "connections": [
                    {
                      "id": "ops-webhook",
                      "name": "Ops Webhook",
                      "kind": "custom_http",
                      "enabled": true,
                      "supportedActions": ["diagnostics", "send_message"],
                      "spaceAllowlist": ["ops"],
                      "readRoomAllowlist": [],
                      "writeRoomAllowlist": ["alerts"],
                      "writeEnabled": true,
                      "defaultReadLimit": 25,
                      "secrets": [
                        { "name": "bearer", "keychainId": "ops_webhook_token" }
                      ],
                      "customHTTP": {
                        "baseURL": "https://hooks.example.test",
                        "actions": {
                          "send_message": {
                            "method": "POST",
                            "path": "/rooms/{room_id}/messages",
                            "headers": {
                              "Authorization": "Bearer ${secret:bearer}"
                            },
                            "bodyTemplate": "{\\"text\\":\\"${content}\\"}"
                          }
                        }
                      }
                    }
                  ]
                }
                """
            try FileManager.default.createDirectory(
                at: AgentChannelConfigurationStore.configurationFileURL().deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try json.write(
                to: AgentChannelConfigurationStore.configurationFileURL(),
                atomically: true,
                encoding: .utf8
            )

            let config = AgentChannelConfigurationStore.load()
            let connection = try #require(config.connection(id: "ops-webhook"))
            #expect(connection.kind == .customHTTP)
            #expect(connection.supportedActions == [.diagnostics, .sendMessage])
            #expect(connection.writeRoomAllowlist == ["alerts"])
            #expect(connection.customHTTP?.actions["send_message"]?.method == "POST")

            let service = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: FakeDiscordAPIClient(),
                    credentialStore: credentials
                )
            )
            let diagnostics = await service.diagnostics(connectionId: "ops-webhook")
            #expect(diagnostics["status"] as? String == "configured_not_executable")
            #expect(diagnostics["custom_actions"] as? [String] == ["send_message"])
        }
    }

    @Test func connectionManagerPersistsValidatedCustomChannel() async throws {
        try await withIsolatedDiscordStores { _ in
            let manager = AgentChannelConnectionManager()
            let connection = AgentChannelConnection(
                id: " ops-webhook ",
                name: " Ops Webhook ",
                kind: .customHTTP,
                supportedActions: [.diagnostics, .sendMessage, .sendMessage],
                spaceAllowlist: [" ops ", "ops"],
                writeRoomAllowlist: ["alerts"],
                writeEnabled: true,
                defaultReadLimit: 250,
                secrets: [
                    AgentChannelSecretReference(name: " bearer ", keychainId: " ops_webhook_token ")
                ],
                customHTTP: AgentChannelCustomHTTPConfiguration(
                    baseURL: "https://hooks.example.test",
                    actions: [
                        "send_message": AgentChannelCustomHTTPAction(
                            method: "post",
                            path: "/rooms/{room_id}/messages",
                            headers: [
                                "Authorization": "Bearer ${secret:bearer}"
                            ],
                            bodyTemplate: #"{"text":"${content}"}"#
                        )
                    ]
                )
            )

            try manager.upsertConnection(connection)

            let saved = try #require(manager.connection(id: "ops-webhook"))
            #expect(saved.name == "Ops Webhook")
            #expect(saved.supportedActions == [.diagnostics, .sendMessage])
            #expect(saved.spaceAllowlist == ["ops"])
            #expect(saved.defaultReadLimit == 100)
            #expect(saved.secrets == [AgentChannelSecretReference(name: "bearer", keychainId: "ops_webhook_token")])
            #expect(saved.customHTTP?.actions["send_message"]?.method == "POST")

            let disk = try String(
                contentsOf: AgentChannelConfigurationStore.configurationFileURL(),
                encoding: .utf8
            )
            #expect(disk.contains("ops_webhook_token"))
            #expect(!disk.localizedCaseInsensitiveContains("discord-bot-token"))
        }
    }

    @Test func connectionManagerRenameRemovesOriginalConnection() async throws {
        try await withIsolatedDiscordStores { _ in
            let manager = AgentChannelConnectionManager()
            try manager.upsertConnection(
                AgentChannelConnection(
                    id: "ops-webhook",
                    name: "Ops Webhook",
                    kind: .customHTTP,
                    supportedActions: [.diagnostics],
                    customHTTP: AgentChannelCustomHTTPConfiguration(
                        baseURL: "https://hooks.example.test",
                        actions: [String: AgentChannelCustomHTTPAction]()
                    )
                )
            )

            try manager.upsertConnection(
                AgentChannelConnection(
                    id: "incident-webhook",
                    name: "Incident Webhook",
                    kind: .customHTTP,
                    supportedActions: [.diagnostics],
                    customHTTP: AgentChannelCustomHTTPConfiguration(
                        baseURL: "https://hooks.example.test",
                        actions: [String: AgentChannelCustomHTTPAction]()
                    )
                ),
                replacingOriginalId: "ops-webhook"
            )

            let saved = manager.loadConfiguration().connections
            #expect(saved.map(\.id) == ["incident-webhook"])
            #expect(manager.connection(id: "ops-webhook") == nil)
            #expect(manager.connection(id: "incident-webhook")?.name == "Incident Webhook")
        }
    }

    @Test func connectionManagerRejectsDuplicateCreateWithoutRenameContext() async throws {
        try await withIsolatedDiscordStores { _ in
            let manager = AgentChannelConnectionManager()
            let connection = AgentChannelConnection(
                id: "ops-webhook",
                name: "Ops Webhook",
                kind: .customHTTP,
                supportedActions: [.diagnostics],
                customHTTP: AgentChannelCustomHTTPConfiguration(
                    baseURL: "https://hooks.example.test",
                    actions: [String: AgentChannelCustomHTTPAction]()
                )
            )

            try manager.upsertConnection(connection)

            #expect(throws: AgentChannelConnectionManagerError.duplicateConnectionId("ops-webhook")) {
                try manager.upsertConnection(
                    AgentChannelConnection(
                        id: "ops-webhook",
                        name: "Replacement",
                        kind: .customHTTP,
                        supportedActions: [.diagnostics],
                        customHTTP: AgentChannelCustomHTTPConfiguration(
                            baseURL: "https://hooks.example.test",
                            actions: [String: AgentChannelCustomHTTPAction]()
                        )
                    )
                )
            }

            #expect(manager.connection(id: "ops-webhook")?.name == "Ops Webhook")
        }
    }

    @Test func connectionManagerExportExcludesNativeDiscordCredentials() async throws {
        try await withIsolatedDiscordStores { _ in
            let token = "discord-bot-token-super-secret"
            try DiscordConnectionConfigurationStore.save(
                DiscordConnectionConfiguration(
                    configuredGuildIds: ["111111111111111111"],
                    readableChannelIds: ["222222222222222222"],
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            let manager = AgentChannelConnectionManager()
            try manager.upsertConnection(
                AgentChannelConnection(
                    id: "ops-webhook",
                    name: "Ops Webhook",
                    kind: .customHTTP,
                    supportedActions: [.diagnostics],
                    secrets: [
                        AgentChannelSecretReference(name: "bearer", keychainId: "ops_webhook_token")
                    ],
                    customHTTP: AgentChannelCustomHTTPConfiguration(
                        baseURL: "https://hooks.example.test",
                        actions: [String: AgentChannelCustomHTTPAction]()
                    )
                )
            )

            let exported = try String(
                data: manager.exportConfigurationData(),
                encoding: .utf8
            )
            let export = try #require(exported)
            #expect(export.contains("ops_webhook_token"))
            #expect(!export.contains(token))
            #expect(!export.contains(#""name" : "bot_token""#))
            #expect(!export.contains(#""keychainId" : "bot_token""#))
            #expect(!export.contains("111111111111111111"))
            #expect(!export.contains("222222222222222222"))
        }
    }

    @Test func connectionManagerRejectsReservedIdsAndUnsafeHTTPFields() async throws {
        try await withIsolatedDiscordStores { _ in
            let manager = AgentChannelConnectionManager()

            #expect(throws: AgentChannelConnectionManagerError.reservedConnectionId("discord")) {
                try manager.upsertConnection(
                    AgentChannelConnection(
                        id: "discord",
                        name: "Not Native Discord",
                        kind: .customHTTP,
                        supportedActions: [.diagnostics],
                        customHTTP: AgentChannelCustomHTTPConfiguration(
                            baseURL: "https://hooks.example.test",
                            actions: [String: AgentChannelCustomHTTPAction]()
                        )
                    )
                )
            }

            #expect(
                throws: AgentChannelConnectionManagerError.invalidCustomHTTPHeader(
                    action: "send_message",
                    header: "Authorization"
                )
            ) {
                try manager.upsertConnection(
                    AgentChannelConnection(
                        id: "unsafe-webhook",
                        name: "Unsafe Webhook",
                        kind: .customHTTP,
                        supportedActions: [.sendMessage],
                        customHTTP: AgentChannelCustomHTTPConfiguration(
                            baseURL: "https://hooks.example.test",
                            actions: [
                                "send_message": AgentChannelCustomHTTPAction(
                                    method: "POST",
                                    path: "/messages",
                                    headers: [
                                        "Authorization": "Bearer ok\nInjected: value"
                                    ]
                                )
                            ]
                        )
                    )
                )
            }
        }
    }

    @Test func connectionManagerImportRejectsDuplicateIds() async throws {
        try await withIsolatedDiscordStores { _ in
            let manager = AgentChannelConnectionManager()
            let json = """
                {
                  "schemaVersion": 1,
                  "connections": [
                    {
                      "id": "ops-webhook",
                      "name": "Ops Webhook",
                      "kind": "custom_http",
                      "enabled": true,
                      "supportedActions": ["diagnostics"],
                      "spaceAllowlist": [],
                      "readRoomAllowlist": [],
                      "writeRoomAllowlist": [],
                      "writeEnabled": false,
                      "defaultReadLimit": 50,
                      "secrets": [],
                      "customHTTP": { "baseURL": "https://hooks.example.test", "actions": {} }
                    },
                    {
                      "id": "ops-webhook",
                      "name": "Duplicate",
                      "kind": "custom_http",
                      "enabled": true,
                      "supportedActions": ["diagnostics"],
                      "spaceAllowlist": [],
                      "readRoomAllowlist": [],
                      "writeRoomAllowlist": [],
                      "writeEnabled": false,
                      "defaultReadLimit": 50,
                      "secrets": [],
                      "customHTTP": { "baseURL": "https://hooks.example.test", "actions": {} }
                    }
                  ]
                }
                """

            #expect(throws: AgentChannelConnectionManagerError.duplicateConnectionId("ops-webhook")) {
                try manager.importConfigurationData(Data(json.utf8))
            }
        }
    }

    @Test func findRecentMessagesScansOnlyReadableChannels() async throws {
        try await withIsolatedDiscordStores { credentials in
            let fake = FakeDiscordAPIClient()
            await fake.setMessages([
                "222222222222222222": [
                    .fixture(id: "9001", channelId: "222222222222222222", content: "eval reports landed")
                ],
                "333333333333333333": [
                    .fixture(id: "9002", channelId: "333333333333333333", content: "eval secret")
                ],
            ])
            let service = DiscordConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(readableChannelIds: ["222222222222222222"])
            )

            let result = try await service.findRecentMessages(
                query: "eval",
                channelIds: ["222222222222222222", "333333333333333333"],
                limitPerChannel: 10,
                maxMatches: 10
            )
            let channelIds = try #require(result["searched_channel_ids"] as? [String])
            #expect(channelIds == ["222222222222222222"])
            let messages = try #require(result["messages"] as? [[String: Any]])
            #expect(messages.count == 1)
            #expect(messages.first?["id"] as? String == "9001")
        }
    }

    @Test func nativeAgentChannelToolsAreDynamicButNotPluginOwned() async throws {
        let names = ToolRegistry.agentChannelToolNames.sorted()
        let phantomDiscordNames: Set<String> = [
            "discord_diagnostics",
            "discord_list_servers",
            "discord_list_channels",
            "discord_read_channel",
            "discord_read_thread",
            "discord_find_recent_messages",
            "discord_draft_message",
            "discord_send_message",
            "discord_reply_to_thread",
        ]
        let (registeredNames, builtInNames, pluginNames, phantomNames) = await MainActor.run {
            (
                Set(ToolRegistry.shared.listTools().map(\.name)),
                ToolRegistry.shared.builtInToolNames,
                names.filter { ToolRegistry.shared.isPluginTool($0) },
                phantomDiscordNames.filter { ToolRegistry.shared.entry(named: $0) != nil }
            )
        }
        #expect(Set(names).isSubset(of: registeredNames))
        #expect(pluginNames.isEmpty)
        #expect(phantomNames.isEmpty)

        for name in names {
            #expect(ToolRegistry.externallyDeniedToolNames.contains(name))
            #expect(!builtInNames.contains(name))
            #expect(!ToolRegistry.isDeniedForCurrentSurface(name))
            let denied = ChatExecutionContext.$isExternalSurface.withValue(true) {
                ToolRegistry.isDeniedForCurrentSurface(name)
            }
            #expect(denied)

            let envelope = ToolRegistry.externalSurfaceDenialEnvelope(tool: name)
            #expect(EnvelopeAssertions.failureKind(envelope) == "rejected")
            #expect(EnvelopeAssertions.failureMessage(envelope)?.contains("Osaurus app") == true)
        }

        for name in phantomDiscordNames {
            #expect(!ToolRegistry.externallyDeniedToolNames.contains(name))
        }
    }

    @Test func discordChannelIsConfiguredForWriteOnlySetups() async throws {
        try await withIsolatedDiscordStores { credentials in
            let service = DiscordConnectionService(
                client: FakeDiscordAPIClient(),
                credentialStore: credentials
            )
            try service.saveBotToken("discord-bot-token-super-secret")
            try service.saveConfiguration(
                DiscordConnectionConfiguration(
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )

            let channelService = AgentChannelConnectionService(discordService: service)
            let discordRow = try #require(
                channelService.listConnections().first { $0["id"] as? String == "discord" }
            )

            #expect(discordRow["configured"] as? Bool == true)
            #expect(discordRow["credential_saved"] as? Bool == true)
        }
    }

    private func withIsolatedDiscordStores(
        _ body: (any DiscordCredentialStorage) async throws -> Void
    ) async throws {
        let previousDirectory = DiscordConnectionConfigurationStore.overrideDirectory
        let previousChannelDirectory = AgentChannelConfigurationStore.overrideDirectory
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-discord-tests-\(UUID().uuidString)", isDirectory: true)
        let credentials = FakeDiscordCredentialStore()
        DiscordConnectionConfigurationStore.overrideDirectory = directory
        AgentChannelConfigurationStore.overrideDirectory = directory
        defer {
            DiscordConnectionConfigurationStore.overrideDirectory = previousDirectory
            AgentChannelConfigurationStore.overrideDirectory = previousChannelDirectory
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(credentials)
    }
}

private final class FakeDiscordCredentialStore: DiscordCredentialStorage, @unchecked Sendable {
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

private actor FakeDiscordAPIClient: DiscordAPIClientProtocol {
    private var shouldEchoTokenFailure = false
    private var messagesByChannel: [String: [DiscordMessage]] = [:]
    private var sentMessages: [(channelId: String, content: String)] = []

    func setCurrentUserFailureEchoingToken() {
        shouldEchoTokenFailure = true
    }

    func setMessages(_ messagesByChannel: [String: [DiscordMessage]]) {
        self.messagesByChannel = messagesByChannel
    }

    func sentMessageCount() -> Int {
        sentMessages.count
    }

    func lastSentContent() -> String? {
        sentMessages.last?.content
    }

    func currentUser(token: String) async throws -> DiscordBotIdentity {
        if shouldEchoTokenFailure {
            throw DiscordAPIError.requestFailed("transport included token \(token)")
        }
        return DiscordBotIdentity(
            id: "444444444444444444",
            username: "osaurus-bot",
            globalName: "Osaurus",
            bot: true
        )
    }

    func guild(id: String, token: String) async throws -> DiscordGuild {
        DiscordGuild(id: id, name: "Test Guild")
    }

    func channels(guildId: String, token: String) async throws -> [DiscordChannel] {
        [
            DiscordChannel(
                id: "222222222222222222",
                guildId: guildId,
                name: "dev",
                type: 0,
                parentId: nil
            ),
            DiscordChannel(
                id: "333333333333333333",
                guildId: guildId,
                name: "maintainers",
                type: 0,
                parentId: nil
            ),
        ]
    }

    func messages(channelId: String, token: String, limit: Int) async throws -> [DiscordMessage] {
        Array((messagesByChannel[channelId] ?? []).prefix(limit))
    }

    func sendMessage(channelId: String, content: String, token: String) async throws -> DiscordMessage {
        sentMessages.append((channelId: channelId, content: content))
        return .fixture(
            id: "sent-\(sentMessages.count)",
            channelId: channelId,
            content: content,
            author: DiscordMessageAuthor(
                id: "444444444444444444",
                username: "osaurus-bot",
                globalName: "Osaurus",
                bot: true
            )
        )
    }
}

private final class DiscordHTTPStubProtocol: URLProtocol {
    nonisolated(unsafe) private static var statusCode: Int = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var requestBody = Data()

    static func session(statusCode: Int, body: String) -> URLSession {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
        requestBody = Data()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscordHTTPStubProtocol.self]
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

private extension DiscordMessage {
    static func fixture(
        id: String,
        channelId: String,
        content: String,
        author: DiscordMessageAuthor = DiscordMessageAuthor(
            id: "555555555555555555",
            username: "mike",
            globalName: "Mike",
            bot: false
        )
    ) -> DiscordMessage {
        DiscordMessage(
            id: id,
            channelId: channelId,
            content: content,
            timestamp: "2026-06-19T20:00:00.000000+00:00",
            author: author,
            attachments: []
        )
    }
}
