// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// The import into Keys is copy-only: legacy Keychain items stay exactly as
/// they were, re-runs never overwrite edits made in the new store, and
/// anything not imported yet keeps resolving through the legacy fallback.
@Suite("Credential migration")
struct CredentialMigrationTests {
    private func plugin(_ id: String, specs: [String]) -> CredentialMigration.Inputs.Plugin {
        .init(id: id, name: "Test Plugin", secretIds: specs)
    }

    @Test("agent secrets are copied as that agent's keys and the legacy item is untouched")
    func agentSecretsCopied() {
        AgentSecretsKeychain._withInMemoryStoreForTesting {
            CredentialStore._withIsolatedStoreForTesting {
                let agent = UUID()
                AgentSecretsKeychain._testSeedSecret("sk-agent", id: "OPENAI_KEY", agentId: agent)

                var inputs = CredentialMigration.Inputs()
                inputs.agentIds = [agent]
                CredentialMigration.run(inputs: inputs)

                let store = CredentialStore.current
                #expect(store.value("OPENAI_KEY", scope: .agent(agent)) == "sk-agent")
                #expect(store.record("OPENAI_KEY", scope: .agent(agent))?.exposeToSandbox == true)
                #expect(store.hasImportedLegacy(AgentSecretsKeychain.legacyId(agentId: agent, key: "OPENAI_KEY")))
                #expect(AgentSecretsKeychain.getSecret(id: "OPENAI_KEY", agentId: agent) == "sk-agent")
                #expect(store.migrationCompletedAt != nil)
            }
        }
    }

    @Test("a locked Keychain listing does not complete the import; a later pass does")
    func lockedListingDoesNotComplete() {
        AgentSecretsKeychain._withInMemoryStoreForTesting {
            CredentialStore._withIsolatedStoreForTesting {
                let agent = UUID()
                AgentSecretsKeychain._testSeedSecret("sk", id: "TOKEN", agentId: agent)
                var inputs = CredentialMigration.Inputs()
                inputs.agentIds = [agent]
                let store = CredentialStore.current

                let locked = CredentialMigration.run(
                    inputs: inputs, agentListing: { ([], false) })
                #expect(locked.listingIncomplete)
                #expect(store.migrationCompletedAt == nil)
                #expect(CredentialMigration.needsAnotherPass)
                #expect(CredentialResolver.sandboxEnvironment(agentId: agent)["TOKEN"] == "sk")

                let unlocked = CredentialMigration.run(inputs: inputs)
                #expect(unlocked.listingIncomplete == false)
                #expect(store.migrationCompletedAt != nil)
                #expect(store.value("TOKEN", scope: .agent(agent)) == "sk")
            }
        }
    }

    @Test("a key deleted on the Keys page before import stays deleted")
    func deleteBeforeImportSticks() {
        AgentSecretsKeychain._withInMemoryStoreForTesting {
            CredentialStore._withIsolatedStoreForTesting {
                let agent = UUID()
                AgentSecretsKeychain._testSeedSecret("sk-old", id: "TOKEN", agentId: agent)
                let store = CredentialStore.current
                #expect(CredentialResolver.sandboxEnvironment(agentId: agent)["TOKEN"] == "sk-old")

                #expect(store.delete("TOKEN", scope: .agent(agent)).isSuccess)
                #expect(CredentialResolver.sandboxEnvironment(agentId: agent)["TOKEN"] == nil)
                #expect(SandboxCredentials.value("TOKEN", agentId: agent) == nil)

                var inputs = CredentialMigration.Inputs()
                inputs.agentIds = [agent]
                CredentialMigration.run(inputs: inputs)
                #expect(store.hasValue("TOKEN", scope: .agent(agent)) == false)
                #expect(CredentialResolver.sandboxEnvironment(agentId: agent)["TOKEN"] == nil)
                // Copy-only: the legacy item itself is never touched.
                #expect(AgentSecretsKeychain.getSecret(id: "TOKEN", agentId: agent) == "sk-old")

                // Saving the key again clears the tombstone.
                store.save("TOKEN", scope: .agent(agent), value: "sk-new", origin: .user)
                #expect(store.isDeleted("TOKEN", scope: .agent(agent)) == false)
                #expect(CredentialResolver.sandboxEnvironment(agentId: agent)["TOKEN"] == "sk-new")
            }
        }
    }

