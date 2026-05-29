//
//  ServerControllerConfigLoadingTests.swift
//  osaurusTests
//

import Foundation
@preconcurrency import MLXLMCommon
import Testing

@testable import OsaurusCore

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

    @Test func loadedModelRefreshInputs_coverCacheMultimodalAndMTP() {
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
}
