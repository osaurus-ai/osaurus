//
//  PluginAgentScopingTests.swift
//  OsaurusCoreTests
//
//  Pins the security boundary added in `Plugin Config + Loading Hardening`:
//  plugin-initiated dispatch / inference always runs under the agent that
//  invoked the plugin, never one of its choosing. Also covers the
//  surrounding hardening primitives — `parseRawRequest` strip, the no-op
//  `notifyConfigBatch` dedup, and the `config_set` payload cap.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - parseRawRequest

/// `parseRawRequest` recognizes `agent_address` / `agent_id` in the raw
/// JSON dict (so the trampoline's warn-on-override path can still see
/// them) but strips them from the sanitized data before handing it to
/// the `ChatCompletionRequest` Codable decoder. Pinning both halves
/// here guards against a regression where the sanitizer accidentally
/// drops only one or the other.
struct ParseRawRequestStripTests {

    @Test func stripsAgentAddressFromSanitizedData() throws {
        let json = """
            {"model":"local","messages":[],"agent_address":"0xabc"}
            """
        let parsed = try #require(PluginHostContext.parseRawRequest(json))
        // Raw dict still surfaces the override so the warn path can fire.
        #expect(parsed.json["agent_address"] as? String == "0xabc")
        // Sanitized data must not contain it — Codable on
        // ChatCompletionRequest would otherwise complain about an
        // unknown key under strict decoding modes.
        let sanitizedDict = try JSONSerialization.jsonObject(with: parsed.sanitized) as? [String: Any]
        #expect(sanitizedDict?["agent_address"] == nil)
    }

    @Test func stripsAgentIdFromSanitizedData() throws {
        let json = """
            {"model":"local","messages":[],"agent_id":"\(UUID().uuidString)"}
            """
        let parsed = try #require(PluginHostContext.parseRawRequest(json))
        #expect(parsed.json["agent_id"] is String)
        let sanitizedDict = try JSONSerialization.jsonObject(with: parsed.sanitized) as? [String: Any]
        #expect(sanitizedDict?["agent_id"] == nil)
    }

    @Test func stripsBothAgentKeysSimultaneously() throws {
        let json = """
            {"model":"local","messages":[],"agent_address":"0xabc","agent_id":"\(UUID().uuidString)"}
            """
        let parsed = try #require(PluginHostContext.parseRawRequest(json))
        #expect(parsed.json["agent_address"] as? String == "0xabc")
        #expect(parsed.json["agent_id"] is String)
        let sanitizedDict = try JSONSerialization.jsonObject(with: parsed.sanitized) as? [String: Any]
        #expect(sanitizedDict?["agent_address"] == nil)
        #expect(sanitizedDict?["agent_id"] == nil)
    }

    @Test func stripsBoolToolsOverride() throws {
        // `"tools": true` is the agent-tools opt-in extension; it must be
        // stripped so the array-typed `tools` Codable decode doesn't fail.
        let json = #"{"model":"local","messages":[],"tools":true}"#
        let parsed = try #require(PluginHostContext.parseRawRequest(json))
        #expect(parsed.json["tools"] as? Bool == true)
        let sanitizedDict = try JSONSerialization.jsonObject(with: parsed.sanitized) as? [String: Any]
        #expect(sanitizedDict?["tools"] == nil)
    }

    @Test func leavesArrayToolsAlone() throws {
        // Real `tools` arrays must round-trip untouched so legitimate
        // tool definitions still reach the decoder.
        let json = #"{"model":"local","messages":[],"tools":[{"type":"function"}]}"#
        let parsed = try #require(PluginHostContext.parseRawRequest(json))
        let sanitizedDict = try JSONSerialization.jsonObject(with: parsed.sanitized) as? [String: Any]
        #expect((sanitizedDict?["tools"] as? [Any])?.count == 1)
    }
}

// MARK: - resolveAgentContext

/// `resolveAgentContext` is the single host entry point that turns the
/// TLS-captured agent id into a per-agent inference context (system
/// prompt, model override, tool surface). The new contract is that it
/// looks the agent up by id only; the previous JSON-driven address
/// resolution is gone. These tests pin the three branches.
@MainActor
struct ResolveAgentContextTests {

    @Test func nilAgentIdReturnsNil() async {
        let ctx = await PluginHostContext.resolveAgentContext(agentId: nil)
        #expect(ctx == nil, "nil agent id must short-circuit and return nil")
    }

    @Test func unknownAgentIdReturnsNil() async {
        // A random UUID that AgentManager has never seen should resolve
        // to nil (not the default agent) — callers fall back to their
        // own default policy after this returns nil.
        let ctx = await PluginHostContext.resolveAgentContext(agentId: UUID())
        #expect(ctx == nil)
    }

