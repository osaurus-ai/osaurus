//
//  SandboxCredentials.swift
//  osaurus
//
//  What an agent's sandbox sees and saves. Values the agent (or the user,
//  through the secret prompt) saves are the agent's own credentials; reads
//  resolve agent then global, with not-yet-imported legacy agent secrets
//  (`AgentSecretsKeychain`) as the fallback.
//

import Foundation

enum SandboxCredentials {
    /// `key` as `agentId` sees it.
    static func value(_ key: String, agentId: UUID, store: CredentialStore = .current) -> String? {
        CredentialResolver.resolve(key, agentId: agentId, legacy: [legacyItem(key, agentId: agentId)], store: store)
    }

    static func legacyItem(_ key: String, agentId: UUID) -> CredentialResolver.LegacyItem {
        CredentialResolver.LegacyItem(AgentSecretsKeychain.legacyId(agentId: agentId, key: key)) {
            AgentSecretsKeychain.getSecret(id: key, agentId: agentId)
        }
    }

    static func exists(_ key: String, agentId: UUID, store: CredentialStore = .current) -> Bool {
        if CredentialResolver.source(key, agentId: agentId, store: store) != nil { return true }
        return value(key, agentId: agentId, store: store) != nil
    }

    /// Saves `value` as `agentId`'s own credential, readable when running code.
    @discardableResult
    static func save(
        _ value: String, key: String, agentId: UUID, description: String? = nil, store: CredentialStore = .current
    ) -> Bool {
        store.save(key, scope: .agent(agentId), value: value, description: description, origin: .sandboxPrompt)
            .isSuccess
    }

    /// Removes `agentId`'s own value; the shared one (if any) applies again.
    @discardableResult
    static func delete(_ key: String, agentId: UUID, store: CredentialStore = .current) -> CredentialWriteOutcome {
        store.delete(key, scope: .agent(agentId))
    }
}
