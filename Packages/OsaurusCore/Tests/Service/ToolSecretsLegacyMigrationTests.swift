// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// Plugin config saved before agent scoping as `"{pluginId}.{key}"` is still
/// read for the Default agent, without being copied, rewritten, or deleted
/// by the read, so an older build pointed at the same Keychain keeps working.
@Suite("Tool secret pre-scoping fallback")
struct ToolSecretsLegacyMigrationTests {

    private let pluginId = "legacy.plugin.\(UUID().uuidString)"
    private let key = "api_key"

    private var legacyAccount: String { "\(pluginId).\(key)" }
    private var canonicalAccount: String {
        "\(Agent.defaultId.uuidString).\(pluginId).\(key)"
    }

    @Test("a Default-agent read falls back to the old account and leaves it alone")
    func defaultAgentReadIsReadOnly() {
        defer { ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId) }
        ToolSecretsKeychain._testSeedRawAccount(legacyAccount, value: "sk-legacy")

        #expect(ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId) == "sk-legacy")
        #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == "sk-legacy")
        #expect(ToolSecretsKeychain._testRawAccountValue(canonicalAccount) == nil)
    }

    @Test("the agent-scoped value wins; deleting it removes the old twin too")
    func canonicalValueWins() {
        defer { ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId) }
        ToolSecretsKeychain._testSeedRawAccount(legacyAccount, value: "sk-stale")
        ToolSecretsKeychain.saveSecret("sk-current", id: key, for: pluginId, agentId: Agent.defaultId)

        #expect(ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId) == "sk-current")
        #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == "sk-stale")

        ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId)
        #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == nil)
        #expect(ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: Agent.defaultId) == nil)
    }

    @Test("other agents see it through the Default-agent fallback, read-only")
    func otherAgentsResolveThroughDefault() {
        let otherAgent = UUID()
        defer {
            ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId)
            ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: otherAgent)
        }
        ToolSecretsKeychain._testSeedRawAccount(legacyAccount, value: "sk-legacy")

        #expect(ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: otherAgent) == nil)
        #expect(ToolSecretsKeychain.resolvedSecret(id: key, for: pluginId, agentId: otherAgent) == "sk-legacy")
        #expect(ToolSecretsKeychain._testRawAccountValue(legacyAccount) == "sk-legacy")
        #expect(ToolSecretsKeychain._testRawAccountValue(canonicalAccount) == nil)
    }

    @Test("presence checks see old values")
    func presenceChecksSeeLegacyValues() {
        defer { ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: Agent.defaultId) }
        ToolSecretsKeychain._testSeedRawAccount(legacyAccount, value: "sk-legacy")

        #expect(ToolSecretsKeychain.hasSecret(id: key, for: pluginId, agentId: Agent.defaultId))
    }
}
