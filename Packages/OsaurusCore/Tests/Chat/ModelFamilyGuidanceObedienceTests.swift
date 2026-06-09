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

    @Test("Gemini resolves to its own frontier block, not Gemma's brevity clamp")
    func geminiGetsDedicatedBlock() {
        for id in ["gemini-2.5-pro", "google/gemini-flash", "models/gemini-pro"] {
            #expect(ModelFamilyGuidance.family(for: id) == .googleGemini)
            #expect(
                ModelFamilyGuidance.guidance(forModelId: id)
                    == ModelFamilyGuidance.googleGeminiGuidance
            )
        }
        // The frontier block must not carry the local-Gemma brevity clamp.
        #expect(!ModelFamilyGuidance.googleGeminiGuidance.contains("Be concise"))
        // Anti-hallucination guardrail still rides along.
        #expect(
            ModelFamilyGuidance.googleGeminiGuidance.contains(
                "Only call tools that exist in your schema"
            )
        )
    }

    @Test("o-series markers match on token boundaries only")
    func oSeriesTokenBoundaryMatching() {
        // Real o-series ids route to GPT/Codex.
        for id in ["o1", "o1-preview", "openai/o3-mini", "o4-mini", "azure_o3_mini"] {
            #expect(ModelFamilyGuidance.family(for: id) == .gptCodex, "\(id) should be gptCodex")
        }
        // Ids that merely contain "o1"/"o3"/"o4" as substrings must NOT.
        #expect(ModelFamilyGuidance.family(for: "molmo3-7b") != .gptCodex)
        #expect(ModelFamilyGuidance.family(for: "yolo11-detect") != .gptCodex)
        #expect(ModelFamilyGuidance.family(for: "turbo4-chat") != .gptCodex)
    }

    @Test("compact variants exist for the heavy blocks and fall through elsewhere")
    func compactVariants() {
        // GPT/Codex and Gemma get dedicated compact blocks.
        #expect(
            ModelFamilyGuidance.guidance(forModelId: "gpt-5", compact: true)
                == ModelFamilyGuidance.gptCodexGuidanceCompact
        )
        #expect(
            ModelFamilyGuidance.guidance(forModelId: "gemma-3-4b-it", compact: true)
                == ModelFamilyGuidance.googleGemmaGuidanceCompact
        )
        // Compact must be a real token saving over the full block.
        #expect(
            ModelFamilyGuidance.gptCodexGuidanceCompact.count
                < ModelFamilyGuidance.gptCodexGuidance.count
        )
        // Already-short families fall through to their full block.
        #expect(
            ModelFamilyGuidance.guidance(forModelId: "qwen3-8b", compact: true)
                == ModelFamilyGuidance.glmQwenGuidance
        )
        #expect(
            ModelFamilyGuidance.guidance(forModelId: "foundation", compact: true)
                == ModelFamilyGuidance.defaultGuidance
        )
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
