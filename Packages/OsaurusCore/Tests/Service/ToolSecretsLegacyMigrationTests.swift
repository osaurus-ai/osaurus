// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// Read-through migration of pre-agent-scoping plugin secrets stored as
/// `"{pluginId}.{key}"`. Users upgrading from builds before agent scoping
/// silently lost those credentials because nothing read the old accounts;
/// `getSecret` must now fall back, copy the value to the canonical
/// `"{agentId}.{pluginId}.{key}"` account, and never resurrect deleted keys.
@Suite("Tool secret legacy migration")
struct ToolSecretsLegacyMigrationTests {

    private let pluginId = "legacy.plugin.\(UUID().uuidString)"
    private let key = "api_key"

    private var legacyAccount: String { "\(pluginId).\(key)" }
    private var canonicalAccount: String {
        "\(Agent.defaultId.uuidString).\(pluginId).\(key)"
    }

    @Test("default-agent read falls back to the legacy account and migrates it")
    func defaultAgentReadMigrates() {
        defer { ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId) }
        ToolSecretsKeychain._testSeedRawAccount(legacyAccount, value: "sk-legacy")

        let value = ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId)

        #expect(value == "sk-legacy")
        #expect(ToolSecretsKeychain._testRawAccountValue(canonicalAccount) == "sk-legacy")
        #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == nil)

        // Subsequent reads hit the canonical account directly.
        #expect(
            ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId)
                == "sk-legacy")
    }

    @Test("canonical value wins over a stale legacy twin")
    func canonicalValueWins() {
        defer { ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId) }
        ToolSecretsKeychain._testSeedRawAccount(legacyAccount, value: "sk-stale")
        ToolSecretsKeychain.saveSecret("sk-current", id: key, for: pluginId, agentId: Agent.defaultId)

        let value = ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId)

        #expect(value == "sk-current")
        // The stale legacy twin is untouched by a canonical hit…
        #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == "sk-stale")

        // …but deleting the canonical secret removes both, so the fallback
        // can never resurrect a deleted key.
        ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId)
        #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == nil)
        #expect(ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId) == nil)
    }

    @Test("non-default agents do not read the legacy namespace directly")
    func nonDefaultAgentDoesNotMigrate() {
        let otherAgent = UUID()
        defer {
            ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId)
            ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: otherAgent)
        }
        ToolSecretsKeychain._testSeedRawAccount(legacyAccount, value: "sk-legacy")

        // Direct per-agent read: no legacy fallback for non-default agents.
        #expect(ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: otherAgent) == nil)
        #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == "sk-legacy")

        // The resolution policy still surfaces it: per-agent reads fall back
        // to Agent.defaultId, which triggers the migration.
        let resolved = ToolSecretsKeychain.resolvedSecret(
            id: key, for: pluginId, agentId: otherAgent)
        #expect(resolved == "sk-legacy")
        #expect(ToolSecretsKeychain._testRawAccountValue(canonicalAccount) == "sk-legacy")
        #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == nil)
    }

    @Test("hasSecret and required-secret checks see legacy values")
    func presenceChecksSeeLegacyValues() {
        defer { ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId) }
        ToolSecretsKeychain._testSeedRawAccount(legacyAccount, value: "sk-legacy")

        #expect(ToolSecretsKeychain.hasSecret(id: key, for: pluginId, agentId: Agent.defaultId))
        #expect(
            ToolSecretsKeychain.hasResolvedSecret(id: key, for: pluginId, agentId: Agent.defaultId))
    }
}
