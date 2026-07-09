//
//  AgentChannelNativeCoexistenceTests.swift
//  osaurusTests
//
//  Cross-provider coverage for native Agent Channel coexistence.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentChannelNativeCoexistenceTests {

    @Test func nativeDiscordSlackAndTelegramConnectionsCoexistWithoutSecretLeakage() async throws {
        try await withIsolatedNativeChannelStores { stores in
            let discord = DiscordConnectionService(
                client: DiscordAPIClient(baseURL: URL(string: "https://discord.test/api/v10")!),
                credentialStore: stores.discordCredentials
            )
            let slack = SlackConnectionService(
                client: SlackAPIClient(baseURL: URL(string: "https://slack.test/api")!),
                credentialStore: stores.slackCredentials
            )
            let telegram = TelegramConnectionService(
                client: TelegramAPIClient(baseURL: URL(string: "https://telegram.test")!),
                credentialStore: stores.telegramCredentials
            )

            try discord.saveBotToken("discord-bot-token-super-secret")
            try discord.saveConfiguration(
                DiscordConnectionConfiguration(
                    configuredGuildIds: ["111111111111111111"],
                    readableChannelIds: ["222222222222222222"],
                    writableChannelIds: ["333333333333333333"],
                    writeEnabled: true
                )
            )
            try slack.saveBotToken("xoxb-slack-bot-token-super-secret")
            try slack.saveSigningSecret("slack-signing-secret-super-secret")
            try slack.saveAppToken("xapp-slack-app-token-super-secret")
            try slack.saveConfiguration(
                SlackConnectionConfiguration(
                    configuredTeamIds: ["T12345"],
                    readableChannelIds: ["C23456"],
                    writableChannelIds: ["C34567"],
                    senderAllowlist: ["U55555"],
                    writeEnabled: true
                )
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

            let service = AgentChannelConnectionService(
                discordService: discord,
                slackService: slack,
                telegramService: telegram
            )
            let rows = service.listConnections()
            let nativeRows = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
                guard let id = row["id"] as? String,
                      ["discord", "slack", "telegram"].contains(id)
                else { return nil }
                return (id, row)
            })

            #expect(Set(nativeRows.keys) == ["discord", "slack", "telegram"])
            #expect(nativeRows["discord"]?["configured"] as? Bool == true)
            #expect(nativeRows["slack"]?["configured"] as? Bool == true)
            #expect(nativeRows["telegram"]?["configured"] as? Bool == true)

            let rendered = String(describing: rows)
            #expect(!rendered.contains("discord-bot-token-super-secret"))
            #expect(!rendered.contains("xoxb-slack-bot-token-super-secret"))
            #expect(!rendered.contains("slack-signing-secret-super-secret"))
            #expect(!rendered.contains("xapp-slack-app-token-super-secret"))
            #expect(!rendered.contains("123456:telegram-bot-token-super-secret"))
            #expect(nativeRows["slack"]?["app_token_saved"] as? Bool == true)
            #expect(nativeRows["slack"]?["sender_allowlist"] as? [String] == ["U55555"])

            let slackPolicies = nativeRows["slack"]?["action_policies"] as? [[String: Any]] ?? []
            #expect(!slackPolicies.contains { $0["status"] as? String == "configured_only" })
            let telegramPolicies = nativeRows["telegram"]?["action_policies"] as? [[String: Any]] ?? []
            #expect(!telegramPolicies.contains {
                ($0["action"] as? String) != "reply_thread"
                    && $0["status"] as? String == "configured_only"
            })
        }
    }

    @Test func connectionManagerRejectsAllNativeProviderIds() throws {
        let manager = AgentChannelConnectionManager()
        for id in ["discord", "slack", "telegram"] {
            #expect(throws: AgentChannelConnectionManagerError.reservedConnectionId(id)) {
                try manager.upsertConnection(
                    AgentChannelConnection(
                        id: id,
                        name: "Shadow \(id)",
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

    @Test func globalWriteKillSwitchBlocksNativeProviderSends() async throws {
        try await withIsolatedNativeChannelStores { stores in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-native-channel-write-gate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let killSwitch = ChannelWriteKillSwitch(fileURL: root.appendingPathComponent("write-gate.json"))
            _ = try killSwitch.disableWrites(now: Date(timeIntervalSince1970: 1))

            let slack = SlackConnectionService(
                client: SlackAPIClient(baseURL: URL(string: "https://slack.test/api")!),
                credentialStore: stores.slackCredentials
            )
            let telegram = TelegramConnectionService(
                client: TelegramAPIClient(baseURL: URL(string: "https://telegram.test")!),
                credentialStore: stores.telegramCredentials
            )
            try slack.saveConfiguration(
                SlackConnectionConfiguration(
                    writableChannelIds: ["C34567"],
                    writeEnabled: true
                )
            )
            try telegram.saveConfiguration(
                TelegramConnectionConfiguration(
                    writableChatIds: ["-100111222333"],
                    writeEnabled: true
                )
            )

            let service = AgentChannelConnectionService(
                discordService: DiscordConnectionService(
                    client: DiscordAPIClient(baseURL: URL(string: "https://discord.test/api/v10")!),
                    credentialStore: stores.discordCredentials
                ),
                slackService: slack,
                telegramService: telegram,
                writeKillSwitch: killSwitch
            )

            await #expect(throws: AgentChannelConnectionServiceError.globalWritesDisabled(generation: 1)) {
                _ = try await service.sendMessage(
                    connectionId: "slack",
                    roomId: "C34567",
                    content: "blocked",
                    confirmSend: true
                )
            }
            await #expect(throws: AgentChannelConnectionServiceError.globalWritesDisabled(generation: 1)) {
                _ = try await service.sendMessage(
                    connectionId: "telegram",
                    roomId: "-100111222333",
                    content: "blocked",
                    confirmSend: true
                )
            }

            let slackRow = try #require(
                service.listConnections().first { $0["id"] as? String == "slack" }
            )
            let slackPolicies = slackRow["action_policies"] as? [[String: Any]] ?? []
            let sendPolicy = try #require(
                slackPolicies.first { $0["action"] as? String == "send_message" }
            )
            #expect(sendPolicy["status"] as? String == "unavailable")
            #expect(sendPolicy["reason"] as? String == "Global Agent Channel writes are disabled.")
        }
    }

    private func withIsolatedNativeChannelStores(
        _ body: @Sendable (NativeChannelCredentialStores) async throws -> Void
    ) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-native-channel-coexistence-\(UUID().uuidString)", isDirectory: true)
            let previousAgentChannelDirectory = AgentChannelConfigurationStore.overrideDirectory
            let previousDiscordDirectory = DiscordConnectionConfigurationStore.overrideDirectory
            let previousSlackDirectory = SlackConnectionConfigurationStore.overrideDirectory
            let previousTelegramDirectory = TelegramConnectionConfigurationStore.overrideDirectory

            AgentChannelConfigurationStore.overrideDirectory = root.appendingPathComponent("agent-channels")
            DiscordConnectionConfigurationStore.overrideDirectory = root.appendingPathComponent("discord")
            SlackConnectionConfigurationStore.overrideDirectory = root.appendingPathComponent("slack")
            TelegramConnectionConfigurationStore.overrideDirectory = root.appendingPathComponent("telegram")
            defer {
                AgentChannelConfigurationStore.overrideDirectory = previousAgentChannelDirectory
                DiscordConnectionConfigurationStore.overrideDirectory = previousDiscordDirectory
                SlackConnectionConfigurationStore.overrideDirectory = previousSlackDirectory
                TelegramConnectionConfigurationStore.overrideDirectory = previousTelegramDirectory
                try? FileManager.default.removeItem(at: root)
            }

            try await body(NativeChannelCredentialStores())
        }
    }
}

