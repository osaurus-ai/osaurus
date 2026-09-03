import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// The greedy-while-MTP contract, exercised through the SINGLE resolution
/// site (`MLXBatchAdapter.effectiveGenerationSettings`) that feeds the run
/// parameters, the API's `last_effective_generation`, and the log line —
/// there is no second coercion pass to drift out of sync with it.
///
/// Starting point for every case is Qwen 3.8 Flash Next's shipped
/// generation_config.json sampler (temperature 1.0, top-p 0.95, top-k 20)
/// arriving as BUNDLE defaults with no per-request overrides:
/// - native MTP active → effective greedy 0/1/0/0, `mtpGreedyEnforced` and
///   `samplerWasChanged` both true;
/// - AR (no drafter) and DFlash 2 → bundle sampler preserved, flags false;
/// - an already-greedy resolution under MTP → enforced but NOT changed.
@Suite struct MTPGreedyCoercionTests {

    private func resolve(
        draftStrategy: MLXLMCommon.DraftStrategy?,
        bundleTemperature: Float = 1.0,
        bundleTopP: Float = 0.95,
        bundleTopK: Int = 20
    ) -> MLXBatchAdapter.EffectiveGenerationSettings {
        let generation = GenerationParameters(
            temperature: nil,
            maxTokens: 16_384,
            maxTokensExplicit: false,
            topPOverride: nil,
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
        // Mirrors the production call site: greedy is forced exactly when
        // the effective draft strategy actually runs native MTP.
        return MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "JANGQ-AI/Qwen3.8-Flash-Next-JANG_4M",
            generation: generation,
            runtimeDefaults: VMLXServerGenerationDefaults(),
            maxBatchSize: 1,
            modelDefaults: bundleDefaults,
            draftStrategy: draftStrategy,
            forcesGreedyForNativeMTP: draftStrategy?.usesNativeMTP == true
        )
    }

    @Test("native MTP resolves the bundle sampler to greedy 0/1/0/0 and flags it")
    func mtpActiveCoercesToGreedy() {
        let effective = resolve(
            draftStrategy: .nativeMTP(depth: 2, verifierMode: nil))
        #expect(effective.temperature == 0)
        #expect(effective.topP == 1)
        #expect(effective.topK == 0)
        #expect(effective.minP == 0)
        #expect(effective.mtpGreedyEnforced)
        #expect(effective.samplerWasChanged)
        #expect(effective.draftStrategy == DraftStrategy.nativeMTP(depth: 2).kindName)
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

    @Test("an already-greedy resolution under MTP is enforced but not changed")
    func alreadyGreedyIsNotACoercion() {
        let effective = resolve(
            draftStrategy: .nativeMTP(depth: 1, verifierMode: nil),
            bundleTemperature: 0,
            bundleTopP: 1,
            bundleTopK: 0
        )
        #expect(effective.temperature == 0)
        #expect(effective.mtpGreedyEnforced)
        #expect(!effective.samplerWasChanged)
    }
}