    @Test("a deleted shared plugin key is not served or imported from the old store")
    func deletedPluginKeyStaysDeleted() {
        CredentialStore._withIsolatedStoreForTesting {
            let pluginId = "test.tomb.\(UUID().uuidString.prefix(8).lowercased())"
            let account = "\(Agent.defaultId.uuidString).\(pluginId).api_key"
            ToolSecretsKeychain._testSeedRawAccount(account, value: "legacy")
            defer { ToolSecretsKeychain.deleteAllSecrets(for: pluginId) }
            let slot = PluginCredentials.slot(pluginId: pluginId, pluginName: "Test Plugin", specId: "api_key")
            #expect(PluginCredentials.value(pluginId: pluginId, specId: "api_key", agentId: nil) == "legacy")

            let store = CredentialStore.current
            store.delete(slot.effectiveKey(), scope: .global)
            #expect(PluginCredentials.value(pluginId: pluginId, specId: "api_key", agentId: nil) == nil)
            #expect(PluginCredentials.isSatisfied(pluginId: pluginId, specId: "api_key", agentId: nil) == false)

            var inputs = CredentialMigration.Inputs()
            inputs.agentIds = [Agent.defaultId]
            inputs.plugins = [plugin(pluginId, specs: ["api_key"])]
            CredentialMigration.run(inputs: inputs)
            #expect(store.hasValue(slot.effectiveKey(), scope: .global) == false)
            #expect(ToolSecretsKeychain._testRawAccountValue(account) == "legacy")
        }
    }

    @Test("a plugin's legacy values sit under the new store and stop after migration")
    func pluginEnvLegacyOrder() {
        CredentialStore._withIsolatedStoreForTesting {
            let pluginId = "test.order.\(UUID().uuidString.prefix(8).lowercased())"
            ToolSecretsKeychain._testSeedRawAccount("\(Agent.defaultId.uuidString).\(pluginId).SHARED", value: "legacy")
            ToolSecretsKeychain._testSeedRawAccount(
                "\(Agent.defaultId.uuidString).\(pluginId).ONLY_LEGACY", value: "old")
            defer { ToolSecretsKeychain.deleteAllSecrets(for: pluginId) }
            let store = CredentialStore.current
            store.save("SHARED", scope: .global, value: "new", exposeToSandbox: true, origin: .user)

            func env() -> [String: String] {
                CredentialResolver.sandboxPluginEnvironment(
                    agentId: nil, pluginId: pluginId, pluginName: "Test Plugin", declared: [])
            }
            #expect(env()["SHARED"] == "new")
            #expect(env()["ONLY_LEGACY"] == "old")
            store.markMigrationCompleted()
            #expect(env()["SHARED"] == "new")
            #expect(env()["ONLY_LEGACY"] == nil)
        }
    }

    @Test("secrets of deleted agents are skipped")
    func orphanAgentsSkipped() {
        AgentSecretsKeychain._withInMemoryStoreForTesting {
            CredentialStore._withIsolatedStoreForTesting {
                let live = UUID()
                let deleted = UUID()
                AgentSecretsKeychain._testSeedSecret("x", id: "KEY", agentId: deleted)
                var inputs = CredentialMigration.Inputs()
                inputs.agentIds = [live]
                CredentialMigration.run(inputs: inputs)
                #expect(CredentialStore.current.records(in: .agent(deleted)).isEmpty)
                #expect(AgentSecretsKeychain.getSecret(id: "KEY", agentId: deleted) == "x")
            }
        }
    }

    @Test("a re-run never overwrites a value edited in the new store")
    func rerunKeepsEdits() {
        AgentSecretsKeychain._withInMemoryStoreForTesting {
            CredentialStore._withIsolatedStoreForTesting {
                let agent = UUID()
                AgentSecretsKeychain._testSeedSecret("old", id: "TOKEN", agentId: agent)
                var inputs = CredentialMigration.Inputs()
                inputs.agentIds = [agent]
                CredentialMigration.run(inputs: inputs)

                let store = CredentialStore.current
                store.save("TOKEN", scope: .agent(agent), value: "edited", origin: .user)
                CredentialMigration.run(inputs: inputs)
                #expect(store.value("TOKEN", scope: .agent(agent)) == "edited")

                // A key deleted after import is not resurrected either.
                store.delete("TOKEN", scope: .agent(agent))
                CredentialMigration.run(inputs: inputs)
                #expect(store.hasValue("TOKEN", scope: .agent(agent)) == false)
                #expect(AgentSecretsKeychain.getSecret(id: "TOKEN", agentId: agent) == "old")
            }
        }
    }

