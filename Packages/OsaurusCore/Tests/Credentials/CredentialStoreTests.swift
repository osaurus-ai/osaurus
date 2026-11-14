// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Credential store")
struct CredentialStoreTests {
    @Test("save, read and delete in each scope")
    func saveReadDelete() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            #expect(store.save("API_KEY", scope: .global, value: "g", origin: .user).isSuccess)
            #expect(store.save("API_KEY", scope: .agent(agent), value: "a", origin: .user).isSuccess)

            #expect(store.value("API_KEY", scope: .global) == "g")
            #expect(store.value("API_KEY", scope: .agent(agent)) == "a")
            #expect(store.hasValue("API_KEY", scope: .agent(UUID())) == false)

            store.delete("API_KEY", scope: .agent(agent))
            #expect(store.value("API_KEY", scope: .agent(agent)) == nil)
            #expect(store.value("API_KEY", scope: .global) == "g")
        }
    }

    @Test("invalid names and empty values are refused")
    func validation() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            #expect(store.save("1BAD", scope: .global, value: "x", origin: .user) == .invalidKey)
            #expect(store.save("HAS-DASH", scope: .global, value: "x", origin: .user) == .invalidKey)
            #expect(store.save("OK", scope: .global, value: "", origin: .user) == .emptyValue)
            #expect(store.save("crm_token", scope: .global, value: "x", origin: .user).isSuccess)
            #expect(store.allRecords().map(\.key) == ["crm_token"])
        }
    }

    @Test("multiline values are kept as typed, up to 64 KB")
    func multilineAndMaxLength() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let pem = "-----BEGIN KEY-----\nAAAA\nBBBB\n-----END KEY-----\n"
            #expect(store.save("PEM", scope: .global, value: pem, origin: .user).isSuccess)
            #expect(store.value("PEM", scope: .global) == pem)

            let tooLong = String(repeating: "x", count: CredentialStore.maxValueBytes + 1)
            #expect(store.save("BIG", scope: .global, value: tooLong, origin: .user) == .valueTooLong)
            #expect(store.record("BIG", scope: .global) == nil)
        }
    }

    @Test("variables keep their value in the index; secrets do not")
    func variablesLiveInIndex() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            store.save("LOG_LEVEL", scope: .global, value: "debug", kind: .variable, origin: .user)
            store.save("TOKEN", scope: .global, value: "sk-1", origin: .user)
            #expect(store.record("LOG_LEVEL", scope: .global)?.variableValue == "debug")
            #expect(store.record("TOKEN", scope: .global)?.variableValue == nil)
            #expect(store.value("LOG_LEVEL", scope: .global) == "debug")

            // Switching a secret to a variable moves the value into the index.
            store.save("TOKEN", scope: .global, value: "plain", kind: .variable, origin: .user)
            #expect(store.record("TOKEN", scope: .global)?.kind == .variable)
            #expect(store.value("TOKEN", scope: .global) == "plain")
        }
    }

    @Test("sandbox exposure defaults come from the origin")
    func exposureDefaults() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            store.save("USER_KEY", scope: .global, value: "x", origin: .user)
            store.save("PROMPTED", scope: .agent(agent), value: "x", origin: .sandboxPrompt)
            store.save("MCP_KEY", scope: .global, value: "x", origin: .mcp)
            store.save("PLUGIN_OVERRIDE", scope: .agent(agent), value: "x", origin: .plugin)
            store.save("WF_KEY", scope: .global, value: "x", origin: .workflow)

            #expect(store.record("USER_KEY", scope: .global)?.exposeToSandbox == true)
            #expect(store.record("PROMPTED", scope: .agent(agent))?.exposeToSandbox == true)
            #expect(store.record("MCP_KEY", scope: .global)?.exposeToSandbox == false)
            #expect(store.record("PLUGIN_OVERRIDE", scope: .agent(agent))?.exposeToSandbox == false)
            #expect(store.record("WF_KEY", scope: .global)?.exposeToSandbox == false)

            // Re-saving keeps metadata the caller did not pass.
            store.updateMetadata("MCP_KEY", scope: .global, exposeToSandbox: true)
            store.save("MCP_KEY", scope: .global, value: "y", origin: .mcp)
            #expect(store.record("MCP_KEY", scope: .global)?.exposeToSandbox == true)
        }
    }

    @Test("rename moves every scope and repoints bindings")
    func renameRepointsBindings() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            store.save("OLD", scope: .global, value: "g", origin: .user)
            store.save("OLD", scope: .agent(agent), value: "a", origin: .user)
            store.setBinding(slot: "plugin:x:key", key: "OLD")

            #expect(store.rename("OLD", to: "NEW").isSuccess)
            #expect(store.value("NEW", scope: .global) == "g")
            #expect(store.value("NEW", scope: .agent(agent)) == "a")
            #expect(store.hasValue("OLD", scope: .global) == false)
            #expect(store.boundKey(for: "plugin:x:key") == "NEW")

            store.save("TAKEN", scope: .global, value: "t", origin: .user)
            #expect(store.rename("NEW", to: "TAKEN") == .nameInUse)
            #expect(store.value("NEW", scope: .global) == "g")
        }
    }

    @Test("rename changes nothing when a value can't be read or a write fails")
    func renameFailures() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = CredentialStore(directory: dir, inMemorySecrets: true)
        first.save("OLD", scope: .global, value: "secret", origin: .user)
        first.setBinding(slot: "plugin:x:key", key: "OLD")

        // A new instance has the record but not the in-memory value.
        let second = CredentialStore(directory: dir, inMemorySecrets: true)
        guard case .keychainFailure = second.rename("OLD", to: "NEW") else {
            Issue.record("expected a read failure")
            return
        }
        #expect(second.hasValue("OLD", scope: .global))
        #expect(second.hasValue("NEW", scope: .global) == false)
        #expect(second.boundKey(for: "plugin:x:key") == "OLD")

        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            store.save("OLD", scope: .global, value: "plain", kind: .variable, origin: .user)
            store.save("OLD", scope: .agent(agent), value: "secret", origin: .user)
            store.failsSecretWritesForTesting = true
            guard case .keychainFailure = store.rename("OLD", to: "NEW") else {
                Issue.record("expected a write failure")
                return
            }
            store.failsSecretWritesForTesting = false
            #expect(store.records(in: .global).map(\.key) == ["OLD"])
            #expect(store.records(in: .agent(agent)).map(\.key) == ["OLD"])
        }
    }

    @Test("a refused Keychain delete keeps the key listed")
    func refusedDelete() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            store.save("TOKEN", scope: .global, value: "x", origin: .user)
            store.failsSecretWritesForTesting = true
            guard case .keychainFailure = store.delete("TOKEN", scope: .global) else {
                Issue.record("expected a delete failure")
                return
            }
            store.failsSecretWritesForTesting = false
            #expect(store.value("TOKEN", scope: .global) == "x")
            #expect(store.isDeleted("TOKEN", scope: .global) == false)
        }
    }

    @Test("old index files without tombstones still load")
    func oldIndexDecodes() throws {
        let json = #"{"version":1,"records":[],"importedLegacy":["svc/a"]}"#
        let index = try JSONDecoder().decode(CredentialIndexFile.self, from: Data(json.utf8))
        #expect(index.importedLegacy == ["svc/a"])
        #expect(index.deletedAccounts.isEmpty)
    }

    @Test("deleteAll(agentId:) only removes that agent's keys")
    func deleteAllForAgent() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let gone = UUID()
            let kept = UUID()
            store.save("K", scope: .global, value: "g", origin: .user)
            store.save("K", scope: .agent(gone), value: "x", origin: .user)
            store.save("ONLY", scope: .agent(gone), value: "x", origin: .user)
            store.save("K", scope: .agent(kept), value: "y", origin: .user)

            store.deleteAll(agentId: gone)
            #expect(store.records(in: .agent(gone)).isEmpty)
            #expect(store.value("K", scope: .agent(kept)) == "y")
            #expect(store.value("K", scope: .global) == "g")
        }
    }

    @Test("index and bindings persist across instances")
    func persistence() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = CredentialStore(directory: dir, inMemorySecrets: true)
        first.save("BASE_URL", scope: .global, value: "https://x", kind: .variable, origin: .user)
        first.setBinding(slot: "mcp:abc:env:URL", key: "BASE_URL")
        first.markLegacyImported(["ai.osaurus.tools/x"])

        let second = CredentialStore(directory: dir, inMemorySecrets: true)
        #expect(second.value("BASE_URL", scope: .global) == "https://x")
        #expect(second.boundKey(for: "mcp:abc:env:URL") == "BASE_URL")
        #expect(second.hasImportedLegacy("ai.osaurus.tools/x"))
    }
}