    @Test func defaultAgentIdReturnsContext() async throws {
        let ctx = await PluginHostContext.resolveAgentContext(agentId: Agent.defaultId)
        let resolved = try #require(ctx)
        #expect(resolved.agentId == Agent.defaultId)
    }
}

// MARK: - Warn-once helpers

/// The two new warn helpers — `warnAgentOverrideOnce` and
/// `warnNoAgentContextOnce` — must exist, be callable from any thread,
/// and must not crash even when called repeatedly with the same key
/// (the dedup is provided by `PluginOnceLogger`). We can't easily
/// observe the unified-log output from a unit test, so this is a smoke
/// test that pins the call sites.
struct AgentScopingWarnHelperTests {

    @Test func warnAgentOverrideOnceIsCallable() {
        // Random plugin id keeps the dedup key unique across test runs
        // so each invocation is the "first" one PluginOnceLogger sees.
        let pid = "com.test.warn.override.\(UUID().uuidString)"
        PluginHostContext.warnAgentOverrideOnce(pluginId: pid, op: "dispatch", supplied: "0xfake")
        // Calling twice must be safe (the second call is dedup'd).
        PluginHostContext.warnAgentOverrideOnce(pluginId: pid, op: "dispatch", supplied: "0xfake")
    }

    @Test func warnNoAgentContextOnceIsCallable() {
        let pid = "com.test.warn.noctx.\(UUID().uuidString)"
        PluginHostContext.warnNoAgentContextOnce(pluginId: pid, op: "dispatch")
        PluginHostContext.warnNoAgentContextOnce(pluginId: pid, op: "dispatch")
    }

    @Test func warnConfigValueTooLargeOnceIsCallable() {
        let pid = "com.test.warn.toolarge.\(UUID().uuidString)"
        PluginHostContext.warnConfigValueTooLargeOnce(pluginId: pid, key: "blob", size: 5_000_000)
        PluginHostContext.warnConfigValueTooLargeOnce(pluginId: pid, key: "blob", size: 5_000_000)
    }
}

// MARK: - configValueMaxBytes

/// The 1 MiB cap is documented under `config_set` in the ABI header.
/// Pinning the constant value here guards against an accidental tweak
/// that would silently change the public contract.
struct ConfigValueCapTests {

    @Test func configValueMaxBytesIsOneMebibyte() {
        #expect(PluginHostContext.configValueMaxBytes == 1024 * 1024)
    }
}

// MARK: - notifyConfigBatch dedup

/// `ExternalPlugin.notifyConfigBatch` drops `(key, value)` pairs that
/// match the prior delivery for the same `(agent, key)` — so the
/// launch-time per-agent fan-out from `PluginManager` and the view's
/// `loadConfig()` re-pushes don't cause the plugin to redo expensive
/// work for values it already saw. Different value, different agent,
/// or shutdown reset must each cause a re-fire.
struct ExternalPluginConfigDedupTests {

    /// Side-channel the C callback uses to record what values reached
    /// `on_config_changed`. The plugin's `ctx` opaque pointer is
    /// recorder.toOpaque() so the callback can recover the recorder
    /// across the C boundary without capturing state.
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

    /// Builds an `ExternalPlugin` whose `on_config_changed` callback
    /// pushes into `recorder`. The recorder is passed via the `ctx`
    /// pointer so the C callback can recover it without captures —
    /// `@convention(c)` blocks cannot close over Swift state. The
    /// caller is responsible for retaining `recorder` for the
    /// duration of the test.
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

