//
//  PluginRelayReconnectRedeliveryTests.swift
//  OsaurusCoreTests
//
//  Pins the relay-reconnect → plugin-redelivery contract:
//
//   1. The pure detection predicates `PluginManager.isConnectedStatus`
//      and `PluginManager.isReconnectTransition` (no plugin needed).
//   2. The plugin-side `notifyConfigBatch(force:)` end-to-end:
//      same-value force re-fires `on_config_changed`, force still
//      updates the dedup cache, and force is per-call (not sticky).
//
//  The relay assigns a stable URL to each agent, so disconnect/reconnect
//  cycles preserve `tunnel_url`. Without the `force` bypass, both
//  value-equality dedup layers (`shouldPushTunnelURL`,
//  `prepareConfigDelivery`) would silently drop the redelivery and
//  leave Telegram-style webhooks pointed at a dead relay session.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - 1. Reconnect detection (pure predicates)

@MainActor
struct PluginManagerReconnectDetectionTests {

    // isConnectedStatus

    @Test func isConnectedStatus_nil_isFalse() {
        #expect(!PluginManager.isConnectedStatus(nil))
    }

    @Test func isConnectedStatus_disconnected_isFalse() {
        #expect(!PluginManager.isConnectedStatus(.disconnected))
    }

    @Test func isConnectedStatus_connecting_isFalse() {
        #expect(!PluginManager.isConnectedStatus(.connecting))
    }

    @Test func isConnectedStatus_error_isFalse() {
        #expect(!PluginManager.isConnectedStatus(.error("auth_failed")))
    }

    @Test func isConnectedStatus_connected_isTrue() {
        #expect(PluginManager.isConnectedStatus(.connected(url: "https://x.agent.osaurus.ai")))
    }

    // isReconnectTransition: first-observation case

    /// First-ever observation (oldStatus == nil) is NOT a reconnect —
    /// `runFirstDeliverySweep` already pushed the launch snapshot.
    @Test func firstObservation_isNotReconnect() {
        #expect(
            !PluginManager.isReconnectTransition(
                from: nil,
                to: .connected(url: "https://x.agent.osaurus.ai")
            )
        )
        #expect(
            !PluginManager.isReconnectTransition(from: nil, to: .disconnected)
        )
    }

    // isReconnectTransition: actual reconnects

    @Test func disconnectedToConnected_isReconnect() {
        #expect(
            PluginManager.isReconnectTransition(
                from: .disconnected,
                to: .connected(url: "https://x.agent.osaurus.ai")
            )
        )
    }

    @Test func connectingToConnected_isReconnect() {
        #expect(
            PluginManager.isReconnectTransition(
                from: .connecting,
                to: .connected(url: "https://x.agent.osaurus.ai")
            )
        )
    }

    @Test func errorToConnected_isReconnect() {
        #expect(
            PluginManager.isReconnectTransition(
                from: .error("auth_failed"),
                to: .connected(url: "https://x.agent.osaurus.ai")
            )
        )
    }

    // isReconnectTransition: non-reconnect transitions

    /// Steady-state — same `.connected(U)` snapshot can fire the sink
    /// repeatedly (cross-agent status changes in the same dict). Not
    /// a reconnect; otherwise every status change would force-redeliver
    /// to every plugin.
    @Test func connectedToConnected_isNotReconnect() {
        #expect(
            !PluginManager.isReconnectTransition(
                from: .connected(url: "https://x.agent.osaurus.ai"),
                to: .connected(url: "https://x.agent.osaurus.ai")
            )
        )
    }

    /// URL-change transition is covered by `shouldPushTunnelURL`'s
    /// value-diff dedup; no force-redelivery needed.
    @Test func connectedToConnectedDifferentURL_isNotReconnect() {
        #expect(
            !PluginManager.isReconnectTransition(
                from: .connected(url: "https://old.agent.osaurus.ai"),
                to: .connected(url: "https://new.agent.osaurus.ai")
            )
        )
    }

    @Test func connectedToDisconnected_isNotReconnect() {
        #expect(
            !PluginManager.isReconnectTransition(
                from: .connected(url: "https://x.agent.osaurus.ai"),
                to: .disconnected
            )
        )
    }

    @Test func disconnectedToConnecting_isNotReconnect() {
        #expect(
            !PluginManager.isReconnectTransition(
                from: .disconnected,
                to: .connecting
            )
        )
    }
}

// MARK: - 2. ExternalPlugin force-delivery end-to-end

/// `ExternalPlugin.notifyConfigBatch(force: true)` must bypass the
/// `prepareConfigDelivery` value-equality dedup so a same-value
/// repush still invokes `on_config_changed` — the plugin-side half
/// of the relay-reconnect fix.
struct ExternalPluginConfigForceDeliveryTests {

