//
//  PluginAbiHandshakeTests.swift
//  osaurusTests
//
//  Pins the load-time ABI handshake the host now drives against every
//  newly-loaded plugin, before any real config push:
//
//  - `PluginManager.abiProbeKey` is the documented synthetic key the
//    host pushes once per plugin (`__osaurus_abi_probe__`). Plugin
//    authors hard-code this string when they want to filter the probe
//    out of their own `on_config_changed` switch — pin the value so a
//    rename in the host immediately surfaces as a test failure.
//  - `notifyConfigBatchSync` blocks the caller until the plugin's
//    `on_config_changed` returns. This is what makes the
//    `runFirstDeliverySweep` marker actually catch a SIGABRT inside
//    the plugin's host callbacks (vs. the old async path where the
//    marker had been cleared by the time the callback fired).
//  - The probe + free-string round-trip works end-to-end through the
//    real `osr_host_api` vtable (`host->get_active_agent_id` →
//    `host->free_string`). This is the production crash signature
//    the user hit with the misaligned-mirror Telegram plugin: a
//    plugin whose mirror is correct must complete the round-trip
//    without aborting.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PluginAbiHandshakeTests {

    // MARK: - Probe key contract

    /// Hard-coded constant the host pushes once per plugin at load time.
    /// Plugin authors who want to opt out of the probe in their
    /// `on_config_changed` body match against this exact string;
    /// renaming it in the host without bumping the ABI version would
    /// break every author who relied on the documented value.
    @Test
    func abiProbeKeyIsTheDocumentedConstant() {
        #expect(PluginManager.abiProbeKey == "__osaurus_abi_probe__")
    }

    /// The probe key is double-underscored so it's visually distinct
    /// from a real config key in plugin logs. Reserved for host use.
    @Test
    func abiProbeKeyHasReservedPrefix() {
        #expect(PluginManager.abiProbeKey.hasPrefix("__"))
        #expect(PluginManager.abiProbeKey.hasSuffix("__"))
    }

    // MARK: - notifyConfigBatchSync semantics

    /// Recorder shared with the C `on_config_changed` trampoline below.
    /// Same shape as `ExternalPluginConfigDedupTests.ConfigCallRecorder`
    /// — kept private here so the two test files can evolve
    /// independently without coupling.
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

    /// Trampoline shared by every test in this suite — pulls the
    /// recorder out of the plugin's `ctx` opaque pointer (the same
    /// retain-pattern `ExternalPluginConfigDedupTests` uses).
    private static let recordingOnConfigChanged: osr_on_config_changed_t = { ctxPtr, keyPtr, valuePtr in
        guard let ctxPtr, let keyPtr, let valuePtr else { return }
        let recorder = Unmanaged<ConfigCallRecorder>.fromOpaque(ctxPtr).takeUnretainedValue()
        recorder.record(
            key: String(cString: keyPtr),
            value: String(cString: valuePtr)
        )
    }

    /// Builds an `ExternalPlugin` whose `on_config_changed` callback
    /// pushes into `recorder`. The recorder is passed via the `ctx`
    /// pointer so the C callback can recover it without captures.
    /// `abiVersion` defaults to v2 (the minimum that has the
    /// `on_config_changed` slot); v1 callers pass `1` to assert
    /// the gate.
    private func makePlugin(
        recorder: ConfigCallRecorder,
        pluginId: String,
        abiVersion: UInt32 = 2
    ) -> (plugin: ExternalPlugin, retain: Unmanaged<ConfigCallRecorder>) {
        let retain = Unmanaged.passRetained(recorder)
        let ctx = retain.toOpaque()
        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: nil,
            version: abiVersion,
            handle_route: nil,
            on_config_changed: Self.recordingOnConfigChanged,
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
            path: "/tmp/abi-handshake-\(pluginId)",
            abiVersion: abiVersion
        )
        return (plugin, retain)
    }

    /// `notifyConfigBatchSync` MUST drive the plugin callback before
    /// returning. The async variant queues the work and returns
    /// immediately, which is what made the load-time loading marker
    /// useless — the marker had been cleared by the time the plugin
    /// crashed inside `on_config_changed`. The sync variant is the
    /// fix; pin its synchronous semantics so a future refactor that
    /// silently re-routes through `.async` immediately fails.
    @Test
    func notifyConfigBatchSyncBlocksUntilCallbackReturns() async {
        let recorder = ConfigCallRecorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.handshake.sync.\(UUID().uuidString)"
        )
        defer {
            Task { await plugin.shutdown() }
            retain.release()
        }

        // Snapshot BEFORE the call: nothing recorded.
        #expect(recorder.calls.isEmpty)

        plugin.notifyConfigBatchSync(
            [(key: PluginManager.abiProbeKey, value: "v")],
            agentId: UUID()
        )

        // Snapshot RIGHT AFTER the call returns — without any
        // `await shutdown()` to drain the queue. If the call was
        // really async this assertion would race and usually fail.
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.key == PluginManager.abiProbeKey)
        #expect(recorder.calls.first?.value == "v")
    }

    /// v1 plugins predate the `on_config_changed` slot, so the host
    /// must NOT dispatch into it. Mirrors the same gate that
    /// `notifyConfigBatch` enforces for the async path.
    @Test
    func notifyConfigBatchSyncIsNoopForV1Plugins() async {
        let recorder = ConfigCallRecorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.handshake.v1.\(UUID().uuidString)",
            abiVersion: 1
        )
        defer {
            Task { await plugin.shutdown() }
            retain.release()
        }

        plugin.notifyConfigBatchSync(
            [(key: PluginManager.abiProbeKey, value: "v")],
            agentId: UUID()
        )

        #expect(recorder.calls.isEmpty)
    }

    /// `notifyConfigBatchSync` shares the per-`(agent, key)` dedup
    /// table with the async variant. A second sync delivery of the
    /// same value must be dropped. Otherwise the load-time probe
    /// would re-fire on every hot reload and flood plugin authors
    /// with spurious `on_config_changed` invocations.
    @Test
    func notifyConfigBatchSyncSharesDedupWithAsyncVariant() async {
        let recorder = ConfigCallRecorder()
        let agentId = UUID()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.handshake.dedup.\(UUID().uuidString)"
        )
        defer {
            Task { await plugin.shutdown() }
            retain.release()
        }

        // Sync first, then async; the async variant must dedup
        // against the sync delivery's snapshot.
        plugin.notifyConfigBatchSync([(key: "k", value: "v")], agentId: agentId)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentId)

        await plugin.shutdown()  // drain the async dispatch queue

        #expect(recorder.calls.count == 1)
    }

    /// An empty change batch must not block on the configEventQueue —
    /// otherwise a probe that gets dedup'd to zero entries would
    /// serialize with whatever the queue is doing right now and add
    /// pointless launch latency.
    @Test
    func notifyConfigBatchSyncReturnsImmediatelyForEmptyBatch() async {
        let recorder = ConfigCallRecorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.handshake.empty.\(UUID().uuidString)"
        )
        defer {
            Task { await plugin.shutdown() }
            retain.release()
        }

        plugin.notifyConfigBatchSync([], agentId: UUID())

        #expect(recorder.calls.isEmpty)
    }

    // MARK: - End-to-end probe round-trip

    /// Drive the production round-trip the probe is designed to
    /// exercise: the plugin's `on_config_changed` calls
    /// `host->get_active_agent_id()` to resolve the active agent,
    /// reads the C string, then frees it via `host->free_string`.
    /// A correctly-aligned plugin mirror MUST complete this without
    /// aborting and MUST see the agent UUID the host bound via TLS.
    /// A misaligned mirror would either return a non-malloc pointer
    /// (one slot off) or abort inside `free_string` — exactly the
    /// production signature the misaligned Telegram plugin hit.
    @Test
    func probeRoundTripResolvesAndFreesActiveAgentIdViaHostVtable() async throws {
        // Per-test recorder + real PluginHostContext so the plugin
        // sees the production host trampolines (`makeCString`,
        // `trampolineHostFreeString`).
        final class RoundTripRecorder: @unchecked Sendable {
            let api: UnsafePointer<osr_host_api>
            private let lock = NSLock()
            private var _agentIds: [String] = []

            init(api: UnsafePointer<osr_host_api>) {
                self.api = api
            }

            var resolvedAgentIds: [String] {
                lock.withLock { _agentIds }
            }

            func record(_ id: String) {
                lock.withLock { _agentIds.append(id) }
            }
        }

        let pluginId = "com.test.handshake.roundtrip.\(UUID().uuidString)"
        let hostCtx = try PluginHostContext(pluginId: pluginId)
        defer { hostCtx.teardown() }

        let recorder = RoundTripRecorder(api: hostCtx.buildHostAPI())
        let retain = Unmanaged.passRetained(recorder)

        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: nil,
            version: 6,
            handle_route: nil,
            // Production-shape callback: read the active agent via the
            // host vtable, copy the C string into Swift, free it via
            // the host's `free_string` slot. Mirrors what the
            // misaligned plugin tried to do.
            on_config_changed: { ctxPtr, _, _ in
                guard let ctxPtr else { return }
                let recorder = Unmanaged<RoundTripRecorder>.fromOpaque(ctxPtr).takeUnretainedValue()
                let api = recorder.api.pointee
                guard let getActiveAgentId = api.get_active_agent_id,
                    let freeString = api.free_string
                else { return }
                if let cstr = getActiveAgentId() {
                    recorder.record(String(cString: cstr))
                    freeString(cstr)
                }
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

        let ctx = retain.toOpaque()
        let plugin = ExternalPlugin(
            handle: ctx,
            api: api,
            ctx: ctx,
            manifest: manifest,
            path: "/tmp/abi-handshake-roundtrip",
            abiVersion: 6
        )
        defer {
            Task { await plugin.shutdown() }
            retain.release()
        }

        let agentId = UUID()
        plugin.notifyConfigBatchSync(
            [(key: PluginManager.abiProbeKey, value: UUID().uuidString)],
            agentId: agentId
        )

        // The plugin's callback ran inside the TLS scope established
        // by `notifyConfigBatchSync` and resolved the bound agent id.
        // If the host's `makeCString` / `freeString` pairing were
        // broken — or if the test's plugin mirror were misaligned —
        // this test would abort instead of reaching the assertion.
        let resolved = recorder.resolvedAgentIds
        #expect(resolved.count == 1)
        #expect(resolved.first.flatMap(UUID.init(uuidString:)) == agentId)
    }
}
