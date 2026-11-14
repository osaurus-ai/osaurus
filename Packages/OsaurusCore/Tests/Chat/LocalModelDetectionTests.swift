//
//  LocalModelDetectionTests.swift
//  OsaurusCoreTests
//
//  Pins the contract for `ChatSession.selectedModelIsLocal` /
//  `isStreamingLocalModel` — the detection that gates the "one local
//  generation at a time, never interrupt an in-flight chat" behavior. A
//  model counts as local iff it resolves in the installed-model catalog
//  (`ModelManager.findInstalledModel`). That catalog merges osaurus-downloaded
//  models with externally-discovered ones (LM Studio, Hugging Face cache); the
//  external discovery/merge itself is covered by `ModelManagerTests`, so here
//  we drive the catalog through `scanLocalModelsOverrideForTests` and assert
//  the session helpers reflect it. A model's external-source origin must not
//  change detection — it's still local.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct LocalModelDetectionTests {

    /// Catalog fixtures: one osaurus-downloaded model and one carrying an
    /// external-source label (as LM Studio / HF-cache models do).
    private static let catalog: [MLXModel] = [
        MLXModel(
            id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            name: "Qwen2.5 7B",
            description: "fixture",
            downloadURL: "https://example.invalid/qwen"
        ),
        MLXModel(
            id: "lmstudio-community/Llama-3.2-3B-Instruct",
            name: "Llama 3.2 3B",
            description: "fixture-external",
            downloadURL: "https://example.invalid/llama",
            externalSource: "LM Studio"
        ),
    ]

    /// Install a deterministic local-model catalog for the duration of `body`.
    /// Must run inside `ChatHistoryTestStorage.run`, which holds
    /// `StoragePathsTestLock` — the same lock the model-scan overrides are
    /// mutated under elsewhere — so these globals can't race other suites.
    private func withCatalog(_ models: [MLXModel], scanBarrier: (@Sendable () -> Void)? = nil, _ body: () throws -> Void) async throws {
        let prevScan = ModelManager.scanLocalModelsOverrideForTests
        let prevWait = ModelManager.localModelsScanWaitLimitOverrideForTests
        let prevExternal = ExternalModelLocator.testRootsOverride

        // No real external roots — the catalog comes entirely from the scan
        // override so the result is deterministic.
        ExternalModelLocator.testRootsOverride = []
        ExternalModelLocator.invalidateInMemory()
        _ = ExternalModelLocator.rescan()
        ModelManager.localModelsScanWaitLimitOverrideForTests = 2.0
        ModelManager.scanLocalModelsOverrideForTests = { _ in scanBarrier?(); return models }
        ModelManager.invalidateLocalModelsCache()
        defer {
            ModelManager.scanLocalModelsOverrideForTests = prevScan
            ModelManager.localModelsScanWaitLimitOverrideForTests = prevWait
            ExternalModelLocator.testRootsOverride = prevExternal
            ExternalModelLocator.invalidateInMemory()
            ModelManager.invalidateLocalModelsCache()
        }

        // The ordinary discovery wait can time out with a provisional empty
        // result. Cache-only UI getters require actual publication, not merely
        // return from that bounded scan API. Yield the main actor while waiting.
        _ = ModelManager.localModelsSnapshotNonBlocking()
        let deadline = ContinuousClock.now + .seconds(10)
        while !ModelManager.isLocalModelsCacheWarm, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ModelManager.isLocalModelsCacheWarm, "Fixture scan did not publish its catalog")
        try body()
    }

    @Test
    func selectedModelIsLocal_matchesCatalogByRepoTailAndFullId() async throws {
        try await ChatHistoryTestStorage.run {
            try await withCatalog(Self.catalog) {
                let session = ChatSession()

                // Repo-tail (the form the picker selects with).
                session.selectedModel = "Qwen2.5-7B-Instruct-4bit"
                #expect(session.selectedModelIsLocal)

                // Full provider/repo id.
                session.selectedModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
                #expect(session.selectedModelIsLocal)
            }
        }
    }

    @Test
    func selectedModelIsLocal_coversExternallyDiscoveredModels() async throws {
        try await ChatHistoryTestStorage.run {
            try await withCatalog(Self.catalog) {
                let session = ChatSession()

                // A model whose origin is an external tool (LM Studio / HF
                // cache) still resolves as local — its source label doesn't
                // change detection.
                session.selectedModel = "Llama-3.2-3B-Instruct"
                #expect(session.selectedModelIsLocal)
            }
        }
    }

    @Test
    func selectedModelIsLocal_falseForRemoteFoundationAndUnknown() async throws {
        try await ChatHistoryTestStorage.run {
            try await withCatalog(Self.catalog) {
                let session = ChatSession()

                // Apple's on-device Foundation model runs on a separate engine.
                session.selectedModel = "foundation"
                #expect(!session.selectedModelIsLocal)

                // Remote provider model id (not in the local catalog).
                session.selectedModel = "openai/gpt-4o"
                #expect(!session.selectedModelIsLocal)

                // Unknown id.
                session.selectedModel = "not-a-real-model"
                #expect(!session.selectedModelIsLocal)

                // No selection.
                session.selectedModel = nil
                #expect(!session.selectedModelIsLocal)
            }
        }
    }

    @Test
    func isStreamingLocalModel_composesStreamingStateWithLocality() async throws {
        try await ChatHistoryTestStorage.run {
            try await withCatalog(Self.catalog) {
                let session = ChatSession()
                session.selectedModel = "Qwen2.5-7B-Instruct-4bit"

                // Local but idle → not a live local generation.
                session.isStreaming = false
                #expect(!session.isStreamingLocalModel)

                // Local and streaming → live local generation.
                session.isStreaming = true
                #expect(session.isStreamingLocalModel)

                // Streaming a remote model → does not count as local.
                session.selectedModel = "openai/gpt-4o"
                #expect(!session.isStreamingLocalModel)

                // Balance the perf-trace begun by the `isStreaming` setter.
                session.isStreaming = false
            }
        }
    }
    @Test
    func catalogFixtureWaitsForPublicationBeforeRunningAssertions() async throws {
        try await ChatHistoryTestStorage.run {
            let gate = LocalityScanGate()
            var enteredBody = false
            let task = Task { @MainActor in
                try await withCatalog(Self.catalog, scanBarrier: { gate.scan() }) {
                    enteredBody = true
                    #expect(ModelManager.isLocalModelsCacheWarm)
                }
            }
            defer { gate.release() }
            do {
                let deadline = ContinuousClock.now + .seconds(10)
                while !gate.started, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(gate.started)
                let enteredBeforeRelease = enteredBody
                gate.release()
                try await task.value
                #expect(!enteredBeforeRelease, "Fixture body must not run while its scan is still blocked")
                #expect(enteredBody)
                #expect(!gate.timedOut)
            } catch {
                gate.release()
                task.cancel()
                // Join before the storage lock and override scope can unwind.
                _ = await task.result
                throw error
            }
        }
    }

}

private final class LocalityScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didStart = false
    private var didTimeOut = false
    var started: Bool { lock.withLock { didStart } }
    var timedOut: Bool { lock.withLock { didTimeOut } }
    func scan() {
        lock.withLock { didStart = true }
        let result = semaphore.wait(timeout: .now() + 10)
        lock.withLock { didTimeOut = result == .timedOut }
    }
    func release() { semaphore.signal() }
}