    /// Side-channel for the C `on_config_changed` callback: the
    /// recorder is passed through the opaque `ctx` pointer because
    /// `@convention(c)` blocks can't capture Swift state. Mirrors
    /// the pattern in `ExternalPluginConfigDedupTests`.
    final class ConfigCallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(key: String, value: String)] = []
        var calls: [(key: String, value: String)] {
            lock.withLock { _calls }
        }
        func record(key: String, value: String) {
            lock.withLock { _calls.append((key, value)) }
        }
    }

    private func makePlugin(
        recorder: ConfigCallRecorder,
        pluginId: String
    ) -> (plugin: ExternalPlugin, retain: Unmanaged<ConfigCallRecorder>) {
        let retain = Unmanaged.passRetained(recorder)
        let ctx = retain.toOpaque()
        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: nil,
            version: 2,
            handle_route: nil,
            on_config_changed: { ctxPtr, keyPtr, valuePtr in
                guard let ctxPtr, let keyPtr, let valuePtr else { return }
                let r = Unmanaged<ConfigCallRecorder>.fromOpaque(ctxPtr).takeUnretainedValue()
                r.record(
                    key: String(cString: keyPtr),
                    value: String(cString: valuePtr)
                )
            },
            on_task_event: nil
        )
        let manifest = PluginManifest(
            plugin_id: pluginId,
            description: nil,
            capabilities: .init(tools: nil, routes: nil, config: nil, web: nil, artifact_handler: nil),
            instructions: nil,
            name: nil,
            version: nil,
            license: nil,
            authors: nil,
            min_macos: nil,
            min_osaurus: nil,
            secrets: nil,
            docs: nil
        )
        let plugin = ExternalPlugin(
            handle: ctx,
            api: api,
            ctx: ctx,
            manifest: manifest,
            path: "/tmp/test-\(pluginId)",
            abiVersion: 2
        )
        return (plugin, retain)
    }

    /// Same `(key, value)` repeated with `force: true` must re-fire
    /// `on_config_changed`. This is what makes Telegram-style webhook
    /// re-registration on relay reconnect work.
    @Test func sameValueWithForce_refires() async {
        let recorder = ConfigCallRecorder()
        let agentId = UUID()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.force.same.\(UUID().uuidString)"
        )

        plugin.notifyConfigBatch([(key: "tunnel_url", value: "https://x")], agentId: agentId)
        plugin.notifyConfigBatch(
            [(key: "tunnel_url", value: "https://x")],
            agentId: agentId,
            force: true
        )
        plugin.notifyConfigBatch(
            [(key: "tunnel_url", value: "https://x")],
            agentId: agentId,
            force: true
        )

        await plugin.shutdown()
        retain.release()

        #expect(recorder.calls.count == 3)
        #expect(recorder.calls.allSatisfy { $0.key == "tunnel_url" && $0.value == "https://x" })
    }

    /// `force` is per-call: after a forced delivery the cache holds
    /// the value, so subsequent default pushes with the same value
    /// still dedup. Force does not "stick" or invalidate the cache.
    @Test func forceIsPerCall_subsequentDefaultStillDedups() async {
        let recorder = ConfigCallRecorder()
        let agentId = UUID()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.force.percall.\(UUID().uuidString)"
        )

        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentId)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentId, force: true)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentId)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentId)

        await plugin.shutdown()
        retain.release()

        // Two deliveries: the initial one and the forced one. The two
        // trailing default-force pushes match the cache and are
        // dropped.
        #expect(recorder.calls.count == 2)
    }

    /// Force-delivery still updates `lastDeliveredConfig`, so a
    /// later value change dedups against the forced value. Guards
    /// against a regression where force=true skips the cache update.
    @Test func forceUpdatesCache_changedValueAfterForceFiresOnce() async {
        let recorder = ConfigCallRecorder()
        let agentId = UUID()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.force.cache.\(UUID().uuidString)"
        )

        plugin.notifyConfigBatch([(key: "k", value: "v1")], agentId: agentId)
        plugin.notifyConfigBatch([(key: "k", value: "v1")], agentId: agentId, force: true)
        plugin.notifyConfigBatch([(key: "k", value: "v2")], agentId: agentId)
        plugin.notifyConfigBatch([(key: "k", value: "v2")], agentId: agentId)

        await plugin.shutdown()
        retain.release()

        // v1, v1 (forced), v2. The trailing v2 dedups against the
        // cache that the v2 delivery just updated.
        #expect(recorder.calls.map(\.value) == ["v1", "v1", "v2"])
    }

    /// Force-delivery is per-`(agent, key)` — forcing on one agent
    /// does NOT invalidate the cache on a different agent.
    @Test func forceIsPerAgent_otherAgentStillDedups() async {
        let recorder = ConfigCallRecorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.force.peragent.\(UUID().uuidString)"
        )
        let agentA = UUID()
        let agentB = UUID()

        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentA)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentB)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentA, force: true)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentB)  // dedup

        await plugin.shutdown()
        retain.release()

        // agentA: v (initial) + v (forced) = 2 calls
        // agentB: v (initial) only — the trailing default push dedups
        #expect(recorder.calls.count == 3)
    }

    /// `notifyConfigBatchSync` exposes the same `force` flag so the
    /// load-time crash-loop guard's sync variant doesn't have to drop
    /// down to the async path to bypass dedup.
    @Test func syncVariantHonorsForce() async {
        let recorder = ConfigCallRecorder()
        let agentId = UUID()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.force.sync.\(UUID().uuidString)"
        )

        plugin.notifyConfigBatchSync([(key: "k", value: "v")], agentId: agentId)
        plugin.notifyConfigBatchSync([(key: "k", value: "v")], agentId: agentId)  // dedup
        plugin.notifyConfigBatchSync([(key: "k", value: "v")], agentId: agentId, force: true)

        await plugin.shutdown()
        retain.release()

        #expect(recorder.calls.count == 2)
    }
}