    /// `shutdown()` drains the per-plugin event queues (including the
    /// config queue) and then sets `isShutDown`. After it returns we
    /// can read the recorder synchronously and trust the count.
    @Test func samePairForSameAgentIsDeliveredOnce() async {
        let recorder = ConfigCallRecorder()
        let agentId = UUID()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.dedup.same.\(UUID().uuidString)"
        )

        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentId)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentId)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentId)

        await plugin.shutdown()
        retain.release()

        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.key == "k")
        #expect(recorder.calls.first?.value == "v")
    }

    @Test func differentValueRefires() async {
        let recorder = ConfigCallRecorder()
        let agentId = UUID()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.dedup.diffval.\(UUID().uuidString)"
        )

        plugin.notifyConfigBatch([(key: "k", value: "v1")], agentId: agentId)
        plugin.notifyConfigBatch([(key: "k", value: "v2")], agentId: agentId)
        plugin.notifyConfigBatch([(key: "k", value: "v2")], agentId: agentId)  // dedup

        await plugin.shutdown()
        retain.release()

        #expect(recorder.calls.count == 2)
        #expect(recorder.calls.map(\.value) == ["v1", "v2"])
    }

    @Test func differentAgentRefires() async {
        let recorder = ConfigCallRecorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.dedup.diffagent.\(UUID().uuidString)"
        )
        let agentA = UUID()
        let agentB = UUID()

        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentA)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentB)
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentA)  // dedup
        plugin.notifyConfigBatch([(key: "k", value: "v")], agentId: agentB)  // dedup

        await plugin.shutdown()
        retain.release()

        // One delivery per agent — the dedup is `(agent, key)` keyed.
        #expect(recorder.calls.count == 2)
    }

    @Test func emptyChangeBatchIsNoop() async {
        let recorder = ConfigCallRecorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.dedup.empty.\(UUID().uuidString)"
        )

        plugin.notifyConfigBatch([], agentId: UUID())

        await plugin.shutdown()
        retain.release()

        #expect(recorder.calls.isEmpty)
    }

    @Test func multipleKeysInOneBatchAllFire() async {
        let recorder = ConfigCallRecorder()
        let (plugin, retain) = makePlugin(
            recorder: recorder,
            pluginId: "com.test.dedup.multikey.\(UUID().uuidString)"
        )
        let agentId = UUID()

        plugin.notifyConfigBatch(
            [
                (key: "a", value: "1"),
                (key: "b", value: "2"),
                (key: "c", value: "3"),
            ],
            agentId: agentId
        )

        await plugin.shutdown()
        retain.release()

        #expect(recorder.calls.count == 3)
        #expect(Set(recorder.calls.map(\.key)) == ["a", "b", "c"])
    }
}

// MARK: - planDispatch (security boundary end-to-end)

/// `PluginHostContext.planDispatch` is the pure-function core of the
/// dispatch trampoline: it parses the plugin-supplied JSON, applies the
/// host-enforced agent scope (TLS-captured `activeAgent`), and either
/// returns an error envelope or a fully-built `DispatchRequest`. Pinning
/// it here covers the security boundary end-to-end without spinning up
/// `BackgroundTaskManager` or a real chat engine — the trampoline that
/// wraps it adds only the rate-limit check and the TaskDispatcher hop.
struct PlanDispatchTests {

    private let pluginId = "com.test.dispatch.plan"

    private func extractRequest(_ plan: PluginHostContext.DispatchPlan) -> DispatchRequest? {
        if case .request(let req) = plan { return req }
        return nil
    }

    private func extractError(_ plan: PluginHostContext.DispatchPlan) -> String? {
        if case .error(let env) = plan { return env }
        return nil
    }

    // MARK: Agent-scope enforcement

