// Copyright 2026 Osaurus AI. All rights reserved.

import Foundation
import Testing

@Suite("Metal tail drain source coverage")
struct MetalTailDrainSourceTests {
    private static var coreRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: coreRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("image generation termination soft-cancels and unload is gated")
    func imageGenerationTerminationSoftCancelsAndUnloadIsGated() throws {
        let service = try Self.source("Services/ModelRuntime/ImageGenerationService.swift")
        #expect(!service.contains("continuation.onTermination = { _ in task.cancel() }"))
        #expect(service.contains("Task { await self.cancel(jobID: jobID) }"))

        let unloadStart = try #require(service.range(of: "public func unload() async"))
        let unloadEnd = try #require(service.range(of: "// MARK: - Model store root"))
        let unload = String(service[unloadStart.lowerBound..<unloadEnd.lowerBound])
        let enter = try #require(unload.range(of: "await MetalGate.shared.enterImageGeneration()"))
        let engineUnload = try #require(unload.range(of: "await engine.unload()"))
        let clear = try #require(unload.range(of: "MLXCacheIOLock.withSerializedMLXCacheIO"))
        let exit = try #require(unload.range(of: "await MetalGate.shared.exitImageGeneration()"))

        #expect(enter.lowerBound < engineUnload.lowerBound)
        #expect(engineUnload.lowerBound < clear.lowerBound)
        #expect(clear.lowerBound < exit.lowerBound)
    }

    @Test("model unload and prepare-input producers drain before releasing MetalGate")
    func modelUnloadAndPrepareInputDrainBeforeGateRelease() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")
        let gate = try Self.source("Services/ModelRuntime/MetalGate.swift")

        #expect(gate.contains("public func enterModelUnload(model: String) async"))
        #expect(gate.contains("public func exitModelUnload(model: String)"))

        let unloadStart = try #require(runtime.range(of: "func unload(name: String) async"))
        let strictStart = try #require(runtime.range(of: "private func strictEvict"))
        let unload = String(runtime[unloadStart.lowerBound..<strictStart.lowerBound])
        let enter = try #require(unload.range(of: "await MetalGate.shared.enterModelUnload(model: name)"))
        let shutdown = try #require(unload.range(of: "await MLXBatchAdapter.Registry.shared.shutdownEngine(for: name)"))
        let wait = try #require(unload.range(of: "await ModelLease.shared.waitForZero(name)"))
        let firstSync = try #require(unload.range(of: "Stream.gpu.synchronize()"))
        let clear = try #require(unload.range(of: "Memory.clearCache()"))
        let lastSync = try #require(unload.range(of: "Stream.gpu.synchronize()", range: clear.upperBound..<unload.endIndex))
        let exit = try #require(unload.range(of: "await MetalGate.shared.exitModelUnload(model: name)"))

        #expect(enter.lowerBound < shutdown.lowerBound)
        #expect(shutdown.lowerBound < wait.lowerBound)
        #expect(wait.lowerBound < firstSync.lowerBound)
        #expect(firstSync.lowerBound < clear.lowerBound)
        #expect(clear.lowerBound < lastSync.lowerBound)
        #expect(lastSync.lowerBound < exit.lowerBound)

        let prepareStart = try #require(adapter.range(of: "await MetalGate.shared.enterGeneration(model: modelName)"))
        let prepared = try #require(adapter.range(of: "prepared = try await prepareInput", range: prepareStart.upperBound..<adapter.endIndex))
        let successSync = try #require(adapter.range(of: "Stream.gpu.synchronize()", range: prepared.upperBound..<adapter.endIndex))
        let successExit = try #require(adapter.range(of: "await MetalGate.shared.exitGeneration(model: modelName)", range: successSync.upperBound..<adapter.endIndex))
        #expect(prepared.lowerBound < successSync.lowerBound)
        #expect(successSync.lowerBound < successExit.lowerBound)

        let catchStart = try #require(adapter.range(of: "} catch {", range: successExit.upperBound..<adapter.endIndex))
        let catchSync = try #require(adapter.range(of: "Stream.gpu.synchronize()", range: catchStart.upperBound..<adapter.endIndex))
        let catchExit = try #require(adapter.range(of: "await MetalGate.shared.exitGeneration(model: modelName)", range: catchSync.upperBound..<adapter.endIndex))
        #expect(catchSync.lowerBound < catchExit.lowerBound)
    }

    @Test("embedder and live audio preencode drain before releasing generation lanes")
    func embedderAndLiveAudioPreencodeDrainBeforeGateRelease() throws {
        let embedder = try Self.source("Services/Memory/MetalSafeEmbedder.swift")
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(embedder.contains("import MLX"))
        let embedTexts = try #require(embedder.range(of: "public func embed(texts: [String]) async throws -> [[Float]]"))
        let embedText = try #require(embedder.range(of: "public func embed(text: String) async throws -> [Float]"))
        let textsBody = String(embedder[embedTexts.lowerBound..<embedText.lowerBound])
        let textBody = String(embedder[embedText.lowerBound..<embedder.endIndex])
        for body in [textsBody, textBody] {
            let result = try #require(body.range(of: "let result = try await inner.embed"))
            let sync = try #require(body.range(of: "Stream.gpu.synchronize()", range: result.upperBound..<body.endIndex))
            let exit = try #require(body.range(of: "await MetalGate.shared.exitEmbedding()", range: sync.upperBound..<body.endIndex))
            #expect(result.lowerBound < sync.lowerBound)
            #expect(sync.lowerBound < exit.lowerBound)
        }

        let liveStart = try #require(runtime.range(of: "func preencodeLiveVoiceAudio"))
        let lifecycleStart = try #require(runtime.range(of: "// MARK: - Model lifecycle"))
        let live = String(runtime[liveStart.lowerBound..<lifecycleStart.lowerBound])
        let eval = try #require(live.range(of: "MLXBatchAdapter.preencodedAudio("))
        let successSync = try #require(live.range(of: "Stream.gpu.synchronize()", range: eval.upperBound..<live.endIndex))
        let successExit = try #require(live.range(of: "await MetalGate.shared.exitGeneration(model: holder.name)", range: successSync.upperBound..<live.endIndex))
        #expect(eval.lowerBound < successSync.lowerBound)
        #expect(successSync.lowerBound < successExit.lowerBound)
    }
}