@Suite("Credential resolver")
struct CredentialResolverTests {
    @Test("the agent's value beats the global value")
    func agentBeatsGlobal() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            let other = UUID()
            store.save("TOKEN", scope: .global, value: "shared", origin: .user)
            store.save("TOKEN", scope: .agent(agent), value: "mine", origin: .user)

            #expect(CredentialResolver.value("TOKEN", agentId: agent) == "mine")
            #expect(CredentialResolver.value("TOKEN", agentId: other) == "shared")
            #expect(CredentialResolver.value("TOKEN", agentId: nil) == "shared")
            #expect(CredentialResolver.source("TOKEN", agentId: agent) == .agent)
            #expect(CredentialResolver.source("TOKEN", agentId: other) == .global)
        }
    }

    @Test("agent-only keys are invisible to other agents")
    func agentOnlyKey() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            store.save("PRIVATE", scope: .agent(agent), value: "p", origin: .user)
            #expect(CredentialResolver.value("PRIVATE", agentId: agent) == "p")
            #expect(CredentialResolver.value("PRIVATE", agentId: UUID()) == nil)
            #expect(CredentialResolver.value("PRIVATE", agentId: nil) == nil)
        }
    }

    @Test("sandbox env honors exposure and reserved names")
    func sandboxEnvironment() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            store.save("SHARED", scope: .global, value: "s", origin: .user)
            store.save("HIDDEN_FROM_CODE", scope: .global, value: "h", origin: .mcp)
            store.save("PATH", scope: .global, value: "/evil", origin: .user)
            store.save("MODE", scope: .agent(agent), value: "fast", kind: .variable, origin: .user)
            store.markMigrationCompleted()

            let env = CredentialResolver.sandboxEnvironment(agentId: agent)
            #expect(env["SHARED"] == "s")
            #expect(env["MODE"] == "fast")
            #expect(env["HIDDEN_FROM_CODE"] == nil)
            #expect(env["PATH"] == nil)
            #expect(CredentialResolver.availableKeys(agentId: agent) == ["MODE", "SHARED"])

            // Variables stay readable in tool output; secrets are scrubbed.
            let scrub = CredentialResolver.scrubValues(from: env, agentId: agent)
            #expect(scrub["SHARED"] == "s")
            #expect(scrub["MODE"] == nil)
        }
    }

    @Test("loader variables are reserved by prefix, in any case")
    func loaderPrefixesReserved() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            for name in ["LD_AUDIT", "DYLD_FRAMEWORK_PATH", "ld_preload", "NODE_PATH"] {
                store.save(name, scope: .global, value: "/evil", exposeToSandbox: true, origin: .user)
            }
            store.save("LDAP_URL", scope: .global, value: "ldap://x", exposeToSandbox: true, origin: .user)
            store.markMigrationCompleted()

            let env = CredentialResolver.sandboxEnvironment(agentId: nil)
            #expect(env.keys.sorted() == ["LDAP_URL"])
            #expect(CredentialResolver.isReservedEnvVar("DYLD_INSERT_LIBRARIES"))
            #expect(CredentialResolver.isReservedEnvVar("LDAP_URL") == false)
        }
    }

    @Test("an agent override replaces the shared value in the sandbox")
    func overrideInSandbox() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            store.save("API", scope: .global, value: "shared", origin: .user)
            store.save("API", scope: .agent(agent), value: "mine", origin: .user)
            store.markMigrationCompleted()
            #expect(CredentialResolver.sandboxEnvironment(agentId: agent)["API"] == "mine")
            #expect(CredentialResolver.sandboxEnvironment(agentId: UUID())["API"] == "shared")
        }
    }

    @Test("the bridge serves only keys marked for code use")
    func bridgeServesExposedKeysOnly() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            store.save("SHARED", scope: .global, value: "s", exposeToSandbox: true, origin: .user)
            store.save("PLUGIN_TOKEN", scope: .global, value: "p", exposeToSandbox: false, origin: .plugin)
            store.markMigrationCompleted()

            #expect(HostAPIBridgeServer.bridgeSecret("SHARED", agentId: agent) == "s")
            #expect(HostAPIBridgeServer.bridgeSecret("PLUGIN_TOKEN", agentId: agent) == nil)
            // The plugin that declares it still gets it in its own exec env.
            let env = CredentialResolver.sandboxPluginEnvironment(
                agentId: agent, pluginId: "probe", pluginName: "Probe", declared: ["PLUGIN_TOKEN"])
            #expect(env["PLUGIN_TOKEN"] == "p")
        }
    }

    @Test("perform runs off the main thread against the same store")
    @MainActor
    func performOffMain() async {
        let store = CredentialStore.makeIsolated()
        let result = await store.perform { inner in
            (onMain: Thread.isMainThread, sameStore: CredentialStore.current === inner && inner === store)
        }
        #expect(result.onMain == false)
        #expect(result.sameStore)
    }

    @Test("a run with no agent gets the shared keys only")
    func agentlessRunUsesSharedKeys() async throws {
        try await CredentialStore.$taskLocalStore.withValue(CredentialStore.makeIsolated()) {
            let store = CredentialStore.current
            let registering = UUID()
            let owner = UUID()
            store.save("API", scope: .global, value: "shared", origin: .user)
            store.save("API", scope: .agent(registering), value: "registering", origin: .user)
            store.save("API", scope: .agent(owner), value: "owner", origin: .user)
            store.save("ONLY_MINE", scope: .agent(registering), value: "private", origin: .user)
            store.markMigrationCompleted()

            #expect(CredentialResolver.credentialAgent(fallback: registering) == registering)

            try await ChatExecutionContext.$usesSharedKeysOnly.withValue(true) {
                let agent = CredentialResolver.credentialAgent(fallback: registering)
                #expect(agent == nil)
                let env = CredentialResolver.sandboxEnvironment(agentId: agent)
                #expect(env["API"] == "shared")
                #expect(env["ONLY_MINE"] == nil)

                let check = try await SandboxSecretCheckTool(agentId: registering.uuidString)
                    .execute(argumentsJSON: #"{"key":"ONLY_MINE"}"#)
                #expect(check.contains(#""exists":false"#))

                let set = try await SandboxSecretSetTool(agentId: registering.uuidString)
                    .execute(argumentsJSON: #"{"key":"NEW","description":"d","instructions":"i","value":"v"}"#)
                #expect(set.contains("no agent"))
                #expect(store.hasValue("NEW", scope: .agent(registering)) == false)
            }

            // An automation with an owner agent runs with that agent's keys.
            await ChatExecutionContext.$currentAgentId.withValue(owner) {
                await ChatExecutionContext.$usesSharedKeysOnly.withValue(false) {
                    let agent = CredentialResolver.credentialAgent(fallback: registering)
                    #expect(CredentialResolver.sandboxEnvironment(agentId: agent)["API"] == "owner")
                }
            }
        }
    }

    @Test("slots resolve through bindings, then the legacy fallback")
    func slotResolution() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let slot = CredentialSlot.plugin(pluginId: "osaurus.weather", pluginName: "Weather", specId: "api_key")
            #expect(slot.defaultKey == "WEATHER_API_KEY")

            let legacy = [CredentialResolver.LegacyItem("svc/acct") { "legacy" }]
            #expect(CredentialResolver.resolve(slot, agentId: nil, legacy: legacy) == "legacy")
            store.save("WEATHER_API_KEY", scope: .global, value: "new", origin: .plugin)
            #expect(CredentialResolver.resolve(slot, agentId: nil, legacy: legacy) == "new")

            store.save("OTHER", scope: .global, value: "bound", origin: .user)
            store.setBinding(slot: slot.id, key: "OTHER", defaultKey: slot.defaultKey)
            #expect(CredentialResolver.resolve(slot, agentId: nil) == "bound")
        }
    }

    @Test("legacy items stop serving once imported; later items still apply")
    func legacyItemsHonorImports() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let legacy = [
                CredentialResolver.LegacyItem("svc/first") { "old" },
                CredentialResolver.LegacyItem("svc/second") { "older" },
            ]
            #expect(CredentialResolver.resolve("KEY", agentId: nil, legacy: legacy) == "old")
            store.markLegacyImported(["svc/first"])
            #expect(CredentialResolver.resolve("KEY", agentId: nil, legacy: legacy) == "older")
            store.markLegacyImported(["svc/second"])
            #expect(CredentialResolver.resolve("KEY", agentId: nil, legacy: legacy) == nil)
        }
    }
}

