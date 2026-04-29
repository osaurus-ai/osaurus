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
        // Only meaningful when Foundation is unavailable; in that case
        // the gated default would also be nil. Backfill always sets the
        // literal name regardless of availability — the per-machine
        // gating happens in `clearUnavailableFoundationCoreModel`.
        #expect(result.coreModelName == "foundation")
    }

    // MARK: - clearUnavailableFoundationCoreModel
    //
    // Pairs with `ChatConfiguration.defaultCoreModelNameIfAvailable`
    // (gated default) to keep the persisted state honest about what
    // this Mac can run. Pre-fix, fresh installs on macOS < 26 shipped
    // with `coreModelName = "foundation"` baked in and persisted —
    // the picker showed it as "set", `CoreModelService.generate` threw
    // `modelUnavailable` every turn, and preflight tool selection
    // silently broke. See GitHub issue #823.

    /// Branch the assertion on the running OS's Foundation
    /// availability so the test passes on both macOS 26+ (Foundation
    /// available — must NOT clear) and macOS < 26 (must clear). The
    /// alternative — mocking `FoundationModelService` — would require
    /// dependency-injecting through a static, which doesn't justify
    /// its complexity here.
    @Test
    @MainActor
    func clearUnavailableFoundation_handlesPersistedFoundationName() {
        var input = ChatConfiguration.default
        input.coreModelName = "foundation"
        input.coreModelProvider = nil
        let result = AppConfiguration.clearUnavailableFoundationCoreModel(input)

        if FoundationModelService.isDefaultModelAvailable() {
            // macOS 26+ with Apple Intelligence: keep the persisted
            // value; the user's saved Foundation choice is real.
            #expect(result.coreModelName == "foundation")
            #expect(result.coreModelProvider == nil)
        } else {
            // macOS < 26 (or Apple Intelligence disabled): clear the
            // unrunnable persisted value so the chat-model fallback
            // takes over and the picker stops showing an orphan
            // entry.
            #expect(result.coreModelName == nil)
            #expect(result.coreModelProvider == nil)
        }
    }

    /// Case-insensitive match on the literal default name so a
    /// stray-cased `"Foundation"` from a hand-edited chat.json gets
    /// cleaned the same way as the canonical lowercase form.
    @Test
    @MainActor
    func clearUnavailableFoundation_isCaseInsensitive() {
        guard !FoundationModelService.isDefaultModelAvailable() else {
            // Only meaningful on macOS where Foundation isn't available;
            // when it is, the case-insensitive cleanup is a no-op anyway.
            return
        }
        var input = ChatConfiguration.default
        input.coreModelName = "Foundation"
        input.coreModelProvider = nil
        let result = AppConfiguration.clearUnavailableFoundationCoreModel(input)
        #expect(result.coreModelName == nil)
    }

    /// Whitespace around the literal name still triggers the cleanup
    /// (defensive against picker bugs that submit a trailing space).
    @Test
    @MainActor
    func clearUnavailableFoundation_trimsWhitespace() {
        guard !FoundationModelService.isDefaultModelAvailable() else { return }
        var input = ChatConfiguration.default
        input.coreModelName = "  foundation  "
        input.coreModelProvider = nil
        let result = AppConfiguration.clearUnavailableFoundationCoreModel(input)
        #expect(result.coreModelName == nil)
    }

    /// Cleanup must be a strict no-op for any other persisted model —
    /// e.g. an explicit Anthropic / Ollama / MLX choice — regardless
    /// of Foundation availability.
    @Test
    @MainActor
    func clearUnavailableFoundation_neverTouchesOtherModels() {
        var input = ChatConfiguration.default
        input.coreModelName = "claude-haiku-4-5"
        input.coreModelProvider = "anthropic"
        let result = AppConfiguration.clearUnavailableFoundationCoreModel(input)
        #expect(result.coreModelName == "claude-haiku-4-5")
        #expect(result.coreModelProvider == "anthropic")
    }

    /// Already-nil persisted state stays nil; no spurious mutation.
    @Test
    @MainActor
    func clearUnavailableFoundation_preservesNilState() {
        var input = ChatConfiguration.default
        input.coreModelName = nil
        input.coreModelProvider = nil
        let result = AppConfiguration.clearUnavailableFoundationCoreModel(input)
        #expect(result.coreModelName == nil)
        #expect(result.coreModelProvider == nil)
    }

    // MARK: - ChatConfiguration.defaultCoreModelNameIfAvailable

    /// Pin the contract that the gated default tracks runtime
    /// Foundation availability. Without this, the data layer can drift
    /// from the service layer and re-introduce the "persisted but
    /// unrunnable `foundation`" state on a future refactor.
    @Test
    @MainActor
    func defaultCoreModelNameIfAvailable_matchesFoundationAvailability() {
        let value = ChatConfiguration.defaultCoreModelNameIfAvailable
        if FoundationModelService.isDefaultModelAvailable() {
            #expect(value == ChatConfiguration.defaultCoreModelName)
        } else {
            #expect(value == nil)
        }
    }

    /// `ChatConfiguration.default` must use the gated value, not the
    /// raw literal — so a fresh install never persists an unrunnable
    /// `"foundation"` on macOS where Apple Intelligence isn't there.
    @Test
    @MainActor
    func defaultConfig_coreModelNameIsGated() {
        let cfg = ChatConfiguration.default
        if FoundationModelService.isDefaultModelAvailable() {
            #expect(cfg.coreModelName == "foundation")
        } else {
            #expect(cfg.coreModelName == nil)
        }
    }
}
