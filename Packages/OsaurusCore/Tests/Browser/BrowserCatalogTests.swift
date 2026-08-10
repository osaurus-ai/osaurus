//
//  BrowserCatalogTests.swift
//  OsaurusCore — Native Browser Use
//
//  Deterministic coverage for the persistent session catalog, the Default
//  agent's configuration store, and the one-time plugin-profile migration:
//  profile minting/stability, observed auth-status transitions (never
//  inferred from cookies), exact-agent migration with no default-agent
//  fallback, and marker idempotence.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Point both browser stores at a fresh temp directory for the duration of
/// `body`, restoring the previous overrides (and dropping caches) afterward.
@MainActor
private func withTemporaryBrowserStores(_ body: @MainActor () throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("osaurus-browser-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let previousCatalogDir = BrowserSessionCatalog.overrideDirectory
    let previousConfigDir = BrowserConfigurationStore.overrideDirectory
    BrowserSessionCatalog.overrideDirectory = dir
    BrowserConfigurationStore.overrideDirectory = dir
    BrowserSessionCatalog.resetCacheForTests()
    BrowserConfigurationStore.resetCacheForTests()
    defer {
        BrowserSessionCatalog.overrideDirectory = previousCatalogDir
        BrowserConfigurationStore.overrideDirectory = previousConfigDir
        BrowserSessionCatalog.resetCacheForTests()
        BrowserConfigurationStore.resetCacheForTests()
        try? FileManager.default.removeItem(at: dir)
    }
    try body()
}

// MARK: - Session catalog

@MainActor
@Suite(.serialized)
struct BrowserSessionCatalogTests {

    @Test func profileIdIsMintedOnceAndStable() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            let first = BrowserSessionCatalog.profileId(for: agentId)
            let second = BrowserSessionCatalog.profileId(for: agentId)
            #expect(first == second)
            #expect(BrowserSessionCatalog.record(for: agentId)?.profileId == first)
        }
    }

    @Test func updateCreatesAndMutatesRecords() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            BrowserSessionCatalog.update(agentId: agentId) { record in
                record.lastDomain = "example.com"
                record.lastTitle = "Example"
            }
            let record = BrowserSessionCatalog.record(for: agentId)
            #expect(record?.lastDomain == "example.com")
            #expect(record?.lastTitle == "Example")
        }
    }

    @Test func removeForgetsTheRecord() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            _ = BrowserSessionCatalog.profileId(for: agentId)
            BrowserSessionCatalog.remove(agentId: agentId)
            #expect(BrowserSessionCatalog.record(for: agentId) == nil)
        }
    }

    @Test func allRecordsSortsByMostRecentActivity() {
        withTemporaryBrowserStores {
            let older = UUID()
            let newer = UUID()
            BrowserSessionCatalog.update(agentId: older) {
                $0.lastActivity = Date(timeIntervalSinceNow: -3600)
            }
            BrowserSessionCatalog.update(agentId: newer) { $0.lastActivity = Date() }
            let ids = BrowserSessionCatalog.allRecords().map(\.agentId)
            #expect(ids == [newer, older])
        }
    }

    @Test func migrateProfileNeverClobbersAnExistingRecord() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            let native = BrowserSessionCatalog.profileId(for: agentId)
            // A later migration attempt for the same agent must be a no-op —
            // the user already has a native session.
            let migrated = BrowserSessionCatalog.migrateProfile(UUID(), forAgent: agentId)
            #expect(!migrated)
            #expect(BrowserSessionCatalog.profileId(for: agentId) == native)
        }
    }

    // MARK: Observed auth transitions (via the manager's recording paths)

    @Test func landingOnALoginPageMarksSignInRequired() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            BrowserSessionManager.shared.recordNavigation(
                agentId: agentId,
                url: "https://github.com/login?return_to=/pulls",
                title: "Sign in to GitHub"
            )
            let record = BrowserSessionCatalog.record(for: agentId)
            #expect(record?.services["github.com"] == .signInRequired)
        }
    }

    @Test func clearingTheLoginWallUpgradesToObservedSignedIn() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            BrowserSessionManager.shared.recordNavigation(
                agentId: agentId, url: "https://github.com/login", title: "Sign in to GitHub")
            BrowserSessionManager.shared.recordNavigation(
                agentId: agentId, url: "https://github.com/pulls", title: "Pull requests")
            let record = BrowserSessionCatalog.record(for: agentId)
            #expect(record?.services["github.com"] == .observedSignedIn)
        }
    }

    @Test func ordinaryBrowsingNeverInfersSignedIn() {
        withTemporaryBrowserStores {
            // Visiting a host without ever hitting its login wall leaves the
            // status untracked — cookie presence alone must not read as
            // "signed in" (the plan's observed-status rule).
            let agentId = UUID()
            BrowserSessionManager.shared.recordNavigation(
                agentId: agentId, url: "https://example.com/pricing", title: "Pricing")
            let record = BrowserSessionCatalog.record(for: agentId)
            #expect(record?.services["example.com"] == nil)
            #expect(record?.lastDomain == "example.com")
        }
    }

    @Test func explicitSignInObservationRecordsTheHost() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            BrowserSessionManager.shared.recordObservedSignIn(
                agentId: agentId, host: "mail.example.com")
            let record = BrowserSessionCatalog.record(for: agentId)
            #expect(record?.services["mail.example.com"] == .observedSignedIn)
        }
    }

    @Test func rapidUpdatesPersistTheLatestStateToDisk() throws {
        try withTemporaryBrowserStores {
            // Serial-persist guard: many rapid saves must land in order, so
            // the file always ends at the LAST write (the concurrent global
            // queue could previously land them reversed).
            let agentId = UUID()
            for index in 1 ... 25 {
                BrowserSessionCatalog.update(agentId: agentId) {
                    $0.lastTitle = "step-\(index)"
                }
            }
            BrowserSessionCatalog.flushWritesForTests()

            let url = BrowserSessionCatalog.overrideDirectory!
                .appendingPathComponent("browser-sessions.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode(
                [BrowserSessionRecord].self, from: Data(contentsOf: url))
            #expect(records.first { $0.agentId == agentId }?.lastTitle == "step-25")
        }
    }

    @Test func recordsDecodeFromDiskWithISO8601Dates() throws {
        try withTemporaryBrowserStores {
            let agentId = UUID()
            let profileId = UUID()
            let json = """
                [
                  {
                    "agentId": "\(agentId.uuidString)",
                    "profileId": "\(profileId.uuidString)",
                    "isActive": false,
                    "lastDomain": "example.com",
                    "lastActivity": "2026-07-01T12:00:00Z",
                    "services": { "example.com": "observedSignedIn" }
                  }
                ]
                """
            let url = BrowserSessionCatalog.overrideDirectory!
                .appendingPathComponent("browser-sessions.json")
            try json.data(using: .utf8)!.write(to: url)
            BrowserSessionCatalog.resetCacheForTests()

            let record = BrowserSessionCatalog.record(for: agentId)
            #expect(record?.profileId == profileId)
            #expect(record?.services["example.com"] == .observedSignedIn)
            #expect(record?.lastActivity != nil)
        }
    }
}

