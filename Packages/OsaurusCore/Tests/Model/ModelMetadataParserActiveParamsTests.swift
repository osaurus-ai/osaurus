//
//  ModelMetadataParserActiveParamsTests.swift
//  osaurusTests
//
//  Covers the MoE active-parameter token parsing (`A<k>B`, e.g. "35B-A3B")
//  that feeds the display-only decode-speed estimates: the active count must
//  be extracted alongside the existing total, and dense ids must never match.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelMetadataParserActiveParamsTests {

    @Test func parsesActiveParamsFromMoENames() {
        #expect(
            ModelMetadataParser.activeParameterCountBillions(
                from: "OsaurusAI/Qwen3.6-35B-A3B-MXFP4-MTP") == 3.0)
        // The server lists lowercased ids; parsing is case-insensitive.
        #expect(
            ModelMetadataParser.activeParameterCountBillions(
                from: "qwen3.6-35b-a3b-mxfp4-mtp") == 3.0)
        // Decimal active counts (A2.5B) and trailing-token position.
        #expect(
            ModelMetadataParser.activeParameterCountBillions(
                from: "OsaurusAI/Gemma-4-26B-A4B-it-qat") == 4.0)
        #expect(
            ModelMetadataParser.activeParameterCountBillions(from: "org/model-30b-a2.5b") == 2.5)
        // M-suffix scales to billions like `parameterCountBillions`.
        #expect(
            ModelMetadataParser.activeParameterCountBillions(from: "org/tiny-moe-3b-a500m") == 0.5)
    }

    @Test func denseNamesHaveNoActiveParams() {
        // "gemma"/"llama" contain letter-adjacent "a…b" sequences that must
        // not be misread as an active-parameter token.
        #expect(ModelMetadataParser.activeParameterCountBillions(from: "OsaurusAI/gemma-4-12B-it-qat-MXFP4") == nil)
        #expect(ModelMetadataParser.activeParameterCountBillions(from: "mlx-community/Llama-3.2-3B-Instruct-4bit") == nil)
        #expect(ModelMetadataParser.activeParameterCountBillions(from: "OsaurusAI/gemma-4-E4B-it-8bit") == nil)
        #expect(ModelMetadataParser.activeParameterCountBillions(from: "") == nil)
    }

    /// The MoE id must still yield its TOTAL via the existing parser — the
    /// estimate needs both counts from the same name.
    @Test func totalAndActiveCoexistOnMoEIds() {
        let id = "OsaurusAI/Qwen3.6-35B-A3B-MXFP4-MTP"
        #expect(ModelMetadataParser.parameterCountBillions(from: id) == 35.0)
        #expect(ModelMetadataParser.activeParameterCountBillions(from: id) == 3.0)
    }
}