@Suite("Credential bindings")
struct CredentialBindingTests {
    @Test("key validation")
    func keyValidation() {
        #expect(CredentialKeys.isValid("GITHUB_TOKEN"))
        #expect(CredentialKeys.isValid("_private"))
        #expect(CredentialKeys.isValid("crm_token"))
        #expect(!CredentialKeys.isValid(""))
        #expect(!CredentialKeys.isValid("9LIVES"))
        #expect(!CredentialKeys.isValid("X-Api-Key"))
        #expect(!CredentialKeys.isValid(String(repeating: "A", count: 129)))
        #expect(CredentialKeys.isConventional("GITHUB_TOKEN"))
        #expect(!CredentialKeys.isConventional("crm_token"))
    }

    @Test("default keys for each consumer")
    func defaultKeys() {
        let id = UUID()
        #expect(CredentialSlot.mcpEnv(providerId: id, providerName: "GitHub", name: "GITHUB_TOKEN").defaultKey == "GITHUB_TOKEN")
        #expect(CredentialSlot.mcpEnv(providerId: id, providerName: "My Server", name: "api_key").defaultKey == "MY_SERVER_API_KEY")
        #expect(CredentialSlot.mcpHeader(providerId: id, providerName: "Linear", header: "X-Api-Key").defaultKey == "LINEAR_X_API_KEY")
        #expect(CredentialSlot.mcpToken(providerId: id, providerName: "Linear").defaultKey == "LINEAR_TOKEN")
        #expect(CredentialSlot.plugin(pluginId: "osaurus.tavily", pluginName: "Tavily", specId: "TAVILY_API_KEY").defaultKey == "TAVILY_API_KEY")
        #expect(CredentialSlot.plugin(pluginId: "com.acme.weather-tools", pluginName: "W", specId: "key").defaultKey == "WEATHER_TOOLS_KEY")
        #expect(ChannelCredentialSlots.slackBotToken.defaultKey == "SLACK_BOT_TOKEN")
        #expect(ChannelCredentialSlots.slackWorkspace("bot_token", teamId: "T123").defaultKey == "SLACK_BOT_TOKEN_T123")
        #expect(CredentialKeys.prefixed("GitHub", "GITHUB_TOKEN") == "GITHUB_TOKEN")
    }

