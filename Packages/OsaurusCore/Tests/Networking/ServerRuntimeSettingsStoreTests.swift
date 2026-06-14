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
