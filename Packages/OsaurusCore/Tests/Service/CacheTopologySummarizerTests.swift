//
//  CacheTopologySummarizerTests.swift
//  osaurusTests
//
//  Coverage for the pure class-name rendering and run-length/counting
//  summarization behind the `predicted_cache_topology` block in
//  `/admin/cache-stats`. The summarizer operates on cache instances /
//  dynamic class-name strings so it is testable without loading an MLX
//  model; `ModelRuntime.adminCacheStatsModelSnapshot` only supplies the
//  entries (via `newCache(parameters: nil)`).
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite
struct CacheTopologySummarizerTests {

    @Test func summarize_emptyInputYieldsEmptySummary() {
        let summary = CacheTopologySummarizer.summarize(classNames: [])
        #expect(summary.classes.isEmpty)
        #expect(summary.layout == "")
    }

    @Test func summarize_singleClassCollapsesToOneRun() {
        let summary = CacheTopologySummarizer.summarize(
            classNames: Array(repeating: "KVCacheSimple", count: 32)
        )
        #expect(summary.classes == ["KVCacheSimple": 32])
        #expect(summary.layout == "32xKVCacheSimple")
    }

    @Test func summarize_hybridInterleavingPreservesRunOrder() {
        // Qwen3.5-style hybrid: runs of Mamba (linear-attention) layers
        // punctuated by full-attention layers. The layout must preserve
        // the interleaving, not just the totals.
        let names =
            Array(repeating: "MambaCache", count: 3)
            + ["KVCacheSimple"]
            + Array(repeating: "MambaCache", count: 3)
            + ["KVCacheSimple"]
        let summary = CacheTopologySummarizer.summarize(classNames: names)
        #expect(summary.classes == ["MambaCache": 6, "KVCacheSimple": 2])
        #expect(
            summary.layout == "3xMambaCache,1xKVCacheSimple,3xMambaCache,1xKVCacheSimple"
        )
    }

    @Test func summarize_alternatingClassesProduceUnitRuns() {
        let summary = CacheTopologySummarizer.summarize(
            classNames: ["A", "B", "A", "B"]
        )
        #expect(summary.classes == ["A": 2, "B": 2])
        #expect(summary.layout == "1xA,1xB,1xA,1xB")
    }

    @Test func summarize_countsAndLayoutAgreeOnTotals() {
        let names = ["A", "A", "B", "C", "C", "C", "A"]
        let summary = CacheTopologySummarizer.summarize(classNames: names)
        #expect(summary.classes.values.reduce(0, +) == names.count)
        #expect(summary.classes == ["A": 3, "B": 1, "C": 3])
        #expect(summary.layout == "2xA,1xB,3xC,1xA")
    }

    @Test func cacheClassName_plainCachesRenderBareDynamicClass() {
        #expect(CacheTopologySummarizer.cacheClassName(KVCacheSimple()) == "KVCacheSimple")
        #expect(
            CacheTopologySummarizer.cacheClassName(RotatingKVCache(maxSize: 1024, keep: 4))
                == "RotatingKVCache"
        )
    }

    @Test func cacheClassName_cacheListExpandsInnerMixOneLevelDeep() {
        // FalconH1/BaichuanM1-style composite: a per-layer CacheList
        // wrapping a Mamba (SSM) cache and a plain KV cache. The bare
        // "CacheList" name would hide the inner mix that determines
        // which engine cache strategies are compatible.
        let composite = CacheList(MambaCache(), KVCacheSimple())
        #expect(
            CacheTopologySummarizer.cacheClassName(composite)
                == "CacheList(MambaCache+KVCacheSimple)"
        )
    }

    @Test func summarize_nestedCacheListNamesRunLengthLikeAnyOtherClass() {
        let names = Array(
            repeating: "CacheList(MambaCache+KVCacheSimple)",
            count: 4
        ) + ["KVCacheSimple"]
        let summary = CacheTopologySummarizer.summarize(classNames: names)
        #expect(
            summary.classes == [
                "CacheList(MambaCache+KVCacheSimple)": 4,
                "KVCacheSimple": 1,
            ]
        )
        #expect(
            summary.layout == "4xCacheList(MambaCache+KVCacheSimple),1xKVCacheSimple"
        )
    }

    // MARK: - Row labels (parameters fidelity)

    @Test func rowLabels_pairCoverTheEngineLongPromptThreshold() {
        // The engine injects `maxKVSize = defaultMaxKVSize` when
        // promptTokenCount > cap × longPromptMultiplier
        // (CacheCoordinatorConfig.resolveKVPolicy), so the two rows must
        // partition the prompt-token axis at exactly that threshold.
        #expect(
            PredictedCacheTopology.longPromptThresholdTokens(cap: 65536, multiplier: 2.0)
                == 131_072
        )

        let defaultRow = PredictedCacheTopology.defaultRowLabels(cap: 65536, multiplier: 2.0)
        #expect(defaultRow.parameters == "default_nil")
        #expect(defaultRow.appliesWhen == "prompt_tokens<=131072")

        let longPromptRow = PredictedCacheTopology.longPromptRowLabels(
            cap: 65536,
            multiplier: 2.0
        )
        #expect(longPromptRow.parameters == "long_prompt(maxKVSize=65536)")
        #expect(longPromptRow.appliesWhen == "prompt_tokens>131072")

        // Strict / performance slider profiles resolve different caps.
        #expect(
            PredictedCacheTopology.longPromptRowLabels(cap: 16384, multiplier: 2.0).parameters
                == "long_prompt(maxKVSize=16384)"
        )
        #expect(
            PredictedCacheTopology.defaultRowLabels(cap: 131_072, multiplier: 2.0).appliesWhen
                == "prompt_tokens<=262144"
        )
    }

    @Test func rowLabels_noConfiguredCapMeansSingleUnboundedNilRow() {
        // Without a `defaultMaxKVSize` the engine never fills `maxKVSize`,
        // so the nil-parameters prediction covers every prompt and there
        // is no second row (and no applies_when hint).
        let labels = PredictedCacheTopology.defaultRowLabels(cap: nil, multiplier: 2.0)
        #expect(labels.parameters == "default_nil")
        #expect(labels.appliesWhen == nil)
    }

    @Test func predictedCacheTopology_cacheEntriesFieldIsConstructionCount() {
        // "cache_entries", not "layers": KV-sharing families (Gemma-3n,
        // Gemma-4) return `newCache` entries only for non-KV-shared
        // layers, so the count can be smaller than the model's layer
        // count. The row must carry the construction count verbatim.
        let classNames = Array(repeating: "KVCacheSimple", count: 30)  // e.g. 48-layer model, 18 KV-shared
        let summary = CacheTopologySummarizer.summarize(classNames: classNames)
        let row = PredictedCacheTopology(
            model: "gemma-4-test",
            cacheEntries: classNames.count,
            classes: summary.classes,
            layout: summary.layout,
            parametersLabel: "default_nil",
            appliesWhen: nil
        )
        #expect(row.cacheEntries == 30)
    }
}
