//
//  CredentialConsumerTests.swift
//  OsaurusCoreTests
//
//  Consumers outside the plugin/agent paths: MCP and channel items carried
//  into the Keys store (legacy items left in place), `credential:` refs in
//  declarative config, and a native plugin's keys kept out of its results.
//

import Foundation
import Testing

@testable import OsaurusCore

struct CredentialConsumerMigrationTests {
    @Test("MCP env, header and bearer items become shared keys; the old items stay")
    func mcpItemsMigrate() {
        CredentialStore._withIsolatedStoreForTesting {
            let id = UUID()
            let stdio = MCPProvider(
                id: id, name: "Files", url: "", transport: .stdio, secretEnvKeys: ["FILES_TOKEN"])
            let httpId = UUID()
            let http = MCPProvider(
                id: httpId, name: "Tracker", url: "https://tracker.example/mcp",
                secretHeaderKeys: ["X-Api-Key"], authType: .bearerToken)
            let legacy = [
                "\(id.uuidString).env.FILES_TOKEN": "env-secret-1",
                "\(httpId.uuidString).header.X-Api-Key": "header-secret-2",
                "\(httpId.uuidString).token": "bearer-secret-3",
            ]

            MCPProviderKeychain.$_legacyItemsForTesting.withValue(legacy) {
                #expect(MCPCredentials.envValue(stdio, name: "FILES_TOKEN", agentId: nil) == "env-secret-1")
                #expect(http.hasToken)

                var inputs = CredentialMigration.Inputs()
                inputs.mcpProviders = [stdio, http]
                #expect(CredentialMigration.run(inputs: inputs).failed == 0)
            }

            let store = CredentialStore.current
            #expect(store.value(MCPCredentials.envSlot(stdio, name: "FILES_TOKEN").effectiveKey(), scope: .global)
                == "env-secret-1")
            #expect(store.value(MCPCredentials.headerSlot(http, header: "X-Api-Key").effectiveKey(), scope: .global)
                == "header-secret-2")
            #expect(store.value(MCPCredentials.tokenSlot(http).effectiveKey(), scope: .global) == "bearer-secret-3")

            // Served from the Keys store once imported, even with the old items gone.
            MCPProviderKeychain.$_legacyItemsForTesting.withValue([:]) {
                #expect(MCPCredentials.headerValue(http, header: "X-Api-Key", agentId: nil) == "header-secret-2")
                #expect(MCPCredentials.tokenValue(http, agentId: nil) == "bearer-secret-3")
                #expect(http.hasToken)
            }
        }
    }

    @Test("a custom channel's token becomes a shared key; the old item stays")
    func channelTokenMigrates() {
        CredentialStore._withIsolatedStoreForTesting {
            let connectionId = UUID().uuidString
            let pluginId = ChannelCredentials.agentChannelPluginId(connectionId)
            let account = "\(Agent.defaultId.uuidString).\(pluginId).webhook_secret"
            ToolSecretsKeychain._testSeedRawAccount(account, value: "channel-secret-4")
            defer { ToolSecretsKeychain._testRemoveRawAccount(account) }

            #expect(
                ChannelCredentials.agentChannelValue(
                    connectionId: connectionId, connectionName: "Orders", secretName: "webhook_secret")
                    == "channel-secret-4")

            var inputs = CredentialMigration.Inputs()
            inputs.agentChannels = [.init(id: connectionId, name: "Orders")]
            let report = CredentialMigration.run(inputs: inputs)
            #expect(report.failed == 0)

            let slot = ChannelCredentialSlots.agentChannel(
                connectionId: connectionId, connectionName: "Orders", secretName: "webhook_secret")
            #expect(CredentialStore.current.value(slot.effectiveKey(), scope: .global) == "channel-secret-4")
            #expect(ToolSecretsKeychain._testRawAccountValue(account) == "channel-secret-4")
        }
    }
}

