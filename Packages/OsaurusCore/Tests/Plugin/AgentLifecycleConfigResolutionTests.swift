//
//  AgentLifecycleConfigResolutionTests.swift
//  OsaurusCoreTests
//
//  Regression coverage for two lifecycle/config defects:
//
//  1. Teardown ordering: `AgentManager.delete(id:)` swept the agent's
//     Keychain secrets BEFORE posting `.agentRemoved`, so plugins that
//     read config (e.g. Telegram's `bot_token`) inside their webhook
//     deregistration callback found nothing — the webhook stayed
//     registered upstream forever. Deletion now awaits
//     `PluginManager.tearDownPluginsForRemovedAgent` (synchronous
//     `tunnel_url=""` delivery to every routed plugin) and only then
//     sweeps. The test drives a real `ExternalPlugin` with a C
//     `on_config_changed` that reads the secret mid-teardown.
//
//  2. Config default resolution: tool payload injection merged
//     `Agent.defaultId` values as global defaults, but `config_get`,
//     initial config delivery, and required-secret checks read only the
//     exact agent namespace — a key saved once on the Plugins tab was
//     "configured" for injection but invisible to `config_get`. All
//     paths now share `ToolSecretsKeychain.resolvedSecret` (exact agent
//     first, then default-agent fallback).
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Teardown ordering

@MainActor
@Suite(.serialized)
struct AgentDeletionPluginTeardownOrderingTests {

    /// Shared with the C `on_config_changed` callback via the plugin's
    /// opaque `ctx` pointer. The callback simulates a Telegram-style
    /// plugin: on `tunnel_url=""` (webhook deregistration signal) it
    /// reads its `bot_token` from the keychain — exactly what the real
    /// plugin needs to call Telegram's `deleteWebhook` API.
    final class TeardownRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _pluginId = ""
        private var _agentId: UUID?
        private var _sawDeregister = false
        private var _tokenDuringDeregister: String?

        var pluginId: String {
            get { lock.withLock { _pluginId } }
            set { lock.withLock { _pluginId = newValue } }
        }
        var agentId: UUID? {
            get { lock.withLock { _agentId } }
            set { lock.withLock { _agentId = newValue } }
        }
        var sawDeregister: Bool { lock.withLock { _sawDeregister } }
        var tokenDuringDeregister: String? { lock.withLock { _tokenDuringDeregister } }

