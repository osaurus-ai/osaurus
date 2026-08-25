//
//  EffectiveSamplerReadoutTests.swift
//  OsaurusCoreTests
//
//  The Live Activity card's "Sampler last used" row.
//
//  Until this landed, the sampler a model ACTUALLY ran with was reachable
//  only through the HTTP admin endpoint's `last_effective_generation`. The
//  Settings panel showed what had been *requested* and nothing showed what
//  *ran* — which is precisely how the user's Sampling Defaults sat inert
//  behind bundle defaults without being visible to anyone.
//

import Testing

@testable import OsaurusCore

@Suite("effective sampler readout")
struct EffectiveSamplerReadoutTests {

    private func settings(
        temperature: Float,
        topP: Float = 0.95,
        topK: Int = 20,
        minP: Float = 0.01,
        maxTokens: Int = 4096,
        repetitionPenalty: Float? = 1.05,
        presencePenalty: Float? = nil,
        frequencyPenalty: Float? = nil,
        draftStrategy: String? = nil,
        mtpFallbackReason: String? = nil
    ) -> MLXBatchAdapter.EffectiveGenerationSettings {
        MLXBatchAdapter.EffectiveGenerationSettings(
            stage: "submitted_to_batch_engine",
            temperature: temperature,
            maxTokens: maxTokens,
            topP: topP,
            topK: topK,
            minP: minP,
            repetitionPenalty: repetitionPenalty,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            draftStrategy: draftStrategy,
            mtpFallbackReason: mtpFallbackReason,
            compiledBatchDecode: true
        )
    }

    // MARK: - What actually drafted the tokens

    /// The MTP Mode picker is an INPUT to resolution, never a description of
    /// it. A bundle whose tuning artifact never asserted `output_equivalent`
    /// cannot run speculative decoding even on Force-On — correctly, since that
    /// assertion IS the output-equivalence proof. Before this readout the user
    /// saw a picker set to Force-On, no speedup, and no explanation anywhere in
    /// the UI; the reason string existed but only reached the submit log.
    @Test func readout_namesTheReasonMTPIsNotRunning() {
        let text = LiveActivitySection.describe(
            settings(
                temperature: 0.7,
                mtpFallbackReason: "tuning artifact did not assert output_equivalent"))

        #expect(text.contains("MTP off — tuning artifact did not assert output_equivalent"))
        #expect(!text.contains("draft none"), "a named reason must replace the bare state")
    }

    @Test func readout_namesTheDrafterWhenSpeculativeDecodingIsLive() {
        let text = LiveActivitySection.describe(
            settings(temperature: 0.7, draftStrategy: "nativeMTP"))

        #expect(text.contains("draft nativeMTP"))
    }

    /// A model that never had MTP to begin with produces no fallback reason.
    /// It must still say what ran, or "no line" becomes indistinguishable from
    /// "the readout is broken".
    @Test func readout_saysPlainDecodeWhenThereIsNoDrafterAndNoReason() {
        let text = LiveActivitySection.describe(settings(temperature: 0.7))
        #expect(text.contains("draft none"))
    }

    @Test func readout_showsEveryResolvedSamplerField() {
        let text = LiveActivitySection.describe(settings(temperature: 0.7))

        #expect(text.contains("temp 0.7"))
        #expect(text.contains("top-p 0.95"))
        #expect(text.contains("top-k 20"))
        #expect(text.contains("min-p 0.01"))
        #expect(text.contains("max 4096"))
        #expect(text.contains("rep 1.05"))
    }

    /// `%g`, not `%.1f`. A share field formatted with `%.1f` already rewrote
    /// 0.005 to 0 once this session; a readout that rounds is a readout that
    /// lies about small min-p / top-p values.
    @Test func readout_keepsSmallValuesInsteadOfRoundingThemToZero() {
        let text = LiveActivitySection.describe(
            settings(temperature: 0.7, topP: 0.999, minP: 0.005)
        )

        #expect(text.contains("min-p 0.005"))
        #expect(text.contains("top-p 0.999"))
        #expect(!text.contains("min-p 0 "))
    }

    /// Temperature 0 is argmax, so top-p / top-k / min-p cannot influence the
    /// result. Printing them without saying that is how an agent stored with
    /// `temperature: 0` looked correctly configured while decoding greedily —
    /// the mechanism behind the DSV4 verbatim reasoning loop.
    @Test func readout_saysGreedyWhenTemperatureIsZero() {
        let greedy = LiveActivitySection.describe(settings(temperature: 0))
        #expect(greedy.contains("greedy"))
        #expect(greedy.contains("inert"))

        let sampled = LiveActivitySection.describe(settings(temperature: 0.7))
        #expect(!sampled.contains("greedy"))
    }

    /// A bundle that ships no repetition penalty must not have one invented
    /// for the display either.
    @Test func readout_omitsRepetitionPenaltyWhenUnset() {
        let text = LiveActivitySection.describe(
            settings(temperature: 0.7, repetitionPenalty: nil)
        )
        #expect(!text.contains("rep "))
    }

    /// Warm-up prefills submit `temperature: 0, maxTokens: 1` after a visible
    /// turn. If those were recorded, the readout would describe housekeeping
    /// instead of the generation the user just watched.
    @Test func readout_sourceExcludesWarmupPrefills() {
        let warmup = GenerationParameters(
            temperature: 0,
            maxTokens: 1,
            warmupPrefill: true
        )
        let visible = GenerationParameters(
            temperature: nil,
            maxTokens: 256,
            maxTokensExplicit: false
        )

        #expect(!MLXBatchAdapter.shouldRecordAsLastEffectiveGeneration(warmup))
        #expect(MLXBatchAdapter.shouldRecordAsLastEffectiveGeneration(visible))
    }
}
