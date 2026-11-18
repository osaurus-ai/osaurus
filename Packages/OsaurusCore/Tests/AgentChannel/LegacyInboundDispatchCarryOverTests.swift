//
//  LegacyInboundDispatchCarryOverTests.swift
//  osaurusTests
//
//  Builds without events route inbound channel messages from the
//  `inboundDispatch` block of the platform config files. Saving a config on
//  this build must leave that block exactly as it was.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct LegacyInboundDispatchCarryOverTests {
    private static let block = AgentChannelInboundDispatchConfiguration(
        enabled: true, targetAgentId: UUID(), requireMention: false)

    private static func blockJSON() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(block))
    }

    private static func rawObject(at url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Writes a file shaped like a stable build's: the platform settings
    /// this build knows plus the `inboundDispatch` block it no longer models.
    private static func writeStableFile<T: Encodable>(_ configuration: T, to url: URL) throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object[LegacyInboundDispatchCarryOver.key] = try blockJSON()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private static func expectBlockPreserved(at url: URL) throws {
        let object = try rawObject(at: url)
        let saved = try #require(object[LegacyInboundDispatchCarryOver.key])
        #expect((saved as? NSDictionary) == (try blockJSON() as? NSDictionary))
        let data = try JSONSerialization.data(withJSONObject: saved)
        #expect(try JSONDecoder().decode(AgentChannelInboundDispatchConfiguration.self, from: data) == block)
    }

    @Test func platformSavesKeepStableRouting() async throws {
        try await withIsolatedStores { _ in
            // Settings views save configurations built from form state, so
            // the saved value never carries the block itself.
            try Self.writeStableFile(
                DiscordConnectionConfiguration(), to: DiscordConnectionConfigurationStore.configurationFileURL())
            try DiscordConnectionConfigurationStore.save(DiscordConnectionConfiguration(writeEnabled: true))
            try Self.expectBlockPreserved(at: DiscordConnectionConfigurationStore.configurationFileURL())
            #expect(DiscordConnectionConfigurationStore.load().writeEnabled)

            try Self.writeStableFile(
                SlackConnectionConfiguration(), to: SlackConnectionConfigurationStore.configurationFileURL())
            try SlackConnectionConfigurationStore.save(SlackConnectionConfiguration())
            try Self.expectBlockPreserved(at: SlackConnectionConfigurationStore.configurationFileURL())

            try Self.writeStableFile(
                TelegramConnectionConfiguration(), to: TelegramConnectionConfigurationStore.configurationFileURL())
            try TelegramConnectionConfigurationStore.save(TelegramConnectionConfiguration())
            try Self.expectBlockPreserved(at: TelegramConnectionConfigurationStore.configurationFileURL())

            try Self.writeStableFile(
                IMessageConnectionConfiguration(), to: IMessageConnectionConfigurationStore.configurationFileURL())
            try IMessageConnectionConfigurationStore.save(IMessageConnectionConfiguration())
            try Self.expectBlockPreserved(at: IMessageConnectionConfigurationStore.configurationFileURL())

            try Self.writeStableFile(
                WhatsAppConnectionConfiguration(), to: WhatsAppConnectionConfigurationStore.configurationFileURL())
            try WhatsAppConnectionConfigurationStore.save(WhatsAppConnectionConfiguration())
            try Self.expectBlockPreserved(at: WhatsAppConnectionConfigurationStore.configurationFileURL())
        }
    }

    @Test func savesWithoutStableRoutingAddNothing() async throws {
        try await withIsolatedStores { _ in
            try DiscordConnectionConfigurationStore.save(DiscordConnectionConfiguration())
            try DiscordConnectionConfigurationStore.save(DiscordConnectionConfiguration(writeEnabled: true))
            let object = try Self.rawObject(at: DiscordConnectionConfigurationStore.configurationFileURL())
            #expect(object[LegacyInboundDispatchCarryOver.key] == nil)
        }
    }

    @Test func n8nConnectionSavesKeepStableRouting() async throws {
        try await withIsolatedStores { _ in
            let connection = AgentChannelConnection(
                id: "n8n-main", name: "n8n", kind: .n8n, supportedActions: [.diagnostics],
                spaceAllowlist: [AgentChannelN8nConfiguration.spaceId],
                n8n: AgentChannelN8nConfiguration())
            let other = AgentChannelConnection(
                id: "n8n-other", name: "n8n 2", kind: .n8n, supportedActions: [.diagnostics],
                spaceAllowlist: [AgentChannelN8nConfiguration.spaceId],
                n8n: AgentChannelN8nConfiguration())
            let url = AgentChannelConfigurationStore.configurationFileURL()
            try AgentChannelConfigurationStore.save(AgentChannelConfiguration(connections: [connection, other]))

            var object = try Self.rawObject(at: url)
            var connections = try #require(object["connections"] as? [[String: Any]])
            let index = try #require(connections.firstIndex { $0["id"] as? String == "n8n-main" })
            var n8n = try #require(connections[index]["n8n"] as? [String: Any])
            n8n[LegacyInboundDispatchCarryOver.key] = try Self.blockJSON()
            connections[index]["n8n"] = n8n
            object["connections"] = connections
            try JSONSerialization.data(withJSONObject: object).write(to: url)

            var configuration = AgentChannelConfigurationStore.load()
            configuration.connections = configuration.connections.map { conn in
                var renamed = conn
                renamed.name += " (edited)"
                return renamed
            }
            try AgentChannelConfigurationStore.save(configuration)

            let saved = try #require(try Self.rawObject(at: url)["connections"] as? [[String: Any]])
            let savedMain = try #require(saved.first { $0["id"] as? String == "n8n-main" })
            let savedOther = try #require(saved.first { $0["id"] as? String == "n8n-other" })
            let mainBlock = (savedMain["n8n"] as? [String: Any])?[LegacyInboundDispatchCarryOver.key]
            #expect((mainBlock as? NSDictionary) == (try Self.blockJSON() as? NSDictionary))
            #expect((savedOther["n8n"] as? [String: Any])?[LegacyInboundDispatchCarryOver.key] == nil)
            #expect(AgentChannelConfigurationStore.load().connections.allSatisfy { $0.name.hasSuffix("(edited)") })
        }
    }

    private func withIsolatedStores(_ body: @escaping @Sendable (URL) async throws -> Void) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-inbound-carry-over-\(UUID().uuidString)", isDirectory: true)
            let previous = (
                AgentChannelConfigurationStore.overrideDirectory,
                DiscordConnectionConfigurationStore.overrideDirectory,
                SlackConnectionConfigurationStore.overrideDirectory,
                TelegramConnectionConfigurationStore.overrideDirectory,
                IMessageConnectionConfigurationStore.overrideDirectory,
                WhatsAppConnectionConfigurationStore.overrideDirectory
            )
            AgentChannelConfigurationStore.overrideDirectory = root.appendingPathComponent("agent-channels")
            DiscordConnectionConfigurationStore.overrideDirectory = root.appendingPathComponent("discord")
            SlackConnectionConfigurationStore.overrideDirectory = root.appendingPathComponent("slack")
            TelegramConnectionConfigurationStore.overrideDirectory = root.appendingPathComponent("telegram")
            IMessageConnectionConfigurationStore.overrideDirectory = root.appendingPathComponent("imessage")
            WhatsAppConnectionConfigurationStore.overrideDirectory = root.appendingPathComponent("whatsapp")
            defer {
                AgentChannelConfigurationStore.overrideDirectory = previous.0
                DiscordConnectionConfigurationStore.overrideDirectory = previous.1
                SlackConnectionConfigurationStore.overrideDirectory = previous.2
                TelegramConnectionConfigurationStore.overrideDirectory = previous.3
                IMessageConnectionConfigurationStore.overrideDirectory = previous.4
                WhatsAppConnectionConfigurationStore.overrideDirectory = previous.5
                try? FileManager.default.removeItem(at: root)
            }
            try await body(root)
        }
    }
}