    @Test("Default-agent plugin secrets become global; other agents become overrides")
    func pluginSecrets() {
        CredentialStore._withIsolatedStoreForTesting {
            let pluginId = "test.migrate.\(UUID().uuidString.prefix(8).lowercased())"
            let agent = UUID()
            let globalAccount = "\(Agent.defaultId.uuidString).\(pluginId).api_key"
            let agentAccount = "\(agent.uuidString).\(pluginId).api_key"
            ToolSecretsKeychain._testSeedRawAccount(globalAccount, value: "shared")
            ToolSecretsKeychain._testSeedRawAccount(agentAccount, value: "mine")
            defer {
                ToolSecretsKeychain.deleteAllSecrets(for: pluginId)
            }

            var inputs = CredentialMigration.Inputs()
            inputs.agentIds = [agent, Agent.defaultId]
            inputs.plugins = [plugin(pluginId, specs: ["api_key"])]
            CredentialMigration.run(inputs: inputs)

            let slot = PluginCredentials.slot(pluginId: pluginId, pluginName: "Test Plugin", specId: "api_key")
            let key = slot.effectiveKey()
            let store = CredentialStore.current
            #expect(store.value(key, scope: .global) == "shared")
            #expect(store.record(key, scope: .global)?.exposeToSandbox == false)
            #expect(store.value(key, scope: .agent(agent)) == "mine")
            #expect(CredentialResolver.resolve(slot, agentId: agent) == "mine")
            #expect(CredentialResolver.resolve(slot, agentId: UUID()) == "shared")

            // Legacy items are byte-identical after the import.
            #expect(ToolSecretsKeychain._testRawAccountValue(globalAccount) == "shared")
            #expect(ToolSecretsKeychain._testRawAccountValue(agentAccount) == "mine")
        }
    }

    @Test("pre-agent-scoping plugin items are read without being rewritten")
    func preScopingItemsUntouched() {
        CredentialStore._withIsolatedStoreForTesting {
            let pluginId = "test.prescope.\(UUID().uuidString.prefix(8).lowercased())"
            let legacyAccount = "\(pluginId).api_key"
            let canonical = "\(Agent.defaultId.uuidString).\(pluginId).api_key"
            ToolSecretsKeychain._testSeedRawAccount(legacyAccount, value: "very-old")
            defer { ToolSecretsKeychain.deleteAllSecrets(for: pluginId) }

            // The legacy fallback serves it before the import runs…
            #expect(PluginCredentials.value(pluginId: pluginId, specId: "api_key", agentId: Agent.defaultId) == "very-old")
            var inputs = CredentialMigration.Inputs()
            inputs.plugins = [plugin(pluginId, specs: ["api_key"])]
            CredentialMigration.run(inputs: inputs)

            let slot = PluginCredentials.slot(pluginId: pluginId, pluginName: "Test Plugin", specId: "api_key")
            #expect(CredentialStore.current.value(slot.effectiveKey(), scope: .global) == "very-old")
            // …and nothing moved or was deleted.
            #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == "very-old")
            #expect(ToolSecretsKeychain._testRawAccountValue(canonical) == nil)
        }
    }

    @Test("colliding values get their own key and a binding")
    func collisionsSeparate() {
        CredentialStore._withIsolatedStoreForTesting {
            let pluginA = "test.a\(UUID().uuidString.prefix(6).lowercased())"
            let pluginB = "test.b\(UUID().uuidString.prefix(6).lowercased())"
            ToolSecretsKeychain._testSeedRawAccount("\(Agent.defaultId.uuidString).\(pluginA).SHARED_TOKEN", value: "one")
            ToolSecretsKeychain._testSeedRawAccount("\(Agent.defaultId.uuidString).\(pluginB).SHARED_TOKEN", value: "two")
            defer {
                ToolSecretsKeychain.deleteAllSecrets(for: pluginA)
                ToolSecretsKeychain.deleteAllSecrets(for: pluginB)
            }

            var inputs = CredentialMigration.Inputs()
            inputs.plugins = [plugin(pluginA, specs: ["SHARED_TOKEN"]), plugin(pluginB, specs: ["SHARED_TOKEN"])]
            CredentialMigration.run(inputs: inputs)

            let slotA = PluginCredentials.slot(pluginId: pluginA, pluginName: "A", specId: "SHARED_TOKEN")
            let slotB = PluginCredentials.slot(pluginId: pluginB, pluginName: "B", specId: "SHARED_TOKEN")
            #expect(CredentialResolver.resolve(slotA, agentId: nil) == "one")
            #expect(CredentialResolver.resolve(slotB, agentId: nil) == "two")
            #expect(slotA.effectiveKey() != slotB.effectiveKey())
        }
    }

