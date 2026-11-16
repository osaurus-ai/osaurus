//
//  WorkflowCredentials.swift
//  osaurus
//
//  Workflow install-time secrets (a template's declared keys, e.g.
//  `CLIO_API_KEY`) are credentials in the unified store, shared by default
//  and overridable per agent. A workflow's slot is
//  `workflow:<scope>:<KEY>`; the scope is the installed workflow (or the
//  template / draft it is being set up from). Values saved before this
//  store existed live under `secret:<scope>:<KEY>` in
//  `WorkflowSecretsKeychain` and are read only as a fallback.
//

import Foundation

enum WorkflowCredentials {
    static func slot(scope: UUID, key: String, workflowName: String = "Workflow") -> CredentialSlot {
        .workflow(installId: scope, workflowName: workflowName, key: key)
    }

    static func legacyId(scope: UUID, key: String) -> String {
        "\(OsaurusKeychainServices.workflowSecrets)/\(WorkflowSecretsKeychain.secretAccount(scope: scope, key: key))"
    }

    /// `secret:<scope>:<KEY>` → (scope, KEY).
    static func parse(account: String) -> (scope: UUID, key: String)? {
        let parts = account.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "secret", let scope = UUID(uuidString: String(parts[1])) else {
            return nil
        }
        return (scope, String(parts[2]))
    }

    static func legacyItem(scope: UUID, key: String) -> CredentialResolver.LegacyItem {
        CredentialResolver.LegacyItem(legacyId(scope: scope, key: key)) {
            WorkflowSecretsKeychain.read(account: WorkflowSecretsKeychain.secretAccount(scope: scope, key: key))
        }
    }

    static func value(scope: UUID, key: String, agentId: UUID?, store: CredentialStore = .current) -> String? {
        CredentialResolver.resolve(
            slot(scope: scope, key: key), agentId: agentId, legacy: [legacyItem(scope: scope, key: key)], store: store)
    }

    static func hasValue(scope: UUID, key: String, agentId: UUID? = nil, store: CredentialStore = .current) -> Bool {
        CredentialResolver.isSatisfied(
            slot(scope: scope, key: key), agentId: agentId, legacy: [legacyItem(scope: scope, key: key)], store: store)
    }

    /// Presence for setup checks, which run while views render: the index,
    /// plus a legacy answer looked up in the background. With `agentId`,
    /// that agent's own value counts too, as it does when the agent runs it.
    static func isSetUp(scope: UUID, key: String, agentId: UUID? = nil, store: CredentialStore = .current) -> Bool {
        let slot = slot(scope: scope, key: key)
        let legacy = legacyItem(scope: scope, key: key)
        return CredentialResolver.isSatisfied(slot, agentId: agentId, legacyId: legacy.id, store: store) {
            LegacyPresenceCache.shared.isPresent(legacy.id, key: slot.effectiveKey(in: store), store: store) {
                !(legacy.read() ?? "").isEmpty
            }
        }
    }

    /// The plain keys `workflow` declares with no value for `agentId` (its
    /// own, else the shared one; nil: shared only). Sign-ins and
    /// connection-bound keys are setup, not Keys. Runs by that caller stop
    /// on them; Vault → Missing Keys lists the shared ones.
    @MainActor
    static func missingKeys(
        _ workflow: InstalledWorkflow, agentId: UUID? = nil, store: CredentialStore = .current
    ) -> [String] {
        workflow.template.requirements.secrets.compactMap { secret in
            guard secret.oauth2 == nil else { return nil }
            if let bound = workflow.bindings.secrets[secret.key] {
                if WorkflowSecretsKeychain.isConnectionAccount(bound) { return nil }
                guard WorkflowSecretsKeychain.isSecretAccount(bound, scope: workflow.id, key: secret.key) else {
                    return nil
                }
            }
            return isSetUp(scope: workflow.id, key: secret.key, agentId: agentId, store: store) ? nil : secret.key
        }
    }

    /// Agents with their own value for `scope`'s `key`, which fills it when
    /// they run the workflow even though no shared value exists.
    static func agentsWithOwnValue(scope: UUID, key: String, store: CredentialStore = .current) -> [UUID] {
        let effective = slot(scope: scope, key: key).effectiveKey(in: store)
        return store.allRecords().compactMap { record in
            guard record.key == effective, case .agent(let id) = record.scope else { return nil }
            return id
        }
    }

    /// Presence behind a `secret:` account; other accounts (answers,
    /// connections) are answered by the workflow Keychain directly.
    static func hasValue(account: String) -> Bool {
        guard let (scope, key) = parse(account: account) else {
            return WorkflowSecretsKeychain.hasValue(account: account)
        }
        return hasValue(scope: scope, key: key)
    }

