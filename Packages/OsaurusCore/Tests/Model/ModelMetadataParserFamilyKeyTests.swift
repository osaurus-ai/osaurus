//
//  ModelMetadataParserFamilyKeyTests.swift
//  osaurusTests
//
//  Covers the family-key derivation that collapses precision/quant variants
//  of the same model (MXFP4/MXFP8/QAT/JANGTQ/…) into one catalog card while
//  keeping genuinely different sizes (9B vs 35B, E2B vs E4B) separate.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelMetadataParserFamilyKeyTests {

    @Test func precisionVariantsShareOneFamily() {
        let gemma12B = [
            "OsaurusAI/gemma-4-12B-it-MXFP8",
            "OsaurusAI/gemma-4-12B-it-qat-MXFP4",
        ]
        let keys = Set(gemma12B.map(ModelMetadataParser.familyKey(from:)))
        #expect(keys.count == 1)
        #expect(keys.first == "osaurusai/gemma-4-12b-it")
    }

    @Test func mtpAndCaseVariantsShareOneFamily() {
        #expect(
            ModelMetadataParser.familyKey(from: "OsaurusAI/Qwen3.6-35B-A3B-MXFP8-MTP")
                == ModelMetadataParser.familyKey(from: "OsaurusAI/Qwen3.6-35B-A3B-mxfp4")
        )
    }

    @Test func turboQuantVariantsShareOneFamily() {
        #expect(
            ModelMetadataParser.familyKey(from: "OsaurusAI/MiniMax-M2.7-JANGTQ4")
                == ModelMetadataParser.familyKey(from: "OsaurusAI/MiniMax-M2.7-JANGTQ")
        )
        // Lettered TurboQuant flavors (JANGTQ_K, live on the org) collapse too.
        #expect(
            ModelMetadataParser.familyKey(from: "OsaurusAI/MiniMax-M2.7-JANGTQ_K")
                == ModelMetadataParser.familyKey(from: "OsaurusAI/MiniMax-M2.7-JANGTQ")
        )
    }

    @Test func differentSizesStaySeparate() {
        // 27B vs 35B MoE are different models, not precision variants.
        #expect(
            ModelMetadataParser.familyKey(from: "OsaurusAI/Qwen3.6-27B-MXFP4")
                != ModelMetadataParser.familyKey(from: "OsaurusAI/Qwen3.6-35B-A3B-mxfp4")
        )
        // E2B vs E4B edge sizes stay separate.
        #expect(
            ModelMetadataParser.familyKey(from: "OsaurusAI/gemma-4-E2B-it-qat-MXFP4")
                != ModelMetadataParser.familyKey(from: "OsaurusAI/gemma-4-E4B-it-qat-MXFP4")
        )
        // "Small" is a size tier, not a quant token.
        #expect(
            ModelMetadataParser.familyKey(from: "OsaurusAI/MiniMax-M2.7-Small-JANGTQ")
                != ModelMetadataParser.familyKey(from: "OsaurusAI/MiniMax-M2.7-JANGTQ")
        )
    }

    @Test func familiesNeverMergeAcrossOrgs() {
        #expect(
            ModelMetadataParser.familyKey(from: "OsaurusAI/gpt-oss-20b-MXFP4")
                != ModelMetadataParser.familyKey(from: "lmstudio-community/gpt-oss-20b-MXFP4")
        )
    }

    @Test func jangMixedPrecisionCollapses() {
        #expect(
            ModelMetadataParser.familyKey(from: "OsaurusAI/Ornith-1.0-35B-JANG_4M")
                == ModelMetadataParser.familyKey(from: "OsaurusAI/Ornith-1.0-35B-MXFP4")
        )
    }

    @Test func idWithoutVariantTokensIsItsOwnFamily() {
        #expect(
            ModelMetadataParser.familyKey(from: "OsaurusAI/rampart-mlx")
                == "osaurusai/rampart"
        )
        #expect(
            ModelMetadataParser.familyKey(from: "some-org/plain-model")
                == "some-org/plain-model"
        )
    }

    @Test func familyDisplayNameDropsQuantAndTuningTokens() {
        #expect(
            ModelMetadataParser.familyDisplayName(from: "OsaurusAI/gemma-4-12B-it-qat-MXFP4")
                == "Gemma 4 12B"
        )
        #expect(
            ModelMetadataParser.familyDisplayName(from: "OsaurusAI/MiniMax-M2.7-JANGTQ4")
                == "MiniMax M2.7"
        )
    }
}
