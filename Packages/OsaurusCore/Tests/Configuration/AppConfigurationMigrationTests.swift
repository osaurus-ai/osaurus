//
//  AppConfigurationMigrationTests.swift
//  OsaurusCoreTests
//
//  Pins the contract of `AppConfiguration`'s legacy-memory-json
//  migration helpers. The 2026-04 incident was:
//
//    1. User picks Foundation Model in Settings → save writes
//       `{coreModelName: "foundation"}` to chat.json (provider key
//       omitted because nil-optionals are skipped by JSONEncoder).
//    2. Restart → load sees "provider missing" → fires the legacy
//       migration → reads `coreModelProvider:"anthropic",
//       coreModelName:"claude-haiku-4-5"` from memory.json →
//       overwrites both keys in chat.json → user sees Claude
//       Haiku again instead of their saved Foundation choice.
//
//  These tests cover the helpers directly (`internal` access via
//  `@testable import`) so they exercise the migration logic
//  without driving the `@MainActor` `AppConfiguration.shared`
//  singleton's init lifecycle (which makes test ordering matter).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AppConfigurationMigrationTests {

    @MainActor
    private static func setUpTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-appcfg-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
        return root
    }

    @MainActor
    private static func tearDown(_ root: URL) {
        OsaurusPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private static func writeMemory(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: OsaurusPaths.memoryConfigFile(), options: .atomic)
    }

    @MainActor
    private static func readMemory() throws -> [String: Any] {
        let data = try Data(contentsOf: OsaurusPaths.memoryConfigFile())
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - migrateCoreModelFromMemoryConfig

    /// Direct regression for the user-reported bug: a saved
    /// `coreModelName: "foundation"` (with no provider key) must
    /// NOT be overwritten by a legacy memory.json on the next load.
    /// The migrator must respect existing chat-side names and only
    /// fill in nil destinations.
    @Test
    func migrate_keepsExistingChatName_evenWhenLegacyJsonHasOtherValues() async throws {
        try await StoragePathsTestLock.shared.run {
            try await MainActor.run {
                let root = try Self.setUpTempRoot()
                defer { Self.tearDown(root) }

                try Self.writeMemory([
                    "coreModelProvider": "anthropic",
                    "coreModelName": "claude-haiku-4-5",
                ])

                var input = ChatConfiguration.default
                input.coreModelName = "foundation"
                input.coreModelProvider = nil

                let migrated = AppConfiguration.migrateCoreModelFromMemoryConfig(into: input)

                #expect(
                    migrated.coreModelName == "foundation",
                    "saved Foundation name must not be overwritten"
                )
                #expect(
                    migrated.coreModelProvider == nil,
                    "must not attach 'anthropic' provider to a local-model name"
                )
            }
        }
    }

    /// First-time migration path: chat-side has no name, memory.json
    /// holds the legacy tuple. Migration adopts both this once.
    @Test
    func migrate_adoptsLegacyValuesWhenChatHasNoName() async throws {
        try await StoragePathsTestLock.shared.run {
            try await MainActor.run {
                let root = try Self.setUpTempRoot()
                defer { Self.tearDown(root) }

                try Self.writeMemory([
                    "coreModelProvider": "anthropic",
                    "coreModelName": "claude-haiku-4-5",
                ])

                var input = ChatConfiguration.default
                input.coreModelName = nil
                input.coreModelProvider = nil

                let migrated = AppConfiguration.migrateCoreModelFromMemoryConfig(into: input)

                #expect(migrated.coreModelProvider == "anthropic")
                #expect(migrated.coreModelName == "claude-haiku-4-5")
            }
        }
    }

    /// When chat-side has no name AND memory.json is missing too,
    /// the migrator returns the input unchanged. The downstream
    /// backfill is responsible for picking a default.
    @Test
    func migrate_isNoOpWhenNeitherSideHasValue() async throws {
        try await StoragePathsTestLock.shared.run {
            try await MainActor.run {
                let root = try Self.setUpTempRoot()
                defer { Self.tearDown(root) }
                try Self.writeMemory(["enabled": true])

                var input = ChatConfiguration.default
                input.coreModelName = nil
                input.coreModelProvider = nil

                let migrated = AppConfiguration.migrateCoreModelFromMemoryConfig(into: input)
                #expect(migrated.coreModelName == nil)
                #expect(migrated.coreModelProvider == nil)
            }
        }
    }

    // MARK: - stripLegacyCoreModelKeysFromMemoryConfig

    /// Always remove the legacy `coreModelProvider` /
    /// `coreModelName` keys from memory.json so the migration
    /// trigger can never silently re-fire on later launches.
    @Test
    func strip_removesLegacyKeysAndPreservesEverythingElse() async throws {
        try await StoragePathsTestLock.shared.run {
            try await MainActor.run {
                let root = try Self.setUpTempRoot()
                defer { Self.tearDown(root) }

                try Self.writeMemory([
                    "enabled": true,
                    "embeddingBackend": "mlx",
                    "coreModelProvider": "anthropic",
                    "coreModelName": "claude-haiku-4-5",
                    "memoryBudgetTokens": 800,
                ])

                AppConfiguration.stripLegacyCoreModelKeysFromMemoryConfig()

                let memOnDisk = try Self.readMemory()
                #expect(memOnDisk["coreModelProvider"] == nil)
                #expect(memOnDisk["coreModelName"] == nil)
                #expect(memOnDisk["enabled"] as? Bool == true)
                #expect(memOnDisk["embeddingBackend"] as? String == "mlx")
                #expect(memOnDisk["memoryBudgetTokens"] as? Int == 800)
            }
        }
    }

    /// Idempotent — second strip after a clean memory.json is a
    /// no-op (and notably doesn't crash on a missing file).
    @Test
    func strip_isIdempotent() async throws {
        try await StoragePathsTestLock.shared.run {
            try await MainActor.run {
                let root = try Self.setUpTempRoot()
                defer { Self.tearDown(root) }

                try Self.writeMemory(["enabled": true])

                AppConfiguration.stripLegacyCoreModelKeysFromMemoryConfig()
                AppConfiguration.stripLegacyCoreModelKeysFromMemoryConfig()

                let memOnDisk = try Self.readMemory()
                #expect(memOnDisk["enabled"] as? Bool == true)
                #expect(memOnDisk["coreModelProvider"] == nil)
                #expect(memOnDisk["coreModelName"] == nil)
            }
        }
    }

    // MARK: - backfillFoundationCoreModelIfMissing

    /// Backfill picks Foundation when the chat-side name is nil/empty.
    @Test
    @MainActor
    func backfill_setsFoundationWhenNameMissing() {
        var input = ChatConfiguration.default
        input.coreModelName = nil
        input.coreModelProvider = nil
        let result = AppConfiguration.backfillFoundationCoreModelIfMissing(input)
        #expect(result.coreModelName == "foundation")
        #expect(result.coreModelProvider == nil)
    }

    /// Backfill must NOT touch an explicit user choice.
    @Test
    @MainActor
    func backfill_preservesExistingChoice() {
        var input = ChatConfiguration.default
        input.coreModelName = "claude-haiku-4-5"
        input.coreModelProvider = "anthropic"
        let result = AppConfiguration.backfillFoundationCoreModelIfMissing(input)
        #expect(result.coreModelName == "claude-haiku-4-5")
        #expect(result.coreModelProvider == "anthropic")
    }

    /// Whitespace-only strings count as empty (defensive against
    /// picker bugs that might submit a stray space).
    @Test
    @MainActor
    func backfill_treatsWhitespaceOnlyNameAsMissing() {
        var input = ChatConfiguration.default
        input.coreModelName = "  "
        input.coreModelProvider = nil
        let result = AppConfiguration.backfillFoundationCoreModelIfMissing(input)
        #expect(result.coreModelName == "foundation")
    }
}