// MARK: - Configuration store

@MainActor
@Suite(.serialized)
struct BrowserConfigurationStoreTests {

    @Test func migrationMarkerIsOffByDefault() {
        withTemporaryBrowserStores {
            #expect(BrowserConfigurationStore.load().pluginProfilesMigrated == false)
        }
    }

    @Test func savedConfigurationRoundTrips() {
        withTemporaryBrowserStores {
            var config = BrowserConfigurationStore.load()
            config.pluginProfilesMigrated = true
            BrowserConfigurationStore.save(config)
            #expect(BrowserConfigurationStore.load().pluginProfilesMigrated == true)
        }
    }

    @Test func rapidSavesPersistTheLatestConfiguration() throws {
        try withTemporaryBrowserStores {
            // Serial-persist guard for the config file (a reversed pair could
            // persist a stale migration marker).
            for _ in 1 ... 10 {
                BrowserConfigurationStore.save(BrowserConfiguration(pluginProfilesMigrated: false))
                BrowserConfigurationStore.save(BrowserConfiguration(pluginProfilesMigrated: true))
            }
            BrowserConfigurationStore.flushWritesForTests()

            let url = BrowserConfigurationStore.overrideDirectory!
                .appendingPathComponent("browser.json")
            let config = try JSONDecoder().decode(
                BrowserConfiguration.self, from: Data(contentsOf: url))
            #expect(config.pluginProfilesMigrated == true)
        }
    }

    @Test func missingKeysDecodeToDefaults() throws {
        try withTemporaryBrowserStores {
            // A config written by an older build (which carried the removed
            // Default-agent opt-in and no migration marker) must decode with
            // the marker defaulted off, not throw.
            let url = BrowserConfigurationStore.overrideDirectory!
                .appendingPathComponent("browser.json")
            try #"{"defaultAgentEnabled": true}"#.data(using: .utf8)!.write(to: url)
            BrowserConfigurationStore.resetCacheForTests()

            let config = BrowserConfigurationStore.load()
            #expect(config.pluginProfilesMigrated == false)
        }
    }
}

