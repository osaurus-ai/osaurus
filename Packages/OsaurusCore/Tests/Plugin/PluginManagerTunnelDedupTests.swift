//
//  PluginManagerTunnelDedupTests.swift
//  OsaurusCoreTests
//
//  Pins the dedup logic added in `Plugin Config + Loading Hardening`
//  to `PluginManager.handleTunnelStatusChange`. The original code
//  deduped against `ToolSecretsKeychain.getSecret("tunnel_url", ...)`,
//  which the plugin can mutate via `config_delete` — defeating the
//  guard and causing repeated webhook setups during launch races.
//
//  The new dedup compares against `lastPushedTunnelURL`, the host's
//  own delivery history, which the plugin can never touch.
//
//  These tests exercise the pure decision function
//  `PluginManager.shouldPushTunnelURL(...)`. The integration with
//  `pushTunnelURL` (which writes to the keychain and notifies the
//  loaded plugin via `notifyConfigChanged`) is too coupled to a real
//  plugin instance to unit test cleanly — that path is covered by the
//  manual smoke item in the plan.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct PluginManagerTunnelDedupTests {

    private let pluginId = "com.test.tunnel.dedup"

    // MARK: - First-push behavior (no entry in cache)

    @Test func emptyCacheNilUrl_skips() {
        let agent = UUID()
        // Initial state: nothing was ever pushed; tunnel is down.
        // Pushing nil over "we already have nothing" is a no-op.
        #expect(
            !PluginManager.shouldPushTunnelURL(
                url: nil,
                pluginId: pluginId,
                agentId: agent,
                cache: [:]
            )
        )
    }

    @Test func emptyCacheConnectedUrl_pushes() {
        let agent = UUID()
        // First connection — must push so the plugin learns the URL.
        #expect(
            PluginManager.shouldPushTunnelURL(
                url: "https://0xabc.agent.osaurus.ai",
                pluginId: pluginId,
                agentId: agent,
                cache: [:]
            )
        )
    }

    // MARK: - Steady-state behavior (entry matches)

    @Test func samePushedUrl_skips() {
        let agent = UUID()
        let url = "https://0xabc.agent.osaurus.ai"
        let cache: [String: [UUID: String?]] = [
            pluginId: [agent: url]
        ]
        #expect(
            !PluginManager.shouldPushTunnelURL(
                url: url,
                pluginId: pluginId,
                agentId: agent,
                cache: cache
            )
        )
    }

    // MARK: - Transitions (must always push)

    @Test func differentUrl_pushes() {
        let agent = UUID()
        let cache: [String: [UUID: String?]] = [
            pluginId: [agent: "https://old.agent.osaurus.ai"]
        ]
        #expect(
            PluginManager.shouldPushTunnelURL(
                url: "https://new.agent.osaurus.ai",
                pluginId: pluginId,
                agentId: agent,
                cache: cache
            )
        )
    }

    @Test func tunnelGoesDown_pushes() {
        let agent = UUID()
        let cache: [String: [UUID: String?]] = [
            pluginId: [agent: "https://0xabc.agent.osaurus.ai"]
        ]
        // Was connected, now down — plugin needs to know so it can
        // deregister webhooks. Push nil through.
        #expect(
            PluginManager.shouldPushTunnelURL(
                url: nil,
                pluginId: pluginId,
                agentId: agent,
                cache: cache
            )
        )
    }

    // MARK: - Scoping

    @Test func differentAgentSameUrl_pushesIndependently() {
        let agentA = UUID()
        let agentB = UUID()
        let url = "https://x.agent.osaurus.ai"
        // agentA already has the URL, agentB doesn't. The dedup is
        // per-(plugin, agent) so agentB still needs the push.
        let cache: [String: [UUID: String?]] = [
            pluginId: [agentA: url]
        ]
        #expect(
            !PluginManager.shouldPushTunnelURL(url: url, pluginId: pluginId, agentId: agentA, cache: cache)
        )
        #expect(
            PluginManager.shouldPushTunnelURL(url: url, pluginId: pluginId, agentId: agentB, cache: cache)
        )
    }

    @Test func differentPluginSameAgentSameUrl_pushesIndependently() {
        let agent = UUID()
        let url = "https://x.agent.osaurus.ai"
        let cache: [String: [UUID: String?]] = [
            "com.test.plugin.a": [agent: url]
        ]
        // Plugin A already saw the URL; plugin B still needs it.
        #expect(
            !PluginManager.shouldPushTunnelURL(
                url: url,
                pluginId: "com.test.plugin.a",
                agentId: agent,
                cache: cache
            )
        )
        #expect(
            PluginManager.shouldPushTunnelURL(
                url: url,
                pluginId: "com.test.plugin.b",
                agentId: agent,
                cache: cache
            )
        )
    }

    // MARK: - "Stay down" idempotency

    @Test func staysDown_skipsAfterFirstDownPush() {
        let agent = UUID()
        // Simulate the realistic sequence: tunnel was up, then went down.
        // After `pushTunnelURL(nil, ...)` the cache entry is removed
        // (Dictionary subscript with nil drops the key), so subsequent
        // "still down" status changes are dedup'd via the absent-entry
        // → nil treatment in `shouldPushTunnelURL`.
        var cache: [String: [UUID: String?]] = [
            pluginId: [agent: "https://x.agent.osaurus.ai"]
        ]
        // First "down" event must push.
        #expect(
            PluginManager.shouldPushTunnelURL(url: nil, pluginId: pluginId, agentId: agent, cache: cache)
        )
        // Production code's `pushTunnelURL` would remove the agent
        // slot when handed a nil URL (subscript-with-nil delete).
        cache[pluginId]?.removeValue(forKey: agent)
        // Second "still down" event must NOT push.
        #expect(
            !PluginManager.shouldPushTunnelURL(url: nil, pluginId: pluginId, agentId: agent, cache: cache)
        )
    }
}
