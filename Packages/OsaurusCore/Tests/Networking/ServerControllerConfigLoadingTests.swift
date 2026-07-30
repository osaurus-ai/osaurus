//
//  ServerControllerConfigLoadingTests.swift
//  osaurusTests
//

import Foundation
@preconcurrency import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ServerControllerConfigLoadingTests {

    @Test @MainActor func controllerLoadsSavedConfigurationOnInit() async throws {
        // Isolate store to a temp directory
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent(
            "osaurus-config-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ServerConfigurationStore.overrideDirectory = dir
        defer {
            ServerConfigurationStore.overrideDirectory = nil
            try? FileManager.default.removeItem(at: dir)
        }

        var config = ServerConfiguration.default
        config.port = 4242
        config.exposeToNetwork = true
        ServerConfigurationStore.save(config)

        let controller = ServerController()
        #expect(controller.configuration.port == 4242)
        #expect(controller.configuration.exposeToNetwork == true)
    }

    @Test @MainActor
    func controllerFollowsOffActorRuntimeSettingsStoreSave() async throws {
        let base = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        let dir = base.appendingPathComponent(
            "osaurus-runtime-controller-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        let previousRuntimeDirectory =
            ServerRuntimeSettingsStore.overrideDirectory
        let previousConfigurationDirectory =
            ServerConfigurationStore.overrideDirectory
        ServerRuntimeSettingsStore.overrideDirectory = dir
        ServerRuntimeSettingsStore.invalidateSnapshot()
        ServerConfigurationStore.overrideDirectory = dir
        defer {
            ServerRuntimeSettingsStore.overrideDirectory =
                previousRuntimeDirectory
            ServerRuntimeSettingsStore.invalidateSnapshot()
            ServerConfigurationStore.overrideDirectory =
                previousConfigurationDirectory
            try? FileManager.default.removeItem(at: dir)
        }

        var legacy = ServerConfiguration.default
        legacy.exposeToNetwork = true
        ServerConfigurationStore.save(legacy)

        var explicit = VMLXServerRuntimeSettings()
        explicit.network.host = "0.0.0.0"
        explicit.concurrency.maxConcurrentSequences = 8
        ServerRuntimeSettingsStore.save(explicit)

        let controller = ServerController()
        #expect(
            controller.runtimeSettings.concurrency
                .maxConcurrentSequences == 8
        )

        var automatic = explicit
        automatic.concurrency.maxConcurrentSequences = nil
        await Task.detached {
            ServerRuntimeSettingsStore.save(automatic)
        }.value

        for _ in 0 ..< 50 {
            await Self.drainMainQueue()
            if controller.runtimeSettings.concurrency
                .maxConcurrentSequences == nil
            {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            controller.runtimeSettings.concurrency
                .maxConcurrentSequences == nil
        )
    }

    @Test @MainActor
    func mainChatAndServerConcurrencyStayBidirectionallySynchronized() async throws {
        let base = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        let dir = base.appendingPathComponent(
            "osaurus-spawn-concurrency-sync-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        let previousRuntimeDirectory =
            ServerRuntimeSettingsStore.overrideDirectory
        let previousConfigurationDirectory =
            ServerConfigurationStore.overrideDirectory
        ServerRuntimeSettingsStore.overrideDirectory = dir
        ServerRuntimeSettingsStore.invalidateSnapshot()
        ServerConfigurationStore.overrideDirectory = dir
        SubagentConfigurationStore.setOverrideDirectory(dir)
        defer {
            SubagentConfigurationStore.flushPendingWrites()
            SubagentConfigurationStore.setOverrideDirectory(nil)
            ServerRuntimeSettingsStore.overrideDirectory =
                previousRuntimeDirectory
            ServerRuntimeSettingsStore.invalidateSnapshot()
            ServerConfigurationStore.overrideDirectory =
                previousConfigurationDirectory
            try? FileManager.default.removeItem(at: dir)
        }

        var serverSettings = VMLXServerRuntimeSettings()
        serverSettings.concurrency.maxConcurrentSequences = 2
        ServerRuntimeSettingsStore.save(serverSettings)

        var mainChat = SubagentConfiguration.default
        mainChat.budgets.maxParallelSpawns = 7
        SubagentConfigurationStore.save(mainChat)
        SubagentConfigurationStore.flushPendingWrites()
        // Drain pre-controller store notifications so other global listeners
        // cannot leak work into the assertions below.
        await Self.drainMainQueue()

        let controller = ServerController()
        #expect(
            SubagentConfigurationStore.snapshot().budgets
                .maxParallelSpawns == 2
        )

        let mainChatEdit = SubagentConfigurationStore.mutate { configuration in
            configuration.budgets.maxParallelSpawns = 5
        }
        await controller.applyMainChatBatchLimit(from: mainChatEdit)
        #expect(
            controller.runtimeSettings.concurrency
                .maxConcurrentSequences == 5
        )
        #expect(
            ServerRuntimeSettingsStore.snapshot().concurrency
                .maxConcurrentSequences == 5
        )

        await controller.applySpawnBatchLimit(4)
        #expect(
            controller.runtimeSettings.concurrency
                .maxConcurrentSequences == 4
        )
        #expect(
            SubagentConfigurationStore.snapshot().budgets
                .maxParallelSpawns == 4
        )

        var serverEdit = controller.runtimeSettings
        serverEdit.concurrency.maxConcurrentSequences = 3
        ServerRuntimeSettingsStore.save(serverEdit)
        for _ in 0 ..< 100 {
            await Self.drainMainQueue()
            if controller.runtimeSettings.concurrency
                .maxConcurrentSequences == 3,
                SubagentConfigurationStore.snapshot().budgets
                    .maxParallelSpawns == 3
            {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            controller.runtimeSettings.concurrency
                .maxConcurrentSequences == 3
        )
        #expect(
            SubagentConfigurationStore.snapshot().budgets
                .maxParallelSpawns == 3
        )

        // Clearing Server back to Automatic mirrors the resolved safe value
        // into Spawn without creating an explicit override. A later explicit
        // Spawn edit to that SAME visible value must still materialize it.
        var automatic = controller.runtimeSettings
        automatic.concurrency.maxConcurrentSequences = nil
        let automaticResolved =
            SpawnBatchConcurrencyContract.configuredLimit(for: automatic)
        ServerRuntimeSettingsStore.save(automatic)
        for _ in 0 ..< 100 {
            await Self.drainMainQueue()
            if controller.runtimeSettings.concurrency
                .maxConcurrentSequences == nil,
                SubagentConfigurationStore.snapshot().budgets
                    .maxParallelSpawns == automaticResolved
            {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(
            controller.runtimeSettings.concurrency
                .maxConcurrentSequences == nil
        )
        #expect(
            SubagentConfigurationStore.snapshot().budgets
                .maxParallelSpawns == automaticResolved
        )

        await controller.applySpawnBatchLimit(automaticResolved)
        #expect(
            controller.runtimeSettings.concurrency
                .maxConcurrentSequences == automaticResolved
        )
        #expect(
            ServerRuntimeSettingsStore.snapshot().concurrency
                .maxConcurrentSequences == automaticResolved
        )
    }

    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test func loadedModelRefreshInputs_coverCacheMemorySafetyMultimodalAndMTP() {
        let base = VMLXServerRuntimeSettings()

        var cacheChanged = base
        cacheChanged.cache.blockDisk.enabled = false
        #expect(
            ServerController.loadedModelRuntimeInputsRequireRefresh(
                previous: base,
                next: cacheChanged
            )
        )

        var turboQuantChanged = base
        turboQuantChanged.cache.liveKVCodec = .turboQuant
        turboQuantChanged.cache.turboQuantKeyBits = 4
        turboQuantChanged.cache.turboQuantValueBits = 4
        #expect(
            ServerController.loadedModelRuntimeInputsRequireRefresh(
                previous: base,
                next: turboQuantChanged
            )
        )

        var memorySafetyChanged = base
        memorySafetyChanged.memorySafety.mode = .strict
        memorySafetyChanged.memorySafety.slider = 1
        #expect(
            ServerController.loadedModelRuntimeInputsRequireRefresh(
                previous: base,
                next: memorySafetyChanged
            )
        )

        var multimodalChanged = base
        multimodalChanged.multimodal.requireMediaSaltForCache = false
        #expect(
            ServerController.loadedModelRuntimeInputsRequireRefresh(
                previous: base,
                next: multimodalChanged
            )
        )

        var mtpChanged = base
        mtpChanged.mtp.mode = .off
        #expect(
            ServerController.loadedModelRuntimeInputsRequireRefresh(
                previous: base,
                next: mtpChanged
            )
        )
    }

    @Test func loadedModelRefreshInputs_ignoreNetworkAndSamplingOnlyChanges() {
        let base = VMLXServerRuntimeSettings()

        var networkChanged = base
        networkChanged.network.port = 9999
        networkChanged.network.host = "0.0.0.0"
        #expect(
            !ServerController.loadedModelRuntimeInputsRequireRefresh(
                previous: base,
                next: networkChanged
            )
        )

        var generationChanged = base
        generationChanged.generation.topP = 0.42
        generationChanged.generation.temperature = 0.1
        #expect(
            !ServerController.loadedModelRuntimeInputsRequireRefresh(
                previous: base,
                next: generationChanged
            )
        )

        var concurrencyChanged = base
        concurrencyChanged.concurrency.maxConcurrentSequences = 4
        #expect(
            !ServerController.loadedModelRuntimeInputsRequireRefresh(
                previous: base,
                next: concurrencyChanged
            )
        )
    }

    @Test func runtimeConfigInputsInvalidateForGenerationAndConcurrencyChanges() {
        let base = VMLXServerRuntimeSettings()

        var generationChanged = base
        generationChanged.generation.temperature = 0.1
        #expect(
            ServerController.runtimeConfigInputsRequireInvalidate(
                previous: base,
                next: generationChanged
            )
        )

        var maxTokensChanged = base
        maxTokensChanged.generation.maxTokens = 2048
        #expect(
            ServerController.runtimeConfigInputsRequireInvalidate(
                previous: base,
                next: maxTokensChanged
            )
        )

        var concurrencyChanged = base
        concurrencyChanged.concurrency.prefillStepSize = 256
        #expect(
            ServerController.runtimeConfigInputsRequireInvalidate(
                previous: base,
                next: concurrencyChanged
            )
        )

        var cacheChanged = base
        cacheChanged.cache.blockDisk.enabled = false
        #expect(
            !ServerController.runtimeConfigInputsRequireInvalidate(
                previous: base,
                next: cacheChanged
            )
        )
    }

    @Test func openSettingsDraftAdoptsExternalClearAndPreservesUnrelatedEdit() {
        var baseline = VMLXServerRuntimeSettings()
        baseline.concurrency.maxConcurrentSequences = 8
        baseline.generation.temperature = 0.2

        var draft = baseline
        draft.generation.temperature = 0.7

        var external = baseline
        external.concurrency.maxConcurrentSequences = nil

        let reconciled = ServerRuntimeSettingsDraftReconciler.reconcile(
            draft: draft,
            baseline: baseline,
            external: external
        )

        #expect(reconciled.settings.concurrency.maxConcurrentSequences == nil)
        #expect(reconciled.settings.generation.temperature == 0.7)
        #expect(reconciled.conflictingSections.isEmpty)
    }

    @Test func openSettingsDraftBlocksSameSectionExternalOverwrite() {
        var baseline = VMLXServerRuntimeSettings()
        baseline.concurrency.maxConcurrentSequences = 8

        var draft = baseline
        draft.concurrency.maxConcurrentSequences = 4

        var external = baseline
        external.concurrency.maxConcurrentSequences = nil

        let reconciled = ServerRuntimeSettingsDraftReconciler.reconcile(
            draft: draft,
            baseline: baseline,
            external: external
        )

        #expect(reconciled.settings.concurrency.maxConcurrentSequences == 4)
        #expect(reconciled.conflictingSections == ["concurrency"])
    }
}
