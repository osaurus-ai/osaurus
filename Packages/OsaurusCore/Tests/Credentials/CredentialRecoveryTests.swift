// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// An unreadable `index.json` or `bindings.json` is backed up, never
/// overwritten blindly, and the secret records come back from the Keychain
/// so an import pass can't write old values over them.
@Suite("Credential store recovery")
struct CredentialRecoveryTests {
    private func makeStore() -> (CredentialStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-credentials-\(UUID().uuidString)", isDirectory: true)
        return (CredentialStore(directory: dir, inMemorySecrets: true), dir)
    }

    private func backups(in dir: URL, prefix: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("\(prefix).corrupt-") }.map { dir.appendingPathComponent($0) }
    }

    @Test("a corrupt index is backed up and rebuilt from stored secrets")
    func corruptIndexRebuilt() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = UUID()
        store.save("API_KEY", scope: .global, value: "g", origin: .user)
        store.save("API_KEY", scope: .agent(agent), value: "a", origin: .user)
        store.save("LOG_LEVEL", scope: .global, value: "debug", kind: .variable, origin: .user)

        let garbage = Data("{ not json".utf8)
        try garbage.write(to: dir.appendingPathComponent("index.json"))
        store._reloadFromDiskForTesting()

        #expect(store.value("API_KEY", scope: .global) == "g")
        #expect(store.value("API_KEY", scope: .agent(agent)) == "a")
        #expect(store.record("LOG_LEVEL", scope: .global) == nil, "variables live only in the backup")

        let saved = backups(in: dir, prefix: "index")
        #expect(saved.count == 1)
        #expect(try Data(contentsOf: #require(saved.first)) == garbage)
        #expect(store.loadIssues().contains { if case .indexRebuilt(_, 2) = $0 { true } else { false } })

        // The rebuilt index was written and reads back cleanly.
        store._reloadFromDiskForTesting()
        #expect(store.hasValue("API_KEY", scope: .agent(agent)))
        #expect(store.loadIssues().isEmpty)
    }

    @Test("a corrupt bindings file is backed up and reset")
    func corruptBindingsReset() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.setBinding(slot: "mcp:x:env:TOKEN", key: "GH")
        try Data("[]".utf8).write(to: dir.appendingPathComponent("bindings.json"))
        store._reloadFromDiskForTesting()

        #expect(store.boundKey(for: "mcp:x:env:TOKEN") == nil)
        #expect(backups(in: dir, prefix: "bindings").count == 1)
        #expect(store.loadIssues().contains { if case .bindingsReset = $0 { true } else { false } })
    }

    @Test("an import after a lost index never writes over a stored secret")
    func importAfterLostIndexKeepsValue() {
        AgentSecretsKeychain._withInMemoryStoreForTesting {
            let (store, dir) = makeStore()
            defer { try? FileManager.default.removeItem(at: dir) }
            CredentialStore.$taskLocalStore.withValue(store) {
                let agent = UUID()
                AgentSecretsKeychain._testSeedSecret("old", id: "TOKEN", agentId: agent)
                var inputs = CredentialMigration.Inputs()
                inputs.agentIds = [agent]
                CredentialMigration.run(inputs: inputs)
                store.save("TOKEN", scope: .agent(agent), value: "edited", origin: .user)

                // The index disappears entirely (not corrupt: missing).
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("index.json"))
                store._reloadFromDiskForTesting()
                #expect(store.hasValue("TOKEN", scope: .agent(agent)) == false)

                CredentialMigration.run(inputs: inputs)
                #expect(store.value("TOKEN", scope: .agent(agent)) == "edited")
                #expect(AgentSecretsKeychain.getSecret(id: "TOKEN", agentId: agent) == "old")
            }
        }
    }

    @Test("account names parse back to scope and key")
    func parseAccount() {
        let agent = UUID()
        let global = CredentialScope.parse(account: "global/API_KEY")
        #expect(global?.0 == .global)
        #expect(global?.1 == "API_KEY")
        let parsed = CredentialScope.parse(account: "agent/\(agent.uuidString.lowercased())/TOKEN")
        #expect(parsed?.0 == .agent(agent))
        #expect(parsed?.1 == "TOKEN")
        #expect(CredentialScope.parse(account: "global/bad-name") == nil)
        #expect(CredentialScope.parse(account: "agent/not-a-uuid/TOKEN") == nil)
        #expect(CredentialScope.parse(account: "other/KEY") == nil)
    }
}