struct CredentialConfigRefTests {
    @Test("credential: refs parse, check presence from the index, and resolve shared values")
    func credentialRefs() {
        CredentialStore._withIsolatedStoreForTesting {
            guard case .success(let ref) = ConfigSecretRef.parse("credential:ORDERS_TOKEN") else {
                Issue.record("credential ref failed to parse")
                return
            }
            #expect(ref.source == .credential("ORDERS_TOKEN"))
            #expect(ref.display == "credential:ORDERS_TOKEN")
            for raw in ["credential:", "credential:9BAD", "credential:HAS SPACE"] {
                if case .success = ConfigSecretRef.parse(raw) { Issue.record("`\(raw)` should not parse") }
            }

            #expect(ref.planTimeIssue(label: "x") != nil)
            #expect(ref.resolve() == nil)

            let store = CredentialStore.current
            store.save("ORDERS_TOKEN", scope: .agent(UUID()), value: "agent-only-value", origin: .user)
            #expect(ref.planTimeIssue(label: "x") != nil, "an agent's own value is not shared")
            #expect(ref.resolve() == nil)

            store.save("ORDERS_TOKEN", scope: .global, value: "  shared-value-5  ", origin: .user)
            #expect(ref.planTimeIssue(label: "x") == nil)
            #expect(ref.resolve() == "shared-value-5")
        }
    }
}

@Suite(.serialized)
struct NativePluginKeyContainmentTests {
    final class EchoRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [String] = []
        var last: String? { lock.withLock { payloads.last } }
        func record(_ payload: String) { lock.withLock { payloads.append(payload) } }
    }

    @Test("a native plugin gets its declared key but an echo of it is redacted")
    func nativeResultsAreScrubbed() async throws {
        let recorder = EchoRecorder()
        let retain = Unmanaged.passRetained(recorder)
        defer { retain.release() }
        let pluginId = "com.test.echo.\(UUID().uuidString.prefix(8).lowercased())"
        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: { ctxPtr, _, _, payloadPtr in
                guard let ctxPtr, let payloadPtr else { return nil }
                let payload = String(cString: payloadPtr)
                Unmanaged<EchoRecorder>.fromOpaque(ctxPtr).takeUnretainedValue().record(payload)
                return UnsafePointer(strdup(payload))
            },
            version: 6,
            handle_route: nil,
            on_config_changed: nil,
            on_task_event: nil
        )
        let manifest = PluginManifest(
            plugin_id: pluginId,
            description: nil,
            capabilities: .init(tools: nil, routes: nil, config: nil, web: nil, artifact_handler: nil),
            instructions: nil,
            name: "Echo",
            version: nil,
            license: nil,
            authors: nil,
            min_macos: nil,
            min_osaurus: nil,
            secrets: [.init(id: "api_key", label: "API Key")],
            docs: nil
        )
        let plugin = ExternalPlugin(
            handle: retain.toOpaque(), api: api, ctx: retain.toOpaque(), manifest: manifest,
            path: "/tmp/echo-\(pluginId)", abiVersion: 6)
        defer { Task { await plugin.shutdown() } }
        let tool = ExternalTool(
            plugin: plugin,
            spec: PluginManifest.ToolSpec(
                id: "echo", description: "Echo", parameters: nil, requirements: [], permission_policy: "auto"))

        let agent = UUID()
        let result = try await CredentialStore._withIsolatedStoreForTesting {
            PluginCredentials.save("shared-plugin-key", pluginId: pluginId, specId: "api_key", agentId: nil)
            PluginCredentials.save("agent-plugin-key", pluginId: pluginId, specId: "api_key", agentId: agent)
            return try await ChatExecutionContext.$currentAgentId.withValue(agent) {
                try await tool.execute(argumentsJSON: #"{"q":"hi"}"#)
            }
        }

        let sent = try #require(recorder.last)
        #expect(sent.contains("agent-plugin-key"), "the agent's own value reaches the plugin")
        #expect(!sent.contains("shared-plugin-key"))
        #expect(!result.contains("agent-plugin-key"), "an echoed key never reaches the model")
        #expect(result.contains("[REDACTED:api_key]"))
    }
}
