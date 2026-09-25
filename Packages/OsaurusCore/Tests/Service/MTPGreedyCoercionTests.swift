import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// Regression for the former blanket greedy override. MTP must consume the
/// same resolved sampler as AR: request > explicit runtime setting > bundle.
/// These resolver checks are not real-model sampling/cache qualification.
@Suite struct MTPSamplingPreservationTests {

    private func resolve(
        draftStrategy: MLXLMCommon.DraftStrategy?,
        bundleTemperature: Float = 1.0,
        bundleTopP: Float = 0.95,
        bundleTopK: Int = 20,
        modelName: String = "JANGQ-AI/Qwen3.8-Flash-Next-JANG_4M",
        requestTemperature: Float? = nil,
        requestTopP: Float? = nil,
        requestTopK: Int? = nil,
        runtime: VMLXServerGenerationDefaults = .init()
    ) -> MLXBatchAdapter.EffectiveGenerationSettings {
        let generation = GenerationParameters(
            temperature: requestTemperature,
            maxTokens: 16_384,
            maxTokensExplicit: false,
            topPOverride: requestTopP,
            topKOverride: requestTopK,
            minPOverride: nil,
            repetitionPenalty: nil
        )
        let bundleDefaults = LocalGenerationDefaults.Defaults(
            maxTokens: nil,
            temperature: bundleTemperature,
            topP: bundleTopP,
            topK: bundleTopK,
            minP: nil,
            repetitionPenalty: nil,
            doSample: true
        )
        // Same resolution entry point and inputs as the production adapter.
        return MLXBatchAdapter.effectiveGenerationSettings(
            modelName: modelName,
            generation: generation,
            runtimeDefaults: runtime,
            maxBatchSize: 1,
            modelDefaults: bundleDefaults,
            draftStrategy: draftStrategy
        )
    }

    @Test("both Qwen families preserve their bundle sampler when MTP is active")
    func mtpActivePreservesBundleSampler() {
        for modelName in ["JANGQ-AI/Qwen3.8-27B-JANG_4D", "JANGQ-AI/Qwen3.8-Flash-Next-JANG_4M"] {
            let effective = resolve(
                draftStrategy: .nativeMTP(depth: 2), modelName: modelName)
            #expect(effective.temperature == 1)
            #expect(effective.topP == 0.95)
            #expect(effective.topK == 20)
            #expect(effective.minP == 0)
            #expect(!effective.mtpGreedyEnforced)
            #expect(!effective.samplerWasChanged)
            #expect(effective.draftStrategy == DraftStrategy.nativeMTP(depth: 2).kindName)
        }
    }

    @Test("AR (no drafter) preserves the bundle generation_config sampler")
    func noDrafterPreservesSampling() {
        let effective = resolve(draftStrategy: nil)
        #expect(effective.temperature == 1.0)
        #expect(effective.topP == 0.95)
        #expect(effective.topK == 20)
        #expect(!effective.mtpGreedyEnforced)
        #expect(!effective.samplerWasChanged)
    }

    @Test("DFlash 2 is speculative but NOT native MTP: sampler preserved")
    func dflash2PreservesSampling() {
        let effective = resolve(
            draftStrategy: .dflash2(
                drafterPath: URL(fileURLWithPath: "/dev/null"), blockSize: nil))
        #expect(effective.temperature == 1.0)
        #expect(effective.topP == 0.95)
        #expect(effective.topK == 20)
        #expect(!effective.mtpGreedyEnforced)
        #expect(!effective.samplerWasChanged)
    }

    @Test("a declared greedy sampler remains greedy without MTP coercion")
    func alreadyGreedyIsNotACoercion() {
        let effective = resolve(
            draftStrategy: .nativeMTP(depth: 1, verifierMode: nil),
            bundleTemperature: 0,
            bundleTopP: 1,
            bundleTopK: 0
        )
        #expect(effective.temperature == 0)
        #expect(!effective.mtpGreedyEnforced)
        #expect(!effective.samplerWasChanged)
    }

    @Test func explicitRequestStillOutranksRuntimeAndBundle() {
        var runtime = VMLXServerGenerationDefaults()
        runtime.temperature = 0.4
        runtime.topP = 0.8
        runtime.topK = 15
        let effective = resolve(
            draftStrategy: .nativeMTP(depth: 3),
            requestTemperature: 0.7, requestTopP: 0.9, requestTopK: 32, runtime: runtime)
        #expect(effective.temperature == 0.7)
        #expect(effective.topP == 0.9)
        #expect(effective.topK == 32)
        #expect(!effective.samplerWasChanged)
    }

    @Test func explicitRuntimeSamplerStillOutranksBundle() {
        var runtime = VMLXServerGenerationDefaults()
        runtime.temperature = 0.4
        runtime.topP = 0.8
        runtime.topK = 15
        let effective = resolve(draftStrategy: .nativeMTP(depth: 1), runtime: runtime)
        #expect(effective.temperature == 0.4)
        #expect(effective.topP == 0.8)
        #expect(effective.topK == 15)
        #expect(!effective.samplerWasChanged)
    }
}
