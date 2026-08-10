//
//  BrowserPluginMigration.swift
//  OsaurusCore — Native Browser Use
//
//  One-time launch migration from the superseded `osaurus.browser` plugin to
//  the native session catalog. The plugin persisted each agent's WebKit
//  profile UUID as the per-agent Keychain secret `profile_id` (plugin id
//  `osaurus.browser`); copying that exact UUID into the catalog means the
//  native `WKWebsiteDataStore(forIdentifier:)` opens the very same on-disk
//  store — cookies and sign-ins carry over with no user action.
//
//  Deliberately EXACT-agent only: the plugin fell back to the Default
//  agent's profile when an agent had none, but replicating that here would
//  silently share one agent's authenticated sessions with another. An agent
//  with no stored `profile_id` simply mints a fresh native profile on first
//  use. The old Keychain values are left in place (the plugin may still be
//  installed; uninstall owns that cleanup).
//

import Foundation

@MainActor
public enum BrowserPluginMigration {
    static let pluginId = "osaurus.browser"
    static let profileSecretKey = "profile_id"

    /// Copy each agent's exact plugin profile UUID into the native catalog.
    /// Idempotent two ways: `BrowserSessionCatalog.migrateProfile` never
    /// clobbers an existing record, and the `pluginProfilesMigrated` marker
    /// skips the Keychain sweep entirely on later launches. Skipped when
    /// Keychain access is disabled (live-proof / test launches) so the marker
    /// isn't burned before a real run can migrate.
    ///
    /// `agentIds` and `secretReader` are test seams; production callers use
    /// the defaults (every known agent plus the Default agent, read from
    /// `ToolSecretsKeychain`).
    public static func migrateIfNeeded(
        agentIds: [UUID]? = nil,
        secretReader: ((UUID) -> String?)? = nil
    ) {
        var config = BrowserConfigurationStore.load()
        guard !config.pluginProfilesMigrated else { return }
        if secretReader == nil {
            // Real-Keychain path only: never burn the marker on a launch that
            // cannot actually read the plugin's secrets.
            guard !KeychainQueryHelpers.disablesKeychainForProcess else { return }
        }
        let readSecret =
            secretReader
            ?? { agentId in
                ToolSecretsKeychain.getSecret(id: profileSecretKey, for: pluginId, agentId: agentId)
            }

        var agentIds = agentIds ?? AgentManager.shared.agents.map(\.id)
        if !agentIds.contains(Agent.defaultId) {
            agentIds.append(Agent.defaultId)
        }

        var migratedCount = 0
        for agentId in agentIds {
            guard
                let raw = readSecret(agentId),
                let profileId = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            if BrowserSessionCatalog.migrateProfile(profileId, forAgent: agentId) {
                migratedCount += 1
            }
        }

        config.pluginProfilesMigrated = true
        BrowserConfigurationStore.save(config)
        if migratedCount > 0 {
            print("[Osaurus] Migrated \(migratedCount) browser profile(s) from osaurus.browser")
        }
    }
}
