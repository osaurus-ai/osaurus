//
//  ModelMetadataParserQuantLabelTests.swift
//  osaurusTests
//
//  Covers the quantization-label parsing for the JANG mixed-precision
//  suffixes (`JANG_4M/4K/2L/2S`). These rows previously rendered "—" in the
//  Quant column; surfacing the bit-class label keeps precision visible.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelMetadataParserQuantLabelTests {

    @Test func parsesJANGMixedPrecisionLabels() {
        #expect(
            ModelMetadataParser.quantization(from: "OsaurusAI/Qwen3.5-122B-A10B-JANG_4K") == "JANG 4K"
        )
        #expect(
            ModelMetadataParser.quantization(from: "OsaurusAI/Gemma-4-26B-A4B-it-JANG_2L") == "JANG 2L"
        )
        #expect(
            ModelMetadataParser.quantization(from: "OsaurusAI/Gemma-4-31B-it-JANG_4M") == "JANG 4M"
        )
    }

    /// TurboQuant (`JANGTQ*`) keeps its own label and must not be swallowed by
    /// the new bare-`JANG_` branch.
    @Test func turboQuantLabelsUnchanged() {
        #expect(ModelMetadataParser.quantization(from: "OsaurusAI/Ling-2.6-flash-JANGTQ") == "JANGTQ")
        #expect(ModelMetadataParser.quantization(from: "OsaurusAI/MiniMax-M2.7-JANGTQ4") == "JANGTQ4")
    }

    /// MXFP / explicit bit-width labels are still parsed as before.
    @Test func precisionFormatsUnchanged() {
        #expect(ModelMetadataParser.quantization(from: "OsaurusAI/gemma-4-12B-it-MXFP8") == "MXFP8")
        #expect(ModelMetadataParser.quantization(from: "OsaurusAI/gemma-4-12B-it-qat-MXFP4") == "MXFP4")
        #expect(ModelMetadataParser.quantization(from: "OsaurusAI/gemma-4-E4B-it-8bit") == "8-bit")
    }
}
