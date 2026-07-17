//
//  PalaceConfigurationTests.swift
//  osaurusTests
//
//  Palace ships disabled: a fresh install must load `enabled == false`
//  and a missing palace.json must NOT be auto-created (see the
//  RemoteProviderConfigurationStore.load data-loss rationale).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PalaceConfigurationTests {

    /// Runs `body` against an isolated OsaurusPaths root.
    /// `overrideRoot` is process-global, so take the cross-suite lock.
    private func withTempRoot<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("palace-config-tests-\(UUID().uuidString)", isDirectory: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            PalaceConfigurationStore.invalidateCache()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                PalaceConfigurationStore.invalidateCache()
                try? FileManager.default.removeItem(at: root)
            }
            return try await body()
        }
    }

    @Test func defaults_are_disabled() {
        let config = PalaceConfiguration()
        #expect(config.enabled == false)
        #expect(config.embeddingBackend == "mlx")
        #expect(config.defaultWing == "default")
        #expect(config.searchDefaultLimit == 5)
        #expect(config.maxDistance == 1.5)
    }

    @Test func missing_file_loads_default_and_does_not_write() async {
        await withTempRoot {
            let loaded = PalaceConfigurationStore.load()
            #expect(loaded.enabled == false)
            #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.palaceConfigFile().path))
        }
    }

    @Test func partial_json_decodes_with_defaults() async throws {
        try await withTempRoot {
            let url = OsaurusPaths.palaceConfigFile()
            try OsaurusPaths.ensureExists(url.deletingLastPathComponent())
            try Data(#"{"enabled": true}"#.utf8).write(to: url)
            let loaded = PalaceConfigurationStore.load()
            #expect(loaded.enabled == true)
            #expect(loaded.searchDefaultLimit == 5)  // default survives partial file
        }
    }

    @Test func save_load_round_trip() async {
        await withTempRoot {
            var config = PalaceConfiguration()
            config.enabled = true
            config.defaultWing = "vault"
            PalaceConfigurationStore.save(config)
            PalaceConfigurationStore.invalidateCache()
            let loaded = PalaceConfigurationStore.load()
            #expect(loaded.enabled == true)
            #expect(loaded.defaultWing == "vault")
        }
    }

    @Test func validated_clamps_out_of_range_values() {
        var config = PalaceConfiguration()
        config.searchDefaultLimit = 10_000
        config.maxDistance = 99
        config.defaultWing = "   "
        let validated = config.validated()
        #expect(validated.searchDefaultLimit == 50)
        #expect(validated.maxDistance == 2.0)
        #expect(validated.defaultWing == "default")
    }

    @Test func paths_resolve_under_root() async {
        await withTempRoot {
            #expect(OsaurusPaths.palaceDatabaseFile().path.hasSuffix("palace/palace.sqlite"))
            #expect(OsaurusPaths.palaceConfigFile().path.hasSuffix("config/palace.json"))
        }
    }

    /// Hand-editing palace.json is the only enable/disable mechanism until
    /// a Settings UI ships — the mtime-keyed cache must pick the edit up
    /// WITHOUT an app restart (and without a test-only invalidateCache()).
    @Test func hand_edit_after_cached_load_is_picked_up() async throws {
        try await withTempRoot {
            let url = OsaurusPaths.palaceConfigFile()
            try OsaurusPaths.ensureExists(url.deletingLastPathComponent())
            try Data(#"{"enabled": true}"#.utf8).write(to: url)
            #expect(PalaceConfigurationStore.load().enabled == true)
            // Cached now. Hand-edit the file (bump mtime explicitly so the
            // test doesn't depend on filesystem timestamp granularity).
            try Data(#"{"enabled": false}"#.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)],
                ofItemAtPath: url.path
            )
            #expect(PalaceConfigurationStore.load().enabled == false)
            // Deleting the file falls back to the shipped default (disabled).
            try FileManager.default.removeItem(at: url)
            #expect(PalaceConfigurationStore.load().enabled == false)
        }
    }
}
