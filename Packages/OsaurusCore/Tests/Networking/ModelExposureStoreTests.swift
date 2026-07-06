//
//  ModelExposureStoreTests.swift
//  OsaurusCoreTests
//
//  Per-model API exposure: local models list by default, remote models are
//  hidden until opted in, and only explicit user toggles persist. Also pins
//  the remote-listing filter in `RemoteProviderManager.getOpenAIModels()`.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelExposureStoreTests {

    // MARK: - Defaults

    @Test func defaults_localExposed_remoteHidden() throws {
        let settings = ModelExposureSettings()
        #expect(settings.isExposed(id: "qwen3-4b-4bit", kind: .local))
        #expect(settings.isExposed(id: "foundation", kind: .local))
        #expect(!settings.isExposed(id: "osaurus/openai/gpt-5.2", kind: .remote))
    }

    @Test func overrides_winOverDefaults() throws {
        let settings = ModelExposureSettings(overrides: [
            "qwen3-4b-4bit": false,
            "osaurus/openai/gpt-5.2": true,
        ])
        #expect(!settings.isExposed(id: "qwen3-4b-4bit", kind: .local))
        #expect(settings.isExposed(id: "osaurus/openai/gpt-5.2", kind: .remote))
        // Untouched ids still resolve to their kind default.
        #expect(settings.isExposed(id: "other-local", kind: .local))
        #expect(!settings.isExposed(id: "osaurus/other", kind: .remote))
    }

    // MARK: - Store round-trip

    @Test func store_roundTrip_persistsOnlyExplicitOverrides() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ModelExposureStore(overrideDirectory: dir)
        store.setExposed(false, id: "hidden-local", kind: .local)
        store.setExposed(true, id: "osaurus/openai/gpt-5.2", kind: .remote)
        // Setting the default value must not create an override entry.
        store.setExposed(true, id: "default-local", kind: .local)
        store.setExposed(false, id: "osaurus/default-remote", kind: .remote)

        // A fresh store instance reads the same file back from disk.
        let reloaded = ModelExposureStore(overrideDirectory: dir)
        let settings = reloaded.settings()
        #expect(
            settings.overrides == [
                "hidden-local": false,
                "osaurus/openai/gpt-5.2": true,
            ]
        )
        #expect(!reloaded.isExposed(id: "hidden-local", kind: .local))
        #expect(reloaded.isExposed(id: "osaurus/openai/gpt-5.2", kind: .remote))
        #expect(reloaded.isExposed(id: "default-local", kind: .local))
        #expect(!reloaded.isExposed(id: "osaurus/default-remote", kind: .remote))
    }

    @Test func store_togglingBackToDefault_removesOverride() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ModelExposureStore(overrideDirectory: dir)
        store.setExposed(false, id: "model-a", kind: .local)
        #expect(store.settings().overrides["model-a"] == false)

        store.setExposed(true, id: "model-a", kind: .local)
        #expect(store.settings().overrides.isEmpty)
    }

    @Test func store_bulkToggle_appliesToAllIds() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ModelExposureStore(overrideDirectory: dir)
        let ids = ["osaurus/a", "osaurus/b", "osaurus/c"]
        store.setExposed(true, ids: ids, kind: .remote)
        for id in ids {
            #expect(store.isExposed(id: id, kind: .remote))
        }

        // Bulk-hiding remotes restores the default, clearing every override.
        store.setExposed(false, ids: ids, kind: .remote)
        #expect(store.settings().overrides.isEmpty)
        for id in ids {
            #expect(!store.isExposed(id: id, kind: .remote))
        }
    }

    @Test func store_absentFile_yieldsDefaults() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ModelExposureStore(overrideDirectory: dir)
        #expect(store.settings().overrides.isEmpty)
        #expect(store.isExposed(id: "any-local", kind: .local))
        #expect(!store.isExposed(id: "any/remote", kind: .remote))
    }

    private func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("osaurus-model-exposure-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Remote listing filter

/// `getOpenAIModels()` feeds `/models`, `/tags`, and the plugin `list_models`
/// surface; these tests pin its default-hidden behavior for remote models.
/// Serialized because they mutate the shared exposure store and the shared
/// `RemoteProviderManager`.
@Suite(.serialized)
struct RemoteModelExposureFilterTests {

    @Test @MainActor func getOpenAIModels_hidesRemoteModelsByDefault() async throws {
        let dir = try makeTempDirectory()
        ModelExposureStore.shared.overrideDirectory = dir
        defer {
            ModelExposureStore.shared.overrideDirectory = nil
            try? FileManager.default.removeItem(at: dir)
        }

        let manager = RemoteProviderManager.shared
        let provider = RemoteProvider(name: "Test Remote", host: "api.example.com")
        manager._testInstallConnectedProvider(provider, discoveredModels: ["model-a", "model-b"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let ids = manager.getOpenAIModels().map(\.id)
        #expect(!ids.contains("test-remote/model-a"))
        #expect(!ids.contains("test-remote/model-b"))
    }

    @Test @MainActor func getOpenAIModels_listsOnlyExposedRemoteModels() async throws {
        let dir = try makeTempDirectory()
        ModelExposureStore.shared.overrideDirectory = dir
        defer {
            ModelExposureStore.shared.overrideDirectory = nil
            try? FileManager.default.removeItem(at: dir)
        }

        let manager = RemoteProviderManager.shared
        let provider = RemoteProvider(name: "Test Remote", host: "api.example.com")
        manager._testInstallConnectedProvider(provider, discoveredModels: ["model-a", "model-b"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        ModelExposureStore.shared.setExposed(true, id: "test-remote/model-b", kind: .remote)

        let ids = manager.getOpenAIModels().map(\.id)
        #expect(!ids.contains("test-remote/model-a"))
        #expect(ids.contains("test-remote/model-b"))
    }

    private func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("osaurus-model-exposure-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