private struct NativeChannelCredentialStores {
    let discordCredentials = NativeDiscordCredentialStore()
    let slackCredentials = NativeSlackCredentialStore()
    let telegramCredentials = NativeTelegramCredentialStore()
}

private final class NativeDiscordCredentialStore: DiscordCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func saveBotToken(_ token: String) -> Bool {
        lock.withLock { self.token = token }
        return true
    }

    func botToken() -> String? {
        lock.withLock { token }
    }

    func hasBotToken() -> Bool {
        botToken() != nil
    }

    func deleteBotToken() -> Bool {
        lock.withLock { token = nil }
        return true
    }
}

private final class NativeSlackCredentialStore: SlackCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var botTokenValue: String?
    private var signingSecretValue: String?
    private var appTokenValue: String?

    func saveBotToken(_ token: String) -> Bool {
        lock.withLock { botTokenValue = token }
        return true
    }

    func botToken() -> String? {
        lock.withLock { botTokenValue }
    }

    func hasBotToken() -> Bool {
        botToken() != nil
    }

    func deleteBotToken() -> Bool {
        lock.withLock { botTokenValue = nil }
        return true
    }

    func saveSigningSecret(_ secret: String) -> Bool {
        lock.withLock { signingSecretValue = secret }
        return true
    }

    func signingSecret() -> String? {
        lock.withLock { signingSecretValue }
    }

    func hasSigningSecret() -> Bool {
        signingSecret() != nil
    }

    func deleteSigningSecret() -> Bool {
        lock.withLock { signingSecretValue = nil }
        return true
    }

    func saveAppToken(_ token: String) -> Bool {
        lock.withLock { appTokenValue = token }
        return true
    }

    func appToken() -> String? {
        lock.withLock { appTokenValue }
    }

    func hasAppToken() -> Bool {
        appToken() != nil
    }

    func deleteAppToken() -> Bool {
        lock.withLock { appTokenValue = nil }
        return true
    }
}

private final class NativeTelegramCredentialStore: TelegramCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func saveBotToken(_ token: String) -> Bool {
        lock.withLock { self.token = token }
        return true
    }

    func botToken() -> String? {
        lock.withLock { token }
    }

    func hasBotToken() -> Bool {
        botToken() != nil
    }

    func deleteBotToken() -> Bool {
        lock.withLock { token = nil }
        return true
    }
}