    @Test func tlsAgentIsHonored() throws {
        let agentX = UUID()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hello"}"#,
            pluginId: pluginId,
            activeAgent: agentX
        )
        let req = try #require(extractRequest(plan))
        #expect(req.agentId == agentX)
        #expect(req.sourcePluginId == pluginId)
        #expect(req.source == .plugin)
        #expect(req.prompt == "hello")
    }

    @Test func jsonAgentAddressIsIgnoredWhenTlsAgentPresent() throws {
        // The whole point of the boundary: a plugin trying to dispatch
        // under a different agent address must NOT win.
        let agentX = UUID()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","agent_address":"0xattacker"}"#,
            pluginId: pluginId,
            activeAgent: agentX
        )
        let req = try #require(extractRequest(plan))
        #expect(req.agentId == agentX, "TLS agent must override JSON-supplied agent_address")
    }

    @Test func jsonAgentIdIsIgnoredWhenTlsAgentPresent() throws {
        let agentX = UUID()
        let attackerAgent = UUID()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","agent_id":"\#(attackerAgent.uuidString)"}"#,
            pluginId: pluginId,
            activeAgent: agentX
        )
        let req = try #require(extractRequest(plan))
        #expect(req.agentId == agentX, "TLS agent must override JSON-supplied agent_id")
    }

    @Test func bothAgentKeysAreIgnoredSimultaneously() throws {
        let agentX = UUID()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"""
                {"prompt":"hi","agent_address":"0xattacker","agent_id":"\#(UUID().uuidString)"}
                """#,
            pluginId: pluginId,
            activeAgent: agentX
        )
        let req = try #require(extractRequest(plan))
        #expect(req.agentId == agentX)
    }

    @Test func nilTlsFallsBackToDefaultAgent() throws {
        // Plugin-spawned background work has no TLS agent. The host
        // routes it to the built-in default agent (and warns once).
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi"}"#,
            pluginId: pluginId,
            activeAgent: nil
        )
        let req = try #require(extractRequest(plan))
        #expect(req.agentId == Agent.defaultId)
    }

    @Test func nilTlsAndJsonOverrideStillFallsBackToDefault() throws {
        // The fallback ignores the JSON override too — plugins can
        // never dispatch into a chosen agent context.
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","agent_address":"0xattacker"}"#,
            pluginId: pluginId,
            activeAgent: nil
        )
        let req = try #require(extractRequest(plan))
        #expect(req.agentId == Agent.defaultId)
    }

    // MARK: Error envelopes

    @Test func missingPromptReturnsInvalidRequest() throws {
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"title":"no prompt here"}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let env = try #require(extractError(plan))
        #expect(env.contains("invalid_request"))
        #expect(env.contains("prompt"))
    }

    @Test func emptyPromptReturnsInvalidRequest() throws {
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":""}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let env = try #require(extractError(plan))
        #expect(env.contains("invalid_request"))
        #expect(env.contains("Prompt is empty"))
    }

    @Test func whitespaceOnlyPromptReturnsInvalidRequest() throws {
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"   \n\t  "}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let env = try #require(extractError(plan))
        #expect(env.contains("Prompt is empty"))
    }

    @Test func malformedJsonReturnsInvalidRequest() throws {
        let plan = PluginHostContext.planDispatch(
            requestJSON: "{ not valid json",
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let env = try #require(extractError(plan))
        #expect(env.contains("invalid_request"))
    }

    // MARK: Field passthrough

    @Test func sessionIdRoundTrips() throws {
        let sid = UUID().uuidString
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","session_id":"\#(sid)"}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let req = try #require(extractRequest(plan))
        #expect(req.externalSessionKey == sid)
    }

    @Test func titleRoundTrips() throws {
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","title":"My Task"}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let req = try #require(extractRequest(plan))
        #expect(req.title == "My Task")
    }

    @Test func callerSuppliedRequestIdIsHonored() throws {
        let cid = UUID()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","id":"\#(cid.uuidString)"}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let req = try #require(extractRequest(plan))
        #expect(req.id == cid)
    }

    @Test func missingRequestIdGeneratesFreshUUID() throws {
        let plan1 = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"a"}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let plan2 = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"a"}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let req1 = try #require(extractRequest(plan1))
        let req2 = try #require(extractRequest(plan2))
        #expect(req1.id != req2.id, "Each call must mint a fresh UUID when no `id` is supplied")
    }

    @Test func folderBookmarkRoundTrips() throws {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let b64 = bytes.base64EncodedString()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","folder_bookmark":"\#(b64)"}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let req = try #require(extractRequest(plan))
        #expect(req.folderBookmark == bytes)
    }

    @Test func sourcePluginIdIsAlwaysSet() throws {
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi"}"#,
            pluginId: "com.test.pluginid.\(UUID().uuidString)",
            activeAgent: UUID()
        )
        let req = try #require(extractRequest(plan))
        #expect(req.sourcePluginId?.hasPrefix("com.test.pluginid.") == true)
        #expect(req.source == .plugin)
    }
}

// MARK: - ToolSecretsKeychain.deleteAllSecrets(forAgent:)

/// Sweeps every plugin's per-agent entry by `"{agentId}."` prefix.
/// Uses synthetic agent UUIDs and a synthetic plugin id so the test
/// only touches keychain entries it created and cleaned up itself.
struct ToolSecretsKeychainAgentSweepTests {

    @Test func deletesOnlyEntriesForTargetAgent() {
        let pluginId = "com.test.keychain.sweep.\(UUID().uuidString)"
        let target = UUID()
        let bystander = UUID()

        // Defensive cleanup in case a prior crashed test left rows
        // (synthetic UUIDs make collisions astronomically unlikely
        // but the cost is one extra SecItemDelete pass).
        defer {
            ToolSecretsKeychain.deleteAllSecrets(forAgent: target)
            ToolSecretsKeychain.deleteAllSecrets(forAgent: bystander)
        }

        // Two entries for the target agent + one entry for an unrelated
        // agent. After the sweep, only the bystander entry should remain.
        ToolSecretsKeychain.saveSecret("v1", id: "key_a", for: pluginId, agentId: target)
        ToolSecretsKeychain.saveSecret("v2", id: "key_b", for: pluginId, agentId: target)
        ToolSecretsKeychain.saveSecret("vB", id: "key_a", for: pluginId, agentId: bystander)

        ToolSecretsKeychain.deleteAllSecrets(forAgent: target)

        #expect(ToolSecretsKeychain.getSecret(id: "key_a", for: pluginId, agentId: target) == nil)
        #expect(ToolSecretsKeychain.getSecret(id: "key_b", for: pluginId, agentId: target) == nil)
        #expect(ToolSecretsKeychain.getSecret(id: "key_a", for: pluginId, agentId: bystander) == "vB")
    }

    @Test func sweepIsIdempotent() {
        let target = UUID()
        // Sweeping when nothing matches must succeed silently.
        ToolSecretsKeychain.deleteAllSecrets(forAgent: target)
        ToolSecretsKeychain.deleteAllSecrets(forAgent: target)
    }
}
