//
//  SlackConnectionTests.swift
//  osaurusTests
//
//  Unit and security coverage for the native Slack Agent Channel adapter.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SlackConnectionTests {

    @Test func configurationPersistsAllowlistsButNeverSecrets() async throws {
        try await withIsolatedSlackStores { credentials in
            let botToken = "xoxb-slack-bot-token-super-secret"
            let signingSecret = "slack-signing-secret-super-secret"
            let service = SlackConnectionService(client: FakeSlackAPIClient(), credentialStore: credentials)
            try service.saveBotToken(botToken)
            try service.saveSigningSecret(signingSecret)
            try service.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: [" T12345 ", "T12345"],
                    readableChannelIds: ["C23456"],
                    writableChannelIds: ["C34567"],
                    writeEnabled: true,
                    defaultReadLimit: 250
                )
            )

            let saved = SlackConnectionConfigurationStore.load()
            #expect(saved.configuredTeamIds == ["T12345"])
            #expect(saved.defaultReadLimit == 100)
            #expect(!SlackConnectionConfiguration.isValidSlackId("T١٢٣"))

            let disk = try String(
                contentsOf: SlackConnectionConfigurationStore.configurationFileURL(),
                encoding: .utf8
            )
            #expect(disk.contains("C23456"))
            #expect(!disk.contains(botToken))
            #expect(!disk.contains(signingSecret))
            #expect(!disk.localizedCaseInsensitiveContains("bot_token"))
            #expect(!disk.localizedCaseInsensitiveContains("signing_secret"))
        }
    }

    @Test func diagnosticsRedactsSavedSecretsEchoedByTransportError() async throws {
        try await withIsolatedSlackStores { credentials in
            let botToken = "xoxb-slack-bot-token-super-secret"
            let signingSecret = "slack-signing-secret-super-secret"
            let fake = FakeSlackAPIClient()
            await fake.setAuthFailureEchoingSecrets(botToken: botToken, signingSecret: signingSecret)
            let service = SlackConnectionService(client: fake, credentialStore: credentials)
            try service.saveBotToken(botToken)
            try service.saveSigningSecret(signingSecret)

            let diagnostics = await service.diagnostics()

            #expect(diagnostics.botTokenSaved)
            #expect(diagnostics.signingSecretSaved)
            #expect(diagnostics.status == "token_invalid_or_unavailable")
            let failures = diagnostics.failures.joined(separator: " ")
            #expect(failures.contains("[REDACTED:SLACK_BOT_TOKEN]"))
            #expect(failures.contains("[REDACTED:SLACK_SIGNING_SECRET]"))
            #expect(!failures.contains(botToken))
            #expect(!failures.contains(signingSecret))
            #expect(!String(describing: diagnostics.dictionary).contains(botToken))
            #expect(!String(describing: diagnostics.dictionary).contains(signingSecret))
        }
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
            channelId: "C34567",
            content: "Hello @channel <@U23456>",
            threadTs: nil,
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

        _ = try await client.conversations(token: token, limit: 10)

        let form = SlackHTTPStubProtocol.lastRequestFormBody()
        #expect(form["limit"] == "10")
        #expect(form["exclude_archived"] == "true")
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
            #expect(result["partial"] as? Bool == true)
            let messages = try #require(result["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(messages.first?["content"] as? String == "eval reports landed")
            #expect(messages.first?["thread_id"] as? String == "C23456:1718800000.000100")
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
            #expect(slackRow["secret_names"] as? [String] == ["bot_token", "signing_secret"])

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

    private func withIsolatedSlackStores(
        _ body: (any SlackCredentialStorage) async throws -> Void
    ) async throws {
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

private final class FakeSlackCredentialStore: SlackCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBotToken: String?
    private var storedSigningSecret: String?

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

    private func save(_ value: String, assign: (String) -> Void) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        lock.withLock { assign(trimmed) }
        return true
    }
}

private actor FakeSlackAPIClient: SlackAPIClientProtocol {
    private var authFailureMessage: String?
    private var messagesByChannel: [String: [SlackMessage]] = [:]
    private var sentMessages: [(channelId: String, content: String, threadTs: String?)] = []

    func setAuthFailureEchoingSecrets(botToken: String, signingSecret: String) {
        authFailureMessage = "transport included token \(botToken) and signing secret \(signingSecret)"
    }

    func setMessages(_ messagesByChannel: [String: [SlackMessage]]) {
        self.messagesByChannel = messagesByChannel
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

    func conversations(token: String, limit: Int) async throws -> [SlackConversation] {
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
    }

    func messages(channelId: String, token: String, limit: Int) async throws -> [SlackMessage] {
        Array((messagesByChannel[channelId] ?? []).prefix(limit))
    }

    func threadMessages(channelId: String, threadTs: String, token: String, limit: Int) async throws -> [SlackMessage] {
        Array((messagesByChannel[channelId] ?? []).filter { ($0.threadTs ?? $0.ts) == threadTs }.prefix(limit))
    }

    func sendMessage(channelId: String, content: String, threadTs: String?, token: String) async throws -> SlackMessage {
        sentMessages.append((channelId: channelId, content: content, threadTs: threadTs))
        return .fixture(
            ts: "171880000\(sentMessages.count).000100",
            text: content,
            threadTs: threadTs
        )
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
    nonisolated(unsafe) private static var requestBody = Data()

    static func session(statusCode: Int, body: String) -> URLSession {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
        requestBody = Data()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlackHTTPStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func lastRequestJSONBody() -> [String: Any]? {
        guard !requestBody.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
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
            headerFields: ["Content-Type": "application/json"]
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
