//
//  ModelParameterBillionsTests.swift
//  osaurusTests
//
//  Covers `ModelMetadataParser.parameterCountBillions` (the numeric size
//  `ContextSizeResolver` uses to set `prefersCompactPrompt` for large-window
//  local models) and the model-id-independent branches of the resolver.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelParameterBillionsTests {

    @Test func parsesBillionsFromCommonIds() {
        #expect(ModelMetadataParser.parameterCountBillions(from: "qwen2.5-7B") == 7.0)
        #expect(ModelMetadataParser.parameterCountBillions(from: "phi-3-mini-1.7B") == 1.7)
        // The user's local model — must read 12B (the leading size token), not
        // the trailing JANG_4M precision label.
        #expect(
            ModelMetadataParser.parameterCountBillions(
                from: "OsaurusAI/gemma-4-12B-it-qat-JANG_4M"
            ) == 12.0
        )
    }

    @Test func parsesMillionsAsFractionalBillions() {
        let b = ModelMetadataParser.parameterCountBillions(from: "embeddinggemma-270M")
        #expect(b != nil)
        // 270M -> 0.27B
        #expect(abs((b ?? 0) - 0.27) < 0.0001)
    }

    @Test func returnsNilWhenNoSizeToken() {
        #expect(ModelMetadataParser.parameterCountBillions(from: "some-model-no-size") == nil)
    }

    /// Model-id-independent resolver branches: a missing/blank id never prefers
    /// the compact prompt (we don't hide prose before a model is resolved). The
    /// local + param-ceiling branch depends on an on-disk MLX config and is
    /// validated end-to-end via the live compose path.
    @Test func resolverPrefersVerboseForMissingOrBlankModel() {
        #expect(ContextSizeResolver.resolve(modelId: nil).prefersCompactPrompt == false)
        #expect(ContextSizeResolver.resolve(modelId: "").prefersCompactPrompt == false)
        #expect(ContextSizeResolver.resolve(modelId: "   ").prefersCompactPrompt == false)
    }

    /// Foundation resolves to a tiny window, which already implies compact.
    @Test func foundationPrefersCompact() {
        #expect(ContextSizeResolver.resolve(modelId: "foundation").prefersCompactPrompt == true)
        #expect(ContextSizeResolver.resolve(modelId: "default").prefersCompactPrompt == true)
    }

    /// The compact param ceiling is the documented 20B (guards against an
    /// accidental edit that would silently re-scope which local models compact).
    @Test func compactParamCeilingIsTwentyBillion() {
        #expect(ContextSizeResolver.compactParamCeilingBillions == 20)
    }
}