    @Test("a different value under the same key gets its own key")
    func collisionSeparates() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let slot = CredentialSlot.mcpEnv(providerId: UUID(), providerName: "Work", name: "GITHUB_TOKEN")
            store.save("GITHUB_TOKEN", scope: .global, value: "personal", origin: .user)

            #expect(store.nonConflictingKey(for: slot, value: "personal", owner: "Work") == "GITHUB_TOKEN")
            let (outcome, key) = store.save(
                "work-token", for: slot, owner: "Work", origin: .mcp, separateOnConflict: true)
            #expect(outcome.isSuccess)
            #expect(key == "WORK_GITHUB_TOKEN")
            #expect(store.value("GITHUB_TOKEN", scope: .global) == "personal")
            #expect(slot.effectiveKey(in: store) == "WORK_GITHUB_TOKEN")
        }
    }

    @Test("without separation a save shares the key")
    func sharedSave() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let slot = CredentialSlot.mcpEnv(providerId: UUID(), providerName: "Work", name: "GITHUB_TOKEN")
            store.save("GITHUB_TOKEN", scope: .global, value: "old", origin: .user)
            let (_, key) = store.save("new", for: slot, owner: "Work", origin: .mcp)
            #expect(key == "GITHUB_TOKEN")
            #expect(store.value("GITHUB_TOKEN", scope: .global) == "new")
        }
    }

    @Test("pinned saves survive a consumer rename")
    func pinnedBinding() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let id = UUID()
            let before = CredentialSlot.mcpToken(providerId: id, providerName: "Linear")
            store.save("tok", for: before, owner: "Linear", origin: .mcp, pin: true)
            let after = CredentialSlot.mcpToken(providerId: id, providerName: "Linear Work")
            #expect(after.defaultKey == "LINEAR_WORK_TOKEN")
            #expect(after.effectiveKey(in: store) == "LINEAR_TOKEN")
            #expect(CredentialResolver.resolve(after, agentId: nil) == "tok")
        }
    }
}