    /// `isSetUp` behind a `secret:` account.
    static func isSetUp(account: String, agentId: UUID? = nil) -> Bool {
        guard let (scope, key) = parse(account: account) else {
            return WorkflowSecretsKeychain.hasValue(account: account)
        }
        return isSetUp(scope: scope, key: key, agentId: agentId)
    }

    /// Saves for all agents under the slot's key.
    @discardableResult
    static func save(_ value: String, scope: UUID, key: String, store: CredentialStore = .current) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let slot = slot(scope: scope, key: key)
        return store.save(slot.effectiveKey(in: store), scope: .global, value: trimmed, kind: .secret, origin: .workflow)
            .isSuccess
    }

    /// Saves a value only this workflow uses: its slot gets its own key when
    /// the shared key already holds something else.
    @discardableResult
    static func saveSeparate(
        _ value: String, scope: UUID, key: String, workflowName: String, store: CredentialStore = .current
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let slot = slot(scope: scope, key: key, workflowName: workflowName)
        if let bound = store.boundKey(for: slot.id), bound != slot.defaultKey {
            return store.save(bound, scope: .global, value: trimmed, kind: .secret, origin: .workflow).isSuccess
        }
        return store.save(trimmed, for: slot, owner: workflowName, origin: .workflow, separateOnConflict: true)
            .outcome.isSuccess
    }

    @discardableResult
    static func save(_ value: String, account: String, store: CredentialStore = .current) -> Bool {
        guard let (scope, key) = parse(account: account) else {
            return WorkflowSecretsKeychain.save(value, account: account)
        }
        return save(value, scope: scope, key: key, store: store)
    }

    /// Points `destination`'s slot at the credential that fills `source`'s,
    /// importing a legacy-only source value. False when `source` has none.
    @discardableResult
    static func copy(key: String, from source: UUID, to destination: UUID, store: CredentialStore = .current) -> Bool {
        guard source != destination else { return hasValue(scope: source, key: key, store: store) }
        let from = slot(scope: source, key: key)
        let to = slot(scope: destination, key: key)
        let sourceKey = from.effectiveKey(in: store)
        if store.hasValue(sourceKey, scope: .global) {
            store.setBinding(slot: to.id, key: sourceKey, defaultKey: to.defaultKey)
            return true
        }
        guard
            let legacy = CredentialResolver.resolve(
                sourceKey, agentId: nil, legacy: [legacyItem(scope: source, key: key)], store: store)
        else { return false }
        let target = to.effectiveKey(in: store)
        if let existing = store.value(target, scope: .global), existing != legacy {
            let renamed = CredentialKeys.prefixed("WORKFLOW_\(destination.uuidString.prefix(8))", key)
            guard store.save(renamed, scope: .global, value: legacy, kind: .secret, origin: .workflow).isSuccess else {
                return false
            }
            store.setBinding(slot: to.id, key: renamed, defaultKey: to.defaultKey)
            return true
        }
        return store.hasValue(target, scope: .global)
            || store.save(target, scope: .global, value: legacy, kind: .secret, origin: .workflow).isSuccess
    }

    /// Copies `keys` from one scope to another (a draft's or template's
    /// secrets following it into the install) and returns bindings naming
    /// the destination accounts, only for keys that had a value. With
    /// `removingSource`, the source scope's bindings are forgotten; values
    /// are never deleted. Keys bound to a shared connection in `existing`
    /// keep that binding, since a connection is not scoped to a workflow.
    static func rekey(
        _ keys: [String], from source: UUID, to destination: UUID, removingSource: Bool = true,
        keeping existing: [String: String] = [:], store: CredentialStore = .current
    ) -> [String: String] {
        var bindings: [String: String] = [:]
        for key in keys {
            if let bound = existing[key], WorkflowSecretsKeychain.isConnectionAccount(bound) {
                bindings[key] = bound
                continue
            }
            guard copy(key: key, from: source, to: destination, store: store) else { continue }
            bindings[key] = WorkflowSecretsKeychain.secretAccount(scope: destination, key: key)
            if removingSource, source != destination { forget(keys: [key], scope: source, store: store) }
        }
        return bindings
    }

    /// Forgets `scope`'s slot bindings. The credentials stay: other
    /// workflows or agents may use them, and the Keys page lists unused keys.
    static func forget(keys: [String], scope: UUID, store: CredentialStore = .current) {
        CredentialResolver.forget(slots: keys.map { slot(scope: scope, key: $0).id }, store: store)
    }
}