        func recordDeregister(token: String?) {
            lock.withLock {
                _sawDeregister = true
                _tokenDuringDeregister = token
            }
        }
    }

    private static let deregisteringConfigChanged: osr_on_config_changed_t = { ctxPtr, keyPtr, valuePtr in
        guard let ctxPtr, let keyPtr, let valuePtr else { return }
        let key = String(cString: keyPtr)
        let value = String(cString: valuePtr)
        guard key == "tunnel_url", value.isEmpty else { return }
        let recorder = Unmanaged<TeardownRecorder>.fromOpaque(ctxPtr).takeUnretainedValue()
        guard let agentId = recorder.agentId else {
            recorder.recordDeregister(token: nil)
            return
        }
        // The regression: this read returned nil because the keychain
        // sweep ran before plugin teardown.
        let token = ToolSecretsKeychain.getSecret(
            id: "bot_token",
            for: recorder.pluginId,
            agentId: agentId
        )
        recorder.recordDeregister(token: token)
    }

    private func makeRoutedPlugin(
        recorder: TeardownRecorder,
        pluginId: String
    ) -> (loaded: PluginManager.LoadedPlugin, retain: Unmanaged<TeardownRecorder>) {
        let retain = Unmanaged.passRetained(recorder)
        let ctx = retain.toOpaque()
        let api = osr_plugin_api(
            free_string: { ptr in
                guard let ptr else { return }
                free(UnsafeMutableRawPointer(mutating: ptr))
            },
            init: nil,
            destroy: { _ in },
            get_manifest: nil,
            invoke: { _, _, _, _ in nil },
            version: 6,
            handle_route: { _, _ in UnsafePointer(strdup(#"{"status":200}"#)) },
            on_config_changed: Self.deregisteringConfigChanged,
            on_task_event: nil
        )
        let route = PluginManifest.RouteSpec(
            id: "webhook",
            path: "/webhook",
            methods: ["POST"]
        )
        let manifest = PluginManifest(
            plugin_id: pluginId,
            description: nil,
            capabilities: .init(
                tools: nil, routes: [route], config: nil, web: nil, artifact_handler: nil),
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
            path: "/tmp/teardown-order-\(pluginId)",
            abiVersion: 6
        )
        let loaded = PluginManager.LoadedPlugin(
            plugin: plugin,
            handle: ctx,
            tools: [],
            skills: [],
            routes: [route],
            webConfig: nil,
            readmePath: nil,
            changelogPath: nil
        )
        return (loaded, retain)
    }

    /// Deleting an agent must deliver the webhook-deregistration signal
    /// (`tunnel_url=""`) to routed plugins WHILE the agent's secrets are
    /// still in the keychain, and only sweep afterwards — all completed
    /// by the time `delete(id:)` returns.
    @Test
    func deleteNotifiesPluginsBeforeSweepingSecrets() async throws {
        try await ChatHistoryTestStorage.run {
            let pluginId = "com.test.teardown-order.\(UUID().uuidString)"
            let recorder = TeardownRecorder()
            recorder.pluginId = pluginId

            let (loaded, retain) = self.makeRoutedPlugin(recorder: recorder, pluginId: pluginId)
            PluginManager.shared.injectLoadedPluginForTesting(loaded)
            defer {
                PluginManager.shared.removeLoadedPluginForTesting(pluginId: pluginId)
                retain.release()
            }

            let agent = Agent(
                name: "TeardownOrder-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Test identity",
                agentAddress: "test-teardown-\(UUID().uuidString)"
            )
            AgentManager.shared.add(agent)
            recorder.agentId = agent.id

            ToolSecretsKeychain.saveSecret("tok-123", id: "bot_token", for: pluginId, agentId: agent.id)

            let result = await AgentManager.shared.delete(id: agent.id)
            #expect(result.deleted)

            // Teardown ran, and — the ordering regression — the plugin
            // could still read its bot_token during deregistration.
            #expect(recorder.sawDeregister, "plugin must receive tunnel_url=\"\" during delete()")
            #expect(
                recorder.tokenDuringDeregister == "tok-123",
                "secrets must still exist while the plugin deregisters its webhook"
            )

            // ...and the sweep still happened afterwards.
            #expect(
                ToolSecretsKeychain.getSecret(id: "bot_token", for: pluginId, agentId: agent.id) == nil,
                "secrets must be swept once teardown completed"
            )

            // Let the belt-and-braces `.agentRemoved` handler task run
            // while the injected plugin is still registered (its delivery
            // is deduped plugin-side, so the recorder must not fire again).
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

// MARK: - Config default resolution policy

/// Pins `ToolSecretsKeychain.resolvedSecret` — THE single resolution
/// policy (exact agent, then `Agent.defaultId` fallback) shared by
/// `config_get`, initial config delivery, and required-secret checks.
/// Uses a synthetic "defaults" write under `Agent.defaultId` and cleans
/// it up, since that UUID is shared process state.
struct ToolSecretsResolutionPolicyTests {

    @Test func exactAgentValueWins() {
        let pluginId = "com.test.resolve.\(UUID().uuidString)"
        let agent = UUID()
        defer {
            ToolSecretsKeychain.deleteAllSecrets(for: pluginId, agentId: agent)
            ToolSecretsKeychain.deleteAllSecrets(for: pluginId, agentId: Agent.defaultId)
        }

        ToolSecretsKeychain.saveSecret("global", id: "api_key", for: pluginId, agentId: Agent.defaultId)
        ToolSecretsKeychain.saveSecret("mine", id: "api_key", for: pluginId, agentId: agent)

        #expect(ToolSecretsKeychain.resolvedSecret(id: "api_key", for: pluginId, agentId: agent) == "mine")
    }

    @Test func fallsBackToDefaultAgentNamespace() {
        let pluginId = "com.test.resolve.\(UUID().uuidString)"
        let agent = UUID()
        defer {
            ToolSecretsKeychain.deleteAllSecrets(for: pluginId, agentId: Agent.defaultId)
        }

        ToolSecretsKeychain.saveSecret("global", id: "api_key", for: pluginId, agentId: Agent.defaultId)

        #expect(ToolSecretsKeychain.resolvedSecret(id: "api_key", for: pluginId, agentId: agent) == "global")
        #expect(ToolSecretsKeychain.hasResolvedSecret(id: "api_key", for: pluginId, agentId: agent))
    }

    @Test func missingEverywhereResolvesNil() {
        let pluginId = "com.test.resolve.\(UUID().uuidString)"
        let agent = UUID()
        #expect(ToolSecretsKeychain.resolvedSecret(id: "api_key", for: pluginId, agentId: agent) == nil)
        #expect(!ToolSecretsKeychain.hasResolvedSecret(id: "api_key", for: pluginId, agentId: agent))
    }

    /// Required-secret checks must agree with what tool payload injection
    /// delivers: a key satisfied by a Plugins-tab (default-agent) write
    /// counts as configured for every agent.
    @Test func requiredSecretChecksHonorDefaultFallback() {
        let pluginId = "com.test.resolve.required.\(UUID().uuidString)"
        let agent = UUID()
        defer {
            ToolSecretsKeychain.deleteAllSecrets(for: pluginId, agentId: Agent.defaultId)
        }
        let specs = [
            PluginManifest.SecretSpec(id: "bot_token", label: "Bot Token"),
            PluginManifest.SecretSpec(id: "optional_key", label: "Optional", required: false),
        ]

        #expect(!ToolSecretsKeychain.hasAllRequiredSecrets(specs: specs, for: pluginId, agentId: agent))
        #expect(
            ToolSecretsKeychain.getMissingRequiredSecrets(specs: specs, for: pluginId, agentId: agent)
                .map(\.id) == ["bot_token"]
        )

        ToolSecretsKeychain.saveSecret("tok", id: "bot_token", for: pluginId, agentId: Agent.defaultId)

        #expect(ToolSecretsKeychain.hasAllRequiredSecrets(specs: specs, for: pluginId, agentId: agent))
        #expect(
            ToolSecretsKeychain.getMissingRequiredSecrets(specs: specs, for: pluginId, agentId: agent).isEmpty
        )
    }

    /// `config_get` (via the host context, inside a TLS scope bound to a
    /// real agent) must resolve through the same policy — the Telegram
    /// `bot_token` saved as a global default is readable from plugin code.
    @Test func configGetResolvesDefaultAgentFallback() throws {
        let pluginId = "com.test.resolve.configget.\(UUID().uuidString)"
        let agent = UUID()
        defer {
            ToolSecretsKeychain.deleteAllSecrets(for: pluginId, agentId: agent)
            ToolSecretsKeychain.deleteAllSecrets(for: pluginId, agentId: Agent.defaultId)
        }

        ToolSecretsKeychain.saveSecret("tok-global", id: "bot_token", for: pluginId, agentId: Agent.defaultId)
        ToolSecretsKeychain.saveSecret("mine", id: "other_key", for: pluginId, agentId: agent)

        let ctx = try PluginHostContext(pluginId: pluginId)
        defer { ctx.teardown() }

        let (fallback, exact): (String?, String?) = PluginHostContext.withTLSScope(
            pluginId: pluginId, agentId: agent
        ) {
            (ctx.configGet(key: "bot_token"), ctx.configGet(key: "other_key"))
        }
        #expect(fallback == "tok-global", "config_get must fall back to the default-agent namespace")
        #expect(exact == "mine", "exact-agent values keep winning")

        // Anonymous context (no bound agent) still refuses to read anything.
        let anonymous = ctx.configGet(key: "bot_token")
        #expect(anonymous == nil, "no agent context must not leak the default namespace")
    }
}