    @Test("workflow secrets become global keys the workflow resolves")
    func workflowSecrets() {
        CredentialStore._withIsolatedStoreForTesting {
            let scope = UUID()
            let account = WorkflowSecretsKeychain.secretAccount(scope: scope, key: "CLIO_API_KEY")
            WorkflowSecretsKeychain.save("clio", account: account)
            defer { WorkflowSecretsKeychain.delete(account: account) }

            var inputs = CredentialMigration.Inputs()
            inputs.workflows = [.init(scope: scope, name: "Clio Sync", keys: ["CLIO_API_KEY"])]
            CredentialMigration.run(inputs: inputs)

            #expect(CredentialStore.current.value("CLIO_API_KEY", scope: .global) == "clio")
            #expect(WorkflowCredentials.value(scope: scope, key: "CLIO_API_KEY", agentId: nil) == "clio")
            #expect(WorkflowSecretsKeychain.read(account: account) == "clio")
        }
    }

    @Test("unimported items keep resolving through the fallback")
    func fallbackBeforeImport() {
        CredentialStore._withIsolatedStoreForTesting {
            let scope = UUID()
            let account = WorkflowSecretsKeychain.secretAccount(scope: scope, key: "LATE_KEY")
            WorkflowSecretsKeychain.save("late", account: account)
            defer { WorkflowSecretsKeychain.delete(account: account) }
            #expect(WorkflowCredentials.value(scope: scope, key: "LATE_KEY", agentId: nil) == "late")
            #expect(CredentialStore.current.hasValue("LATE_KEY", scope: .global) == false)
        }
    }

    @Test("old stores are no longer read once a migration pass completes")
    func legacyReadsStopAfterMigration() {
        CredentialStore._withIsolatedStoreForTesting {
            let scope = UUID()
            let account = WorkflowSecretsKeychain.secretAccount(scope: scope, key: "GATED_KEY")
            WorkflowSecretsKeychain.save("old", account: account)
            defer { WorkflowSecretsKeychain.delete(account: account) }
            CredentialStore.current.markMigrationCompleted()

            #expect(WorkflowCredentials.value(scope: scope, key: "GATED_KEY", agentId: nil) == nil)
            #expect(WorkflowSecretsKeychain.read(account: account) == "old", "the old item is untouched")
        }
    }

    @Test("a failed copy keeps the old stores readable and the pass incomplete")
    func failedImportKeepsFallback() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let scope = UUID()
            let account = WorkflowSecretsKeychain.secretAccount(scope: scope, key: "FAILING_KEY")
            WorkflowSecretsKeychain.save("old", account: account)
            defer { WorkflowSecretsKeychain.delete(account: account) }
            var inputs = CredentialMigration.Inputs()
            inputs.workflows = [.init(scope: scope, name: "Flow", keys: ["FAILING_KEY"])]

            store.failsSecretWritesForTesting = true
            let report = CredentialMigration.run(
                inputs: inputs, toolListing: { ([], true) }, agentListing: { ([], true) })
            store.failsSecretWritesForTesting = false

            #expect(report.failed == 1)
            #expect(store.migrationCompletedAt == nil)
            #expect(WorkflowCredentials.value(scope: scope, key: "FAILING_KEY", agentId: nil) == "old")
        }
    }

    @Test("setup checks find an old value in the background instead of reading it inline")
    func setupCheckFindsLegacyInBackground() async throws {
        LegacyPresenceCache.shared._resetForTesting()
        let store = CredentialStore.makeIsolated()
        let scope = UUID()
        let account = WorkflowSecretsKeychain.secretAccount(scope: scope, key: "BG_KEY")
        WorkflowSecretsKeychain.save("old", account: account)
        defer { WorkflowSecretsKeychain.delete(account: account) }

        #expect(WorkflowCredentials.isSetUp(scope: scope, key: "BG_KEY", store: store) == false)
        var found = false
        for _ in 0..<100 where !found {
            try await Task.sleep(for: .milliseconds(20))
            found = WorkflowCredentials.isSetUp(scope: scope, key: "BG_KEY", store: store)
        }
        #expect(found)
    }
}