// MARK: - Plugin-profile migration

@MainActor
@Suite(.serialized)
struct BrowserPluginMigrationTests {

    // These tests inject `secretReader` (the seam the production path fills
    // with `ToolSecretsKeychain.getSecret`) because the standard test lane
    // runs with OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1, where every Keychain
    // wrapper is a deliberate no-op.

    @Test func migratesTheExactAgentProfileUUID() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            let pluginProfile = UUID()

            BrowserPluginMigration.migrateIfNeeded(agentIds: [agentId]) { id in
                id == agentId ? pluginProfile.uuidString : nil
            }

            // The exact UUID is reused so the native WKWebsiteDataStore opens
            // the plugin's on-disk store (sign-ins carry over).
            #expect(BrowserSessionCatalog.record(for: agentId)?.profileId == pluginProfile)
        }
    }

    @Test func doesNotFallBackToTheDefaultAgentsProfile() {
        withTemporaryBrowserStores {
            // The plugin resolved a missing per-agent profile through the
            // Default agent's Keychain entry; the native migration must NOT —
            // that would share one agent's authenticated session with another.
            let customAgent = UUID()
            let defaultProfile = UUID()

            BrowserPluginMigration.migrateIfNeeded(agentIds: [customAgent]) { id in
                id == Agent.defaultId ? defaultProfile.uuidString : nil
            }

            // The Default agent's own record migrates its own profile…
            #expect(
                BrowserSessionCatalog.record(for: Agent.defaultId)?.profileId == defaultProfile)
            // …but the custom agent gets NO record (it mints fresh on first use).
            #expect(BrowserSessionCatalog.record(for: customAgent) == nil)
        }
    }

    @Test func migrationRunsOnceViaTheMarker() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            BrowserPluginMigration.migrateIfNeeded(agentIds: [agentId]) { _ in nil }
            #expect(BrowserConfigurationStore.load().pluginProfilesMigrated)

            // A profile that appears AFTER the sweep must not migrate (the
            // plugin is superseded; nothing legitimately writes new ones).
            let lateProfile = UUID()
            BrowserPluginMigration.migrateIfNeeded(agentIds: [agentId]) { _ in
                lateProfile.uuidString
            }
            #expect(BrowserSessionCatalog.record(for: agentId) == nil)
        }
    }

    @Test func uninstallOrderingPreservesProfileAfterSecretSweep() {
        withTemporaryBrowserStores {
            // `PluginRepositoryService.uninstall("osaurus.browser")` runs the
            // migration BEFORE `ToolSecretsKeychain` sweeps the plugin's
            // secrets — the Keychain `profile_id` is the only other copy of
            // the WebKit profile UUID. Simulate that ordering: once the
            // migration has copied the profile, destroying the secret store
            // must not lose it.
            let agentId = UUID()
            let profile = UUID()
            var secrets: [UUID: String] = [agentId: profile.uuidString]

            BrowserPluginMigration.migrateIfNeeded(agentIds: [agentId]) { secrets[$0] }
            secrets.removeAll()  // uninstall deletes every Keychain entry

            #expect(BrowserSessionCatalog.record(for: agentId)?.profileId == profile)

            // The marker means a later migrate call against the now-empty
            // store is a no-op — the catalog record survives untouched.
            BrowserPluginMigration.migrateIfNeeded(agentIds: [agentId]) { secrets[$0] }
            #expect(BrowserSessionCatalog.record(for: agentId)?.profileId == profile)
        }
    }

    @Test func nonUUIDSecretsAreIgnored() {
        withTemporaryBrowserStores {
            let agentId = UUID()
            BrowserPluginMigration.migrateIfNeeded(agentIds: [agentId]) { _ in "not-a-uuid" }
            #expect(BrowserSessionCatalog.record(for: agentId) == nil)
        }
    }

    @Test func keychainDisabledLaunchNeverBurnsTheMarker() {
        withTemporaryBrowserStores {
            // Without the seam, a keychain-disabled process (this test lane,
            // live-proof launches) must skip entirely — leaving the marker
            // unset so a real launch can still migrate. When run in the
            // keychain-enabled lane this test is a no-op.
            guard KeychainQueryHelpers.disablesKeychainForProcess else { return }
            BrowserPluginMigration.migrateIfNeeded(agentIds: [UUID()])
            #expect(!BrowserConfigurationStore.load().pluginProfilesMigrated)
        }
    }
}
