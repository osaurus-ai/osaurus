//
//  ChannelCredentials.swift
//  osaurus
//
//  Channel tokens (Slack, Discord, Telegram, custom JSON / n8n) are keys
//  shared by all agents. Items saved earlier in `ToolSecretsKeychain` under
//  the Default agent and a channel plugin id are read only as the legacy
//  fallback until imported.
//

import Foundation

enum ChannelCredentials {
    static func legacyId(pluginId: String, key: String) -> String {
        ToolSecretsKeychain.legacyId(agentId: Agent.defaultId, pluginId: pluginId, key: key)
    }

    static func legacyItem(pluginId: String, key: String) -> CredentialResolver.LegacyItem {
        CredentialResolver.LegacyItem(legacyId(pluginId: pluginId, key: key)) {
            ToolSecretsKeychain.readOnlySecret(id: key, for: pluginId, agentId: Agent.defaultId)
        }
    }

    static func value(_ slot: CredentialSlot, legacyPluginId: String, legacyKey: String) -> String? {
        CredentialResolver.resolve(slot, agentId: nil, legacy: [legacyItem(pluginId: legacyPluginId, key: legacyKey)])
    }

    static func has(_ slot: CredentialSlot, legacyPluginId: String, legacyKey: String) -> Bool {
        CredentialResolver.isSatisfied(
            slot, agentId: nil, legacy: [legacyItem(pluginId: legacyPluginId, key: legacyKey)])
    }

    static func save(_ value: String, slot: CredentialSlot) -> CredentialWriteOutcome {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyValue }
        let store = CredentialStore.current
        return store.save(slot.effectiveKey(in: store), scope: .global, value: trimmed, kind: .secret, origin: .channel)
    }

    // MARK: Custom JSON / n8n agent channels

    static let agentChannelPluginIdPrefix = "osaurus.agent-channel"

    static func agentChannelPluginId(_ connectionId: String) -> String {
        "\(agentChannelPluginIdPrefix).\(connectionId)"
    }

    static func agentChannelValue(connectionId: String, connectionName: String, secretName: String) -> String? {
        value(
            ChannelCredentialSlots.agentChannel(
                connectionId: connectionId, connectionName: connectionName, secretName: secretName),
            legacyPluginId: agentChannelPluginId(connectionId), legacyKey: secretName)
    }

    static func saveAgentChannel(
        _ value: String, connectionId: String, connectionName: String, secretName: String
    ) -> CredentialWriteOutcome {
        save(
            value,
            slot: ChannelCredentialSlots.agentChannel(
                connectionId: connectionId, connectionName: connectionName, secretName: secretName))
    }

    @discardableResult
    static func deleteAgentChannel(connectionId: String, connectionName: String, secretName: String) -> Bool {
        delete(
            ChannelCredentialSlots.agentChannel(
                connectionId: connectionId, connectionName: connectionName, secretName: secretName),
            legacyPluginId: agentChannelPluginId(connectionId), legacyKey: secretName)
    }

    /// Removes the global value; the delete's tombstone keeps the legacy
    /// fallback from bringing it back.
    @discardableResult
    static func delete(_ slot: CredentialSlot, legacyPluginId: String, legacyKey: String) -> Bool {
        let store = CredentialStore.current
        return store.delete(slot.effectiveKey(in: store), scope: .global).isSuccess
    }
}
