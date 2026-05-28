// Copyright © 2026 osaurus.

import Testing

@testable import OsaurusCore

@Suite("Local model tags metadata")
struct LocalModelTagsMetadataTests {
    @Test("known local model aliases do not report unknown family in /api/tags details")
    func knownLocalAliasesInferOllamaTagFamilies() {
        let rows: [(String, String)] = [
            ("_dsv4_band_pe2", "deepseek_v4"),
            ("deepseek-v4-flash-jangtq2", "deepseek_v4"),
            ("gemma-4-26b-a4b-it-jang_4m-crack", "gemma"),
            ("gemma-4-e2b-it-4bit", "gemma"),
            ("qwen3.6-35b-a3b-mxfp4", "qwen"),
            ("qwen3.6-27b-jang_4m-crack", "qwen"),
        ]

        for (modelId, expectedFamily) in rows {
            let details = ModelDetails.localMLXModelDetails(for: modelId)

            #expect(details.format == "safetensors")
            #expect(details.family == expectedFamily, "\(modelId) should infer \(expectedFamily)")
            #expect(details.families == [expectedFamily], "\(modelId) should expose a concrete family list")
        }
    }

    @Test("local tags metadata keeps parameter and quantization heuristics for clients")
    func localTagDetailsPreserveParameterAndQuantizationHints() {
        let qwen = ModelDetails.localMLXModelDetails(for: "qwen3.6-35b-a3b-mxfp4")
        #expect(qwen.parameter_size == "35B")
        #expect(qwen.quantization_level?.lowercased().contains("fp4") == true)

        let gemma = ModelDetails.localMLXModelDetails(for: "gemma-4-26b-a4b-it-jang_4m-crack")
        #expect(gemma.parameter_size == "26B")

        let dsv4 = ModelDetails.localMLXModelDetails(for: "_dsv4_band_pe2")
        #expect(dsv4.family == "deepseek_v4")

        let jangtq = ModelDetails.localMLXModelDetails(for: "deepseek-v4-flash-jangtq2")
        #expect(jangtq.quantization_level == "JANGTQ2")
    }

    @Test("unknown local aliases remain explicitly unknown")
    func unrelatedAliasRemainsUnknown() {
        let details = ModelDetails.localMLXModelDetails(for: "custom-research-model")
        #expect(details.family == "unknown")
        #expect(details.families == ["unknown"])
    }
}
