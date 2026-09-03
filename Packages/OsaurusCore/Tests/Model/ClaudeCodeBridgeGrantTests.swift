//
//  ClaudeCodeBridgeGrantTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Claude Code bridge grant")
struct ClaudeCodeBridgeGrantTests {

    @Test("a minted grant resolves to the agent it was minted for")
    func mintedGrantResolves() async {
        let store = ClaudeCodeBridgeGrantStore()
        let agentId = UUID()
        let token = await store.mint(agentId: agentId, allowsConfigWrites: false)

        let grant = await store.resolve(token)
        #expect(grant?.agentId == agentId)
        #expect(grant?.allowsConfigWrites == false)
        #expect(grant?.allowsTool("osaurus_status") == true)
        #expect(grant?.allowsTool("osaurus_agent") == false)
    }

    @Test("an unknown token resolves to nothing")
    func unknownTokenRejected() async {
        let store = ClaudeCodeBridgeGrantStore()
        _ = await store.mint(agentId: UUID(), allowsConfigWrites: false)

        #expect(await store.resolve("not-a-real-grant") == nil)
    }

    @Test("an expired grant stops resolving and is dropped")
    func expiredGrantRejected() async {
        let store = ClaudeCodeBridgeGrantStore()
        let now = Date()
        let token = await store.mint(agentId: UUID(), allowsConfigWrites: false, lifetime: 60, now: now)

        #expect(await store.resolve(token, now: now.addingTimeInterval(30)) != nil)
        #expect(await store.resolve(token, now: now.addingTimeInterval(61)) == nil)
        // Resolving past expiry evicts it, so the store does not accumulate
        // dead grants for turns that were never revoked cleanly.
        #expect(await store.liveGrantCount(now: now.addingTimeInterval(61)) == 0)
    }

    @Test("lifetime cannot exceed the ceiling")
    func lifetimeClamped() async {
        let store = ClaudeCodeBridgeGrantStore()
        let now = Date()
        let token = await store.mint(
            agentId: UUID(),
            allowsConfigWrites: false,
            lifetime: 60 * 60 * 24 * 365,
            now: now
        )

        let justPastCeiling = now.addingTimeInterval(ClaudeCodeBridgeGrantStore.maxLifetime + 1)
        #expect(await store.resolve(token, now: justPastCeiling) == nil)
    }

    @Test("revoking ends the grant immediately")
    func revokeEndsGrant() async {
        let store = ClaudeCodeBridgeGrantStore()
        let token = await store.mint(agentId: UUID(), allowsConfigWrites: true)
        #expect(await store.resolve(token) != nil)

        await store.revoke(token)
        #expect(await store.resolve(token) == nil)
    }

    @Test("revokeAll clears every outstanding grant")
    func revokeAllClearsStore() async {
        let store = ClaudeCodeBridgeGrantStore()
        for _ in 0 ..< 3 { _ = await store.mint(agentId: UUID(), allowsConfigWrites: false) }
        #expect(await store.liveGrantCount() == 3)

        await store.revokeAll()
        #expect(await store.liveGrantCount() == 0)
    }

    @Test("each mint returns a distinct unguessable token")
    func tokensAreDistinct() async {
        let store = ClaudeCodeBridgeGrantStore()
        var seen = Set<String>()
        for _ in 0 ..< 50 {
            let token = await store.mint(agentId: UUID(), allowsConfigWrites: false)
            #expect(seen.insert(token).inserted, "tokens must never repeat")
            // URL-safe base64 of 32 bytes, unpadded.
            #expect(token.count >= 43)
            #expect(!token.contains("+") && !token.contains("/") && !token.contains("="))
        }
    }

    @Test("write permission is fixed at mint time")
    func writeScopeIsFixed() async {
        // The child cannot escalate: whatever the toggle said when the turn
        // started is what the grant carries for its whole life.
        let store = ClaudeCodeBridgeGrantStore()
        let readOnly = await store.mint(agentId: UUID(), allowsConfigWrites: false)
        let writable = await store.mint(agentId: UUID(), allowsConfigWrites: true)

        #expect(await store.resolve(readOnly)?.allowsConfigWrites == false)
        #expect(await store.resolve(writable)?.allowsConfigWrites == true)
        #expect(await store.resolve(readOnly)?.allowsTool("osaurus_provider") == false)
        #expect(await store.resolve(writable)?.allowsTool("osaurus_provider") == true)
        #expect(await store.resolve(writable)?.allowsTool("osaurus_schedule") == false)
    }

    @Test("the config embeds the grant in env, never in argv")
    func configCarriesGrantOutOfArgv() throws {
        // argv is world-readable via `ps`; the env block of a 0600 config file
        // is not. A grant leaking into argv would be visible to every process.
        let json = try #require(
            ClaudeCodeConfiguration.mcpConfigJSON(
                cliPath: "/usr/local/bin/osaurus",
                allowConfigWrites: false,
                bridgeGrant: "grant-abc123"
            )
        )
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let server = try #require(servers[ClaudeCodeConfiguration.mcpServerName] as? [String: Any])

        let env = try #require(server["env"] as? [String: String])
        #expect(env[ClaudeCodeBridgeGrantStore.environmentKey] == "grant-abc123")

        let args = try #require(server["args"] as? [String])
        #expect(!args.contains { $0.contains("grant-abc123") })
    }

    @Test("no grant means no env block at all")
    func configOmitsEmptyGrant() throws {
        let json = try #require(
            ClaudeCodeConfiguration.mcpConfigJSON(
                cliPath: "/usr/local/bin/osaurus",
                allowConfigWrites: false,
                bridgeGrant: nil
            )
        )
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let server = try #require(servers[ClaudeCodeConfiguration.mcpServerName] as? [String: Any])
        #expect(server["env"] == nil)
    }
}
