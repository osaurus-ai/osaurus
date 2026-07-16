//
//  ServerRuntimeSettingsStoreTests.swift
//  osaurusTests
//
//  Coverage for `ServerRuntimeSettingsStore` — the canonical
//  persistence path for the vmlx `VMLXServerRuntimeSettings`
//  contract used by the Server → Settings tab.
//

import Foundation
@preconcurrency import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ServerRuntimeSettingsStoreTests {

    @Test @MainActor func loadOrMigrate_buildsFromLegacyOnFirstRun() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            // Override the legacy server.json directory too so the
            // migration source is the in-repo defaults rather than
            // whatever the developer machine has persisted at
            // `~/.osaurus/config/server.json`.
            let previousLegacy = ServerConfigurationStore.overrideDirectory
            ServerConfigurationStore.overrideDirectory = dir
            defer { ServerConfigurationStore.overrideDirectory = previousLegacy }

            // No file present yet — loadOrMigrate should derive the
            // settings from the legacy `server.json` defaults +
            // `UserDefaults` and persist them.
            let migrated = ServerRuntimeSettingsStore.loadOrMigrate()
            #expect(migrated.network.port == ServerConfiguration.default.port)
            #expect(migrated.network.host == "127.0.0.1")
            // The default disk-cache topology mirrors what
            // `ModelRuntime.buildCacheCoordinatorConfig` used to hardcode.
            #expect(migrated.cache.prefix.enabled == true)
            #expect(migrated.cache.pagedKV.enabled == false)
            #expect(migrated.cache.blockDisk.enabled == true)
            #expect(migrated.cache.legacyDisk.enabled == false)
            #expect(migrated.cache.liveKVCodec == .engineSelected)
            #expect(migrated.cache.prefix.memoryPercent == nil)
            // nil: the seed leaves the default KV cap to the RAM-safety slider
            // (safe_auto resolves to 65536 in vmlx, so the effective out-of-box
            // cap is unchanged, but the slider now governs it).
            #expect(migrated.cache.defaultMaxKVSize == nil)
            #expect(migrated.cache.longPromptMultiplier == 2.0)
            #expect(migrated.cache.enableSSMReDerive == true)
            #expect(migrated.mtp.mode == .auto)
            #expect(migrated.memorySafety.mode == .safeAuto)
            #expect(migrated.memorySafety.slider == 2)
            #expect(migrated.memorySafety.allowExperimentalMLXPress == false)

            // File should now exist.
            let url = dir.appendingPathComponent("server-runtime.json")
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(
                        ".server-runtime-memory-safety-cache-defaults-v4-migrated"
                    ).path
                )
            )
        }
    }

    @Test @MainActor func snapshotColdFallbackUsesMigratedOsaurusDefaults() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            let previousLegacy = ServerConfigurationStore.overrideDirectory
            ServerConfigurationStore.overrideDirectory = dir
            defer { ServerConfigurationStore.overrideDirectory = previousLegacy }

            let snapshot = ServerRuntimeSettingsStore.snapshot()

            #expect(snapshot.network.port == ServerConfiguration.default.port)
            #expect(snapshot.cache.prefix.enabled == true)
            #expect(snapshot.cache.pagedKV.enabled == false)
            #expect(snapshot.cache.blockDisk.enabled == true)
            #expect(snapshot.cache.legacyDisk.enabled == false)
            #expect(snapshot.cache.liveKVCodec == .engineSelected)
            #expect(snapshot.cache.prefix.memoryPercent == nil)
            // nil: slider governs the default KV cap (see migrate test above).
            #expect(snapshot.cache.defaultMaxKVSize == nil)
            #expect(snapshot.cache.longPromptMultiplier == 2.0)
            #expect(snapshot.cache.enableSSMReDerive == true)
            #expect(snapshot.mtp.mode == .auto)
            #expect(snapshot.memorySafety.mode == .safeAuto)
            #expect(snapshot.memorySafety.slider == 2)
            #expect(snapshot.memorySafety.allowExperimentalMLXPress == false)
        }
    }

    @Test func noAutomaticLimitsRemovesOnlyImplicitCaps() {
        var settings = VMLXServerRuntimeSettings()
        settings.memorySafety.mode = .diagnosticDangerous
        settings.cache.prefix.memoryPercent = nil
        settings.cache.defaultMaxKVSize = nil
        settings.concurrency.maxConcurrentSequences = nil

        let plan = ServerRuntimeSettingsStore.resolvedMemorySafetyPlan(for: settings)

        #expect(plan.loadConfiguration.memoryLimit == .unlimited)
        #expect(plan.loadConfiguration.maxResidentBytes == .unlimited)
        #expect(plan.resolvedLoadBudgetBytes == nil)
        #expect(plan.cache.prefix.memoryPercent == nil)
        #expect(plan.cache.defaultMaxKVSize == nil)
        #expect(plan.concurrency.maxConcurrentSequences == nil)
        #expect(plan.displaySummary.contains("load_cap=unlimited"))
        #expect(plan.displaySummary.contains("allocator_cap=unlimited"))
        #expect(plan.displaySummary.contains("max_concurrent=default"))
        #expect(plan.displaySummary.contains("kv_cap=unlimited"))
    }

    @Test func noAutomaticLimitsDisablesOsaurusOwnedPercentageGates() {
        var settings = VMLXServerRuntimeSettings()
        settings.memorySafety.mode = .diagnosticDangerous
        settings.memorySafety.customPhysicalMemoryFraction = nil

        #expect(ServerRuntimeSettingsStore.automaticMemoryLimitsDisabled(for: settings))
        #expect(ServerRuntimeSettingsStore.modelLoadRAMThresholds(for: settings).soft == 1.0)
        #expect(ServerRuntimeSettingsStore.modelLoadRAMThresholds(for: settings).hard == 1.0)
        #expect(
            ModelRuntime.flexibleResidentBudgetBytes(
                physicalMemoryBytes: 128 << 30,
                automaticMemoryLimitsDisabled: true
            ) == .max
        )
        #expect(ModelRuntime.cacheStorePolicy(for: settings).headroomFraction == 1.0)
    }

    @Test func explicitPhysicalFractionKeepsAUserSelectedLimit() {
        var settings = VMLXServerRuntimeSettings()
        settings.memorySafety.mode = .diagnosticDangerous
        settings.memorySafety.customPhysicalMemoryFraction = 0.82

        #expect(!ServerRuntimeSettingsStore.automaticMemoryLimitsDisabled(for: settings))
    }

    @Test func noAutomaticLimitsPreservesExplicitOverrides() {
        var settings = VMLXServerRuntimeSettings()
        settings.memorySafety.mode = .diagnosticDangerous
        settings.memorySafety.customPhysicalMemoryFraction = 0.82
        settings.memorySafety.customAllocatorCacheBytes = 256 << 20
        settings.memorySafety.customDefaultMaxKVSize = 32_768
        settings.memorySafety.customMaxConcurrentSequences = 3
        settings.cache.prefix.memoryPercent = 12

        let plan = ServerRuntimeSettingsStore.resolvedMemorySafetyPlan(for: settings)

        #expect(plan.loadConfiguration.memoryLimit == .fraction(0.82))
        #expect(plan.loadConfiguration.maxResidentBytes == .absolute(256 << 20))
        #expect(plan.resolvedLoadBudgetBytes != nil)
        #expect(plan.cache.prefix.memoryPercent == 12)
        #expect(plan.cache.defaultMaxKVSize == 32_768)
        #expect(plan.concurrency.maxConcurrentSequences == 3)
    }

    @Test func bundleSpecificPlanReportsItsActualRaisedLoadBudget() throws {
        let physical: UInt64 = 128 << 30
        let weights: UInt64 = 94 << 30
        let facts = LoadBundleFacts(
            totalSafetensorsBytes: weights,
            isRouted: true,
            physicalMemory: physical,
            modelType: "hy_v3",
            weightFormat: "jang-affine-mixed"
        )

        let plan = ServerRuntimeSettingsStore.resolvedMemorySafetyPlan(
            for: VMLXServerRuntimeSettings(),
            baseLoadConfiguration: .osaurusProduction,
            bundleFacts: facts
        )
        guard case .fraction(let actualFraction) = plan.loadConfiguration.memoryLimit else {
            Issue.record("Near-RAM Safe Auto plan must resolve to a fractional load budget.")
            return
        }
        let expectedBudget = UInt64(Double(physical) * actualFraction)

        #expect(!plan.loadConfiguration.useMmapSafetensors)
        #expect(plan.resolvedLoadBudgetBytes == expectedBudget)
        #expect(plan.displaySummary.contains("load_cap=0.79"))
    }

    @Test @MainActor func load_movesLegacyImplicitPrefixCapUnderMemorySafety() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var oldDefault = VMLXServerRuntimeSettings()
            oldDefault.cache.pagedKV.enabled = true
            oldDefault.cache.liveKVCodec = .none
            oldDefault.cache.enableSSMReDerive = false
            oldDefault.cache.defaultMaxKVSize = 65_536
            try writeSettings(oldDefault, to: dir)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())

            #expect(loaded.cache.prefix.memoryPercent == nil)
            #expect(
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(
                        ".server-runtime-memory-safety-cache-defaults-v4-migrated"
                    ).path
                )
            )
        }
    }

    @Test @MainActor func load_preservesExplicitPrefixCap() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var explicit = ServerRuntimeSettingsStore.migratedFromLegacy(
                serverConfiguration: .default,
                userDefaults: throwawayDefaults()
            )
            explicit.cache.prefix.memoryPercent = 12
            try writeSettings(explicit, to: dir)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())

            #expect(loaded.cache.prefix.memoryPercent == 12)
        }
    }

    @Test @MainActor func freshInstall_preservesLaterExplicitFifteenPercentCap() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var settings = ServerRuntimeSettingsStore.migratedFromLegacy(
                serverConfiguration: .default,
                userDefaults: throwawayDefaults()
            )
            settings.cache.prefix.memoryPercent = 15
            try writeSettings(settings, to: dir)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())

            #expect(loaded.cache.prefix.memoryPercent == 15)
        }
    }

    @Test @MainActor func save_thenLoadReturnsSameValue() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var settings = VMLXServerRuntimeSettings()
            settings.network.port = 4242
            settings.network.host = "0.0.0.0"
            settings.network.corsOrigins = ["https://example.com"]
            settings.generation.temperature = 0.42
            // Set an explicit non-default diffusion budget so the one-time
            // diffusion-defaults seed migration is a no-op here; this asserts
            // an explicit user value round-trips and is not clobbered on load.
            // (The seed only fills a nil field once, on first launch.)
            settings.generation.diffusionMaxDenoisingSteps = 24
            // Set an explicit (non-fp16) tied-head codec so the one-time q6
            // tied-head-default seed is a no-op here; this asserts an explicit
            // user codec round-trips and is not clobbered on load.
            settings.performance = VMLXServerPerformanceSettings(
                tiedHeadCodec: .q8,
                compiledDecode: false
            )
            settings.concurrency.maxConcurrentSequences = 5
            settings.cache.defaultMaxKVSize = 16_384
            settings.memorySafety.mode = .strict
            settings.memorySafety.slider = 3

            ServerRuntimeSettingsStore.save(settings)
            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = ServerRuntimeSettingsStore.load()

            #expect(loaded == settings)
            #expect(ServerRuntimeSettingsStore.snapshot() == settings)
        }
    }

    @Test @MainActor func load_seedsQ6TiedHeadDefault() async throws {
        // Fresh install (no codec ever chosen) should default the tied-head
        // codec to q6 — the GGUF-parity head bandwidth point and the largest
        // safe out-of-box Gemma 4 QAT speed lever.
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var settings = VMLXServerRuntimeSettings()
            settings.network.port = 4242
            // performance left nil (never configured)
            ServerRuntimeSettingsStore.save(settings)
            ServerRuntimeSettingsStore.invalidateSnapshot()

            let loaded = try #require(ServerRuntimeSettingsStore.load())
            #expect(loaded.effectivePerformance.tiedHeadCodec == .q6)
            // compiled decode stays OFF by default (correctness gate #1173).
            #expect(loaded.effectivePerformance.compiledDecode == false)
        }
    }

    @Test @MainActor func load_repairsOldPersistedMTPDefaultOffToAuto() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var oldDefault = VMLXServerRuntimeSettings()
            oldDefault.mtp.mode = .off
            try writeSettings(oldDefault, to: dir)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())
            #expect(loaded.mtp.mode == .auto)
            let repaired = try #require(ServerRuntimeSettingsStore.load())
            #expect(repaired.mtp.mode == .auto)
            let data = try Data(contentsOf: dir.appendingPathComponent("server-runtime.json"))
            let persisted = try JSONDecoder().decode(VMLXServerRuntimeSettings.self, from: data)
            #expect(persisted.mtp.mode == .auto)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let snapshot = ServerRuntimeSettingsStore.snapshot()
            #expect(snapshot.mtp.mode == .auto)
        }
    }

    @Test @MainActor func load_preservesExplicitNonDefaultMTPOff() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var explicitOff = VMLXServerRuntimeSettings()
            explicitOff.mtp.mode = .off
            explicitOff.mtp.draftTokenLimit = 2
            try writeSettings(explicitOff, to: dir)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())
            #expect(loaded.mtp.mode == .off)
            #expect(loaded.mtp.draftTokenLimit == 2)
        }
    }

    @Test @MainActor func load_repairsLegacyCacheDefaultsWithoutEnablingTurboQuant() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var oldDefault = VMLXServerRuntimeSettings()
            oldDefault.cache.pagedKV.enabled = true
            oldDefault.cache.liveKVCodec = .none
            oldDefault.cache.enableSSMReDerive = false
            oldDefault.cache.defaultMaxKVSize = 65536
            oldDefault.cache.longPromptMultiplier = 2.0
            try writeSettings(oldDefault, to: dir)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())
            #expect(loaded.cache.liveKVCodec == .none)
            #expect(loaded.cache.pagedKV.enabled == false)
            #expect(loaded.cache.enableSSMReDerive == true)

            let data = try Data(contentsOf: dir.appendingPathComponent("server-runtime.json"))
            let persisted = try JSONDecoder().decode(VMLXServerRuntimeSettings.self, from: data)
            #expect(persisted.cache.liveKVCodec == .none)
            #expect(persisted.cache.pagedKV.enabled == false)
            #expect(persisted.cache.enableSSMReDerive == true)
            #expect(
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(".server-runtime-cache-defaults-v2-migrated").path
                )
            )

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let snapshot = ServerRuntimeSettingsStore.snapshot()
            #expect(snapshot.cache.liveKVCodec == .none)
            #expect(snapshot.cache.pagedKV.enabled == false)
            #expect(snapshot.cache.enableSSMReDerive == true)
        }
    }

    @Test @MainActor func load_preservesExplicitCacheNoneAfterMigrationMarker() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var explicitNone = VMLXServerRuntimeSettings()
            explicitNone.cache.liveKVCodec = .none
            explicitNone.cache.enableSSMReDerive = false
            explicitNone.cache.defaultMaxKVSize = 65536
            explicitNone.cache.longPromptMultiplier = 2.0
            try writeSettings(explicitNone, to: dir)
            try Data().write(
                to: dir.appendingPathComponent(".server-runtime-cache-defaults-v2-migrated"),
                options: [.atomic]
            )

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())
            #expect(loaded.cache.liveKVCodec == .none)
            #expect(loaded.cache.enableSSMReDerive == false)
        }
    }

    @Test @MainActor func load_preservesAutoMigratedEngineSelectedCacheDefault() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var autoMigrated = VMLXServerRuntimeSettings()
            autoMigrated.cache.liveKVCodec = .engineSelected
            autoMigrated.cache.enableSSMReDerive = true
            autoMigrated.cache.defaultMaxKVSize = 65536
            autoMigrated.cache.longPromptMultiplier = 2.0
            autoMigrated.cache.legacyDisk = VMLXDiskCacheSettings(
                enabled: false,
                maxSizeGB: nil,
                directory: nil
            )
            autoMigrated.cache.blockDisk = VMLXBlockDiskCacheSettings(
                enabled: true,
                maxSizeGB: nil,
                directory: nil
            )
            try writeSettings(autoMigrated, to: dir)
            try Data().write(
                to: dir.appendingPathComponent(".server-runtime-cache-defaults-v2-migrated"),
                options: [.atomic]
            )

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())
            #expect(loaded.cache.liveKVCodec == .engineSelected)
            #expect(loaded.cache.enableSSMReDerive == true)

            let data = try Data(contentsOf: dir.appendingPathComponent("server-runtime.json"))
            let persisted = try JSONDecoder().decode(VMLXServerRuntimeSettings.self, from: data)
            #expect(persisted.cache.liveKVCodec == .engineSelected)
        }
    }

    @Test @MainActor func load_preservesExplicitEngineSelectedWithoutMigrationMarker() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var explicitEngineSelected = VMLXServerRuntimeSettings()
            explicitEngineSelected.cache.liveKVCodec = .engineSelected
            explicitEngineSelected.cache.enableSSMReDerive = true
            try writeSettings(explicitEngineSelected, to: dir)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())
            #expect(loaded.cache.liveKVCodec == .engineSelected)
        }
    }

    @Test @MainActor func load_repairsOldEngineSelectedPagedCacheDefaultToOff() async throws {
        let dir = try makeTempDirectory()
        try await withOverriddenDirectory(dir) {
            var oldDefault = VMLXServerRuntimeSettings()
            oldDefault.cache.pagedKV.enabled = true
            oldDefault.cache.liveKVCodec = .engineSelected
            oldDefault.cache.enableSSMReDerive = true
            oldDefault.cache.defaultMaxKVSize = 65536
            oldDefault.cache.longPromptMultiplier = 2.0
            oldDefault.cache.legacyDisk = VMLXDiskCacheSettings(
                enabled: false,
                maxSizeGB: nil,
                directory: nil
            )
            oldDefault.cache.blockDisk = VMLXBlockDiskCacheSettings(
                enabled: true,
                maxSizeGB: nil,
                directory: nil
            )
            try writeSettings(oldDefault, to: dir)

            ServerRuntimeSettingsStore.invalidateSnapshot()
            let loaded = try #require(ServerRuntimeSettingsStore.load())
            #expect(loaded.cache.pagedKV.enabled == false)
            #expect(loaded.cache.liveKVCodec == .engineSelected)
            #expect(loaded.cache.blockDisk.enabled == true)

            let data = try Data(contentsOf: dir.appendingPathComponent("server-runtime.json"))
            let persisted = try JSONDecoder().decode(VMLXServerRuntimeSettings.self, from: data)
            #expect(persisted.cache.pagedKV.enabled == false)
            #expect(
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(".server-runtime-paged-cache-default-off-v3-migrated").path
                )
            )
        }
    }

    @Test func migratedFromLegacy_projectsCorsAndPort() async throws {
        var legacy = ServerConfiguration.default
        legacy.port = 9000
        legacy.exposeToNetwork = true
        legacy.allowedOrigins = ["https://a.example", "https://b.example"]
        legacy.genTopP = 0.42

        let migrated = ServerRuntimeSettingsStore.migratedFromLegacy(
            serverConfiguration: legacy,
            userDefaults: throwawayDefaults()
        )

        #expect(migrated.network.port == 9000)
        #expect(migrated.network.host == "0.0.0.0")
        #expect(migrated.network.corsOrigins == ["https://a.example", "https://b.example"])
        // Only non-default top-p values flow into the runtime store.
        // Float → Double round-trips through `Float`, so we compare
        // against the rounded value rather than the literal 0.42.
        let topP = try #require(migrated.generation.topP)
        #expect(abs(topP - 0.42) < 1e-5)
    }

    @Test func migratedFromLegacy_seedsConcurrencyFromUserDefaults() async throws {
        let defaults = throwawayDefaults()
        defaults.set(6, forKey: "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize")

        let migrated = ServerRuntimeSettingsStore.migratedFromLegacy(
            serverConfiguration: .default,
            userDefaults: defaults
        )

        #expect(migrated.concurrency.maxConcurrentSequences == 6)
    }

    @Test func projectIntoLegacy_mirrorsRuntimeChangesIntoServerConfiguration() async throws {
        let base = ServerConfiguration.default
        var settings = VMLXServerRuntimeSettings()
        settings.network.port = 8080
        settings.network.host = "0.0.0.0"
        settings.network.corsOrigins = ["*", "https://app.example"]
        settings.generation.topP = 0.85

        let projected = ServerRuntimeSettingsStore.projectIntoLegacy(
            settings,
            base: base
        )

        #expect(projected.port == 8080)
        #expect(projected.exposeToNetwork == true)
        // The "*" sentinel is dropped — legacy uses an empty array
        // to mean "no extra origins beyond the implicit loopback".
        #expect(projected.allowedOrigins == ["https://app.example"])
        #expect(abs(projected.genTopP - 0.85) < 1e-5)
    }

    @Test func projectIntoLegacy_clearsLegacyTopPWhenRuntimeTopPIsModelDefault() async throws {
        var base = ServerConfiguration.default
        base.genTopP = 0.42

        var settings = VMLXServerRuntimeSettings()
        settings.generation.topP = nil

        let projected = ServerRuntimeSettingsStore.projectIntoLegacy(
            settings,
            base: base
        )

        #expect(projected.genTopP == ServerConfiguration.default.genTopP)
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "osaurus-runtime-settings-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func throwawayDefaults() -> UserDefaults {
        let suite = "ai.osaurus.test.runtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func writeSettings(
        _ settings: VMLXServerRuntimeSettings,
        to dir: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings)
            .write(to: dir.appendingPathComponent("server-runtime.json"), options: [.atomic])
    }

    @MainActor
    private func withOverriddenDirectory(
        _ dir: URL,
        _ body: () async throws -> Void
    ) async throws {
        let previous = ServerRuntimeSettingsStore.overrideDirectory
        ServerRuntimeSettingsStore.overrideDirectory = dir
        ServerRuntimeSettingsStore.invalidateSnapshot()
        defer {
            ServerRuntimeSettingsStore.overrideDirectory = previous
            ServerRuntimeSettingsStore.invalidateSnapshot()
            try? FileManager.default.removeItem(at: dir)
        }
        try await body()
    }
}
