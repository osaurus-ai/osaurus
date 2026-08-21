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

    /// 🚨 A cold memo must not change PROMPT SHAPE.
    ///
    /// `resolveUnadjusted` used to return `.unknown` when `loadCachedOrWarm`
    /// missed, defaulting `prefersCompactPrompt` to false, while the warm
    /// branch of the SAME function said the opposite for the same situation —
    /// "Unknown size on a local model also compacts" — returning true when the
    /// parameter count is unparseable. Both paths now share one resolver.
    ///
    /// So an Ornith 9B conversation composed a VERBOSE system prompt on the
    /// first render and a COMPACT one once the memo warmed. Different prompt =
    /// different prefix = missed KV cache, on the read sites whose own comment
    /// calls mutual consistency "a KV-cache requirement". A 35B model is
    /// non-compact in both states, which is why this hid on the big models.
    ///
    /// The parameter count is parsed from the model ID, which is available with
    /// or without the memo, so both paths can and must agree.
    @Test func coldMemoDoesNotFlipCompactPreference() {
        // Sub-ceiling local models compact. Neither of these has an on-disk
        // bundle here, so this exercises the cold path specifically.
        #expect(ContextSizeResolver.resolve(modelId: "OsaurusAI/Ornith-1.0-9B-JANG_4").prefersCompactPrompt == true)
        #expect(ContextSizeResolver.resolve(modelId: "Qwen3.5-9B-MXFP8").prefersCompactPrompt == true)
        // Above the ceiling stays verbose cold, matching the warm answer.
        #expect(ContextSizeResolver.resolve(modelId: "OsaurusAI/Ornith-1.0-35B-A3B-JANG_4").prefersCompactPrompt == false)
        // An UNPARSEABLE size stays verbose in BOTH paths.
        //
        // This assertion originally expected `true`, copying the warm branch's
        // `?? true`. That was wrong, and CI caught it: compaction is not merely
        // cosmetic — the compact prompt swaps the expanded management tools for
        // an ids-only `capabilities_load` manifest, so defaulting an unsizeable
        // model to compact silently narrowed the tool schema the API
        // advertises and broke HTTPHandlerChatStreamingTests' default-agent
        // tool set. Consistency between the cold and warm paths is the goal;
        // resolving the disagreement toward VERBOSE is the safe direction,
        // because it never removes a capability on a guess.
        #expect(ContextSizeResolver.resolve(modelId: "SomeVendor/mystery-bundle").prefersCompactPrompt == false)
    }

    /// The compact param ceiling is the documented 20B (guards against an
    /// accidental edit that would silently re-scope which local models compact).
    @Test func compactParamCeilingIsTwentyBillion() {
        #expect(ContextSizeResolver.compactParamCeilingBillions == 20)
    }
}
