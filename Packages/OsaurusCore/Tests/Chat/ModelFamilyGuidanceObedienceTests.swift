//
//  ModelFamilyGuidanceObedienceTests.swift
//
//  Pins the obedience-regression fix: LFM2 (the actual model behind the
//  reported "less obedient" payload) and unrecognised families (Apple
//  Foundation et al.) must resolve to a non-nil guidance block. Before
//  the fix both fell into `.other -> nil`, so they received the always-on
//  prohibition sections (codeStyle / riskAware) with no "act when you can"
//  counterweight — reading as refusal-prone.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Model family obedience guidance")
struct ModelFamilyGuidanceObedienceTests {

    @Test("LFM2 resolves to the LFM2 obedience block")
    func lfm2ResolvesToLFM2Block() {
        #expect(ModelFamilyGuidance.family(for: "OsaurusAI/LFM2.5-8B-A1B-MXFP8") == .lfm2)
        let guidance = ModelFamilyGuidance.guidance(forModelId: "OsaurusAI/LFM2.5-8B-A1B-MXFP8")
        #expect(guidance == ModelFamilyGuidance.lfm2Guidance)
        // Anti-hallucination guardrail must ride along with the obedience push.
        #expect(guidance?.contains("Only call tools that exist in your schema") == true)
    }

    @Test("unrecognised families fall back to the default obedience block, not nil")
    func otherResolvesToDefaultBlock() {
        // Apple Foundation and any future/unknown id.
        for id in ["foundation", "some-unheard-of-model-9000", "phi-4-mini"] {
            #expect(ModelFamilyGuidance.family(for: id) == .other)
            let guidance = ModelFamilyGuidance.guidance(forModelId: id)
            #expect(guidance == ModelFamilyGuidance.defaultGuidance)
            #expect(guidance != nil)
        }
    }

    @Test("known families keep their targeted blocks")
    func knownFamiliesUnchanged() {
        #expect(ModelFamilyGuidance.guidance(forModelId: "gpt-5") == ModelFamilyGuidance.gptCodexGuidance)
        #expect(
            ModelFamilyGuidance.guidance(forModelId: "google/gemma-3-12b-it") == ModelFamilyGuidance.googleGemmaGuidance
        )
        #expect(ModelFamilyGuidance.guidance(forModelId: "qwen3-32b") == ModelFamilyGuidance.glmQwenGuidance)
        #expect(ModelFamilyGuidance.guidance(forModelId: "deepseek-v4") == ModelFamilyGuidance.deepSeekGuidance)
    }

    @Test("the default block does not invite tool enumeration")
    func defaultBlockGuardsAgainstEnumeration() {
        // The whole reason `.other` historically returned nil was the fear
        // of a universal addendum encouraging tool listing. The default
        // block must explicitly bound that risk.
        #expect(
            ModelFamilyGuidance.defaultGuidance.contains(
                "Only call tools that exist in your schema"
            )
        )
        #expect(ModelFamilyGuidance.defaultGuidance.contains("never invent a tool name"))
    }
}
