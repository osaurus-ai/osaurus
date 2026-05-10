//
//  PluginManagerMigrationTests.swift
//  OsaurusCoreTests
//
//  Pins the per-plugin tracking added in `Plugin Config + Loading
//  Hardening` to `PluginManager.migrateGlobalConfigToPerAgent`. The
//  legacy gate was a once-per-process static (`hasMigrated`); plugins
//  installed AFTER startup were silently skipped. The new gate persists
//  the migrated set in `UserDefaults` so a plugin's first scan always
//  sees the migration pass.
//
//  These tests touch only the helper functions
//  (`loadMigratedPluginIds` / `saveMigratedPluginIds`) so they stay
//  hermetic — the integration with the real `_loadAll` flow is covered
//  by manual smoke per the plan.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct PluginManagerMigrationHelperTests {

    /// Snapshots the persisted set, runs `body`, then restores the
    /// snapshot so this test never alters the user's real
    /// PluginManager state across test runs.
    private func runWithEmptyMigrationSet<T>(_ body: () throws -> T) rethrows -> T {
        let snapshot = PluginManager.loadMigratedPluginIds()
        UserDefaults.standard.removeObject(forKey: PluginManager.migratedPluginIdsDefaultsKey)
        defer {
            PluginManager.saveMigratedPluginIds(snapshot)
        }
        return try body()
    }

    // MARK: - Round-trip

    @Test func saveLoadRoundTripsSet() throws {
        try runWithEmptyMigrationSet {
            let initial = PluginManager.loadMigratedPluginIds()
            #expect(initial.isEmpty, "test must start with the persisted set cleared")

            let payload: Set<String> = [
                "com.test.alpha",
                "com.test.beta",
                "com.test.gamma",
            ]
            PluginManager.saveMigratedPluginIds(payload)

            let reloaded = PluginManager.loadMigratedPluginIds()
            #expect(reloaded == payload)
        }
    }

    @Test func saveOverwritesPreviousValue() throws {
        try runWithEmptyMigrationSet {
            PluginManager.saveMigratedPluginIds(["com.test.first"])
            PluginManager.saveMigratedPluginIds(["com.test.second", "com.test.third"])

            let reloaded = PluginManager.loadMigratedPluginIds()
            #expect(reloaded == ["com.test.second", "com.test.third"])
            #expect(!reloaded.contains("com.test.first"), "save must overwrite, not union")
        }
    }

    @Test func saveEmptyClearsTheSet() throws {
        try runWithEmptyMigrationSet {
            PluginManager.saveMigratedPluginIds(["com.test.foo"])
            #expect(!PluginManager.loadMigratedPluginIds().isEmpty)

            PluginManager.saveMigratedPluginIds([])
            #expect(PluginManager.loadMigratedPluginIds().isEmpty)
        }
    }

    @Test func loadReturnsEmptyWhenKeyMissing() throws {
        try runWithEmptyMigrationSet {
            // Inside the helper, the key is removed before `body` runs.
            #expect(PluginManager.loadMigratedPluginIds().isEmpty)
        }
    }

    // MARK: - Set semantics

    /// Under the new contract, `migrateGlobalConfigToPerAgent` performs
    /// a per-plugin-id check `migrated.contains(pluginId)`, then unions
    /// the new ids in. Mirroring that here keeps the test honest about
    /// what the production code is actually doing.
    @Test func unionWithExistingSetIsIdempotent() throws {
        try runWithEmptyMigrationSet {
            var current = PluginManager.loadMigratedPluginIds()
            current.insert("com.test.alpha")
            PluginManager.saveMigratedPluginIds(current)

            // Second pass over the same plugin id is a no-op for the
            // persisted set: `contains` short-circuits in the real flow.
            current = PluginManager.loadMigratedPluginIds()
            #expect(current.contains("com.test.alpha"))
            current.insert("com.test.alpha")
            PluginManager.saveMigratedPluginIds(current)

            #expect(PluginManager.loadMigratedPluginIds() == ["com.test.alpha"])
        }
    }

    /// Defensive: `UserDefaults` will accept any plist-encodable type
    /// under our key. If a future contributor accidentally writes a
    /// non-`[String]` payload, `loadMigratedPluginIds` must degrade to
    /// an empty set rather than crash.
    @Test func loadDegradesGracefullyOnTypeMismatch() {
        runWithEmptyMigrationSet {
            UserDefaults.standard.set(
                ["valid_id", 42, true] as [Any],
                forKey: PluginManager.migratedPluginIdsDefaultsKey
            )
            // The cast `as? [String]` fails on the mixed-type array,
            // so the function returns an empty set instead of crashing.
            let loaded = PluginManager.loadMigratedPluginIds()
            #expect(loaded.isEmpty)
        }
    }
}
