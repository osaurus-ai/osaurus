//
//  ModelPickerItemCacheTests.swift
//  osaurusTests
//
//  Regression tests for the launch-time race that caused remote-provider
//  models to disappear from the model picker until the user disconnected
//  and reconnected the provider.
//
//  The cache is a process-wide singleton driven by NotificationCenter, so
//  these tests mostly verify invariants of the serialized rebuild path:
//
//  1. Concurrent callers of `buildModelPickerItems()` are coalesced and all
//     return the same final list.
//  2. `items` is never transiently emptied while a rebuild is in flight
//     (the bug previously was caused by `invalidateCache()` running inside
//     the notification observer).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ModelPickerItemCacheTests {

    /// Hammer the cache from many concurrent tasks. Because the underlying
    /// state (foundation availability, local models, remote providers) does
    /// not change during the test, every concurrent caller MUST observe the
    /// same final result. Before the fix, two concurrent rebuilds — one
    /// with `includeRemote: false` (the old `prewarmLocalModelsOnly`) and
    /// one with `includeRemote: true` — could finish in non-deterministic
    /// order, so callers could disagree about whether remote models were
    /// present.
    @Test func concurrentCallers_returnIdenticalResults() async throws {
        await RemoteProviderTestLock.shared.run {
            // Establish a baseline so we know what to compare against, and so
            // any work needed to populate the cache (e.g. local model
            // discovery) doesn't perturb the concurrent run below.
            let baselineItems = await ModelPickerItemCache.shared.buildModelPickerItems()
            let baselineIds = baselineItems.map(\.id)

            // Spawn many detached tasks that each call into the @MainActor
            // cache. Detached tasks are deliberately used so the calls hop
            // back into the MainActor at the await point and exercise the
            // serialized rebuild path the way real callers do (notification
            // observer Tasks, the AppDelegate prewarm Task, ChatView's
            // refresh Task, and so on).
            var tasks: [Task<[String], Never>] = []
            for _ in 0 ..< 32 {
                tasks.append(
                    Task.detached {
                        let items = await ModelPickerItemCache.shared.buildModelPickerItems()
                        return items.map(\.id)
                    }
                )
            }

            for task in tasks {
                let ids = await task.value
                #expect(ids == baselineIds)
            }
            #expect(ModelPickerItemCache.shared.isLoaded)
        }
    }

    /// Posting a burst of `.remoteProviderModelsChanged` notifications used
    /// to call `invalidateCache()` inside the observer Task, blanking
    /// `items` to `[]` until the rebuild's detached local-discovery task
    /// resumed. Anyone reading `cache.items` during that window — most
    /// notably `ChatView.init` — would snapshot an empty list. This test
    /// asserts the invariant that, once populated, `items` never goes
    /// empty across rebuilds.
    @Test func notificationBurst_doesNotTransientlyEmptyItems() async throws {
        await RemoteProviderTestLock.shared.run {
            let cache = ModelPickerItemCache.shared

            // Make sure we start populated. If this machine has no foundation
            // model, no local MLX models, and no connected remote providers,
            // the invariant is trivially satisfied - skip in that case so CI
            // doesn't false-positive.
            _ = await cache.buildModelPickerItems()
            guard !cache.items.isEmpty else { return }
            let initialCount = cache.items.count

            // Spam many notifications. Each one schedules an observer Task
            // that calls `buildModelPickerItems()`. Pre-fix, each Task would
            // first set `items = []` and `isLoaded = false`.
            for _ in 0 ..< 50 {
                NotificationCenter.default.post(
                    name: .remoteProviderModelsChanged,
                    object: nil
                )
            }

            // Drain the observer Tasks by repeatedly yielding the MainActor
            // and sampling `items`. With the fix, every sample must be
            // non-empty - the rebuild only assigns `items` when it has the
            // full list.
            var samples: [Int] = []
            for _ in 0 ..< 200 {
                samples.append(cache.items.count)
                try? await Task.sleep(nanoseconds: 200_000)  // 0.2ms
            }

            #expect(
                !samples.contains(0),
                "items must remain populated during rebuilds; observed sample counts: \(samples)"
            )

            // After the burst settles, the cache should still hold a
            // populated list (state hasn't actually changed, so it should
            // match the initial count).
            let final = await cache.buildModelPickerItems()
            #expect(!final.isEmpty)
            #expect(final.count == initialCount)
        }
    }

    /// Embedding/encoder-only bundles (e.g. potion-base-4M pulled into the
    /// HF cache by the memory feature) must be excluded from the chat
    /// picker's item list, while regular causal-LM bundles pass through.
    @Test func computeItems_excludesLocalEmbeddingBundles() async throws {
        try await RemoteProviderTestLock.shared.run {
            // Two on-disk fixture bundles classified purely via config.json.
            func makeBundle(config: [String: Any]) throws -> URL {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "osu-picker-cache-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
                try JSONSerialization.data(withJSONObject: config)
                    .write(to: dir.appendingPathComponent("config.json"))
                return dir
            }
            let chatDir = try makeBundle(config: [
                "model_type": "qwen2",
                "architectures": ["Qwen2ForCausalLM"],
            ])
            let embedDir = try makeBundle(config: [
                "model_type": "model2vec",
                "architectures": ["StaticModel"],
            ])

            let fixtures = [
                MLXModel(
                    id: "fixture/chat-model-4bit",
                    name: "Fixture Chat Model",
                    description: "fixture",
                    downloadURL: "https://example.invalid/chat",
                    bundleDirectory: chatDir
                ),
                MLXModel(
                    id: "fixture/potion-base-4M",
                    name: "Fixture Embedding Model",
                    description: "fixture",
                    downloadURL: "https://example.invalid/potion",
                    bundleDirectory: embedDir
                ),
            ]

            let prevScan = ModelManager.scanLocalModelsOverrideForTests
            let prevWait = ModelManager.localModelsScanWaitLimitOverrideForTests
            ModelManager.localModelsScanWaitLimitOverrideForTests = 2.0
            ModelManager.scanLocalModelsOverrideForTests = { _ in fixtures }
            ModelManager.invalidateLocalModelsCache()

            let items = await ModelPickerItemCache.shared.buildModelPickerItems()
            let ids = items.map(\.id)

            // Restore globals and rebuild before asserting so fixture
            // entries can't linger in the shared cache for later suites.
            ModelManager.scanLocalModelsOverrideForTests = prevScan
            ModelManager.localModelsScanWaitLimitOverrideForTests = prevWait
            ModelManager.invalidateLocalModelsCache()
            await ModelPickerItemCache.shared.buildModelPickerItems()
            try? FileManager.default.removeItem(at: chatDir)
            try? FileManager.default.removeItem(at: embedDir)

            #expect(ids.contains("fixture/chat-model-4bit"))
            #expect(!ids.contains("fixture/potion-base-4M"))
        }
    }
}
