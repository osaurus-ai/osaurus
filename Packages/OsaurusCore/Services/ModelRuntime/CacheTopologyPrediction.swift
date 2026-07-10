//
//  CacheTopologyPrediction.swift
//  osaurus
//
//  Predicted per-layer cache topology for `/admin/cache-stats`, derived
//  from `LanguageModel.newCache(parameters:)`.
//

import Foundation
import MLXLMCommon

/// Predicted cache topology for one resident model, for one construction
/// input (`parametersLabel`).
///
/// PREDICTED, not observed: vmlx keeps each in-flight request's live
/// `[KVCache]` array inside the engine's decode loop where the host cannot
/// reach it, so the only host-visible source of per-layer topology is
/// constructing a fresh cache the same way the engine does and inspecting
/// its dynamic classes. `newCache` allocates empty cache shells only — no
/// tensor evals — which is why the admin endpoint can afford to call it
/// lazily on each hit. It must never be called on the generation path.
///
/// Parameters fidelity: the engine constructs each request's cache with
/// that request's `GenerateParameters`, and the only parameters field any
/// vmlx `newCache` implementation consults is `maxKVSize` — non-nil turns
/// full-attention layers from `KVCacheSimple` into
/// `RotatingKVCache(maxSize:, keep: 4)` (LanguageModel.swift:399-413).
/// Osaurus never sets `maxKVSize` on a request, but the ENGINE does: every
/// request path runs `coordinator.config.resolveKVPolicy`, which fills
/// `maxKVSize = defaultMaxKVSize` whenever the prompt token count exceeds
/// `defaultMaxKVSize × longPromptMultiplier`
/// (CacheCoordinatorConfig.swift:147-169) — and osaurus configures both
/// knobs (`ModelRuntime.buildCacheCoordinatorConfig`; slider-resolved cap
/// 65536 safe_auto / 16384 strict / 131072 performance, multiplier 2.0).
/// So the `parameters: nil` prediction covers prompts up to
/// `defaultMaxKVSize × longPromptMultiplier` tokens; past that threshold
/// the engine's resolved `maxKVSize` applies and the
/// "long_prompt(maxKVSize=N)" row is the faithful prediction. Each row's
/// `appliesWhen` states its prompt-token range; when no cap is configured
/// the nil row covers every prompt and `appliesWhen` is nil.
struct PredictedCacheTopology: Equatable, Sendable {
    /// Resident model name (the osaurus model id used in `/admin` rows).
    let model: String
    /// Number of cache entries returned by `newCache`. One per layer for
    /// most families, but NOT all: KV-sharing families (Gemma-3n,
    /// Gemma-4) return entries only for their non-KV-shared layers, so
    /// this can be smaller than the model's layer count.
    let cacheEntries: Int
    /// Dynamic class name → count, e.g. `["KVCacheSimple": 16,
    /// "MambaCache": 48]` for a Qwen3.5-style hybrid.
    let classes: [String: Int]
    /// Ordered run-length rendering of the per-layer classes, e.g.
    /// `"3xMambaCache,1xKVCacheSimple,3xMambaCache,..."`. Preserves layer
    /// order because interleaving (not just counts) is what determines
    /// which engine cache strategies are compatible.
    let layout: String
    /// Construction input for this row: "default_nil"
    /// (`newCache(parameters: nil)`) or "long_prompt(maxKVSize=N)"
    /// (`newCache` with the coordinator's configured `defaultMaxKVSize`,
    /// mirroring what `resolveKVPolicy` injects past the long-prompt
    /// threshold).
    let parametersLabel: String
    /// Prompt-token range this row's prediction applies to, e.g.
    /// "prompt_tokens<=131072" / "prompt_tokens>131072". Nil when no
    /// `defaultMaxKVSize` cap is configured (the nil-parameters row then
    /// covers every prompt).
    let appliesWhen: String?
}

extension PredictedCacheTopology {
    /// The engine adopts `defaultMaxKVSize` when
    /// `Double(promptTokenCount) > Double(cap) × multiplier`
    /// (CacheCoordinatorConfig.resolveKVPolicy). Prompt counts are
    /// integers, so the nil-parameters prediction applies exactly to
    /// `promptTokens <= floor(cap × multiplier)`.
    static func longPromptThresholdTokens(cap: Int, multiplier: Double) -> Int {
        Int((Double(cap) * multiplier).rounded(.down))
    }

    /// Row labels for the `newCache(parameters: nil)` prediction.
    static func defaultRowLabels(
        cap: Int?,
        multiplier: Double
    ) -> (parameters: String, appliesWhen: String?) {
        guard let cap else { return ("default_nil", nil) }
        let threshold = longPromptThresholdTokens(cap: cap, multiplier: multiplier)
        return ("default_nil", "prompt_tokens<=\(threshold)")
    }

    /// Row labels for the long-prompt prediction built with
    /// `parameters.maxKVSize = cap`.
    static func longPromptRowLabels(
        cap: Int,
        multiplier: Double
    ) -> (parameters: String, appliesWhen: String) {
        let threshold = longPromptThresholdTokens(cap: cap, multiplier: multiplier)
        return ("long_prompt(maxKVSize=\(cap))", "prompt_tokens>\(threshold)")
    }
}

/// Pure summarization over dynamic class-name strings so the run-length
/// and counting logic is unit-testable without loading an MLX model.
enum CacheTopologySummarizer {
    /// Render one cache entry's class name for the topology row.
    ///
    /// Composite entries are expanded ONE level deep: families like
    /// FalconH1/BaichuanM1 return a per-layer `CacheList(...)` wrapping
    /// e.g. a MambaCache and a KVCacheSimple; reporting the bare
    /// "CacheList" would hide that inner mix, so such an entry renders as
    /// `"CacheList(MambaCache+KVCacheSimple)"`. Children are enumerated
    /// via `CacheList`'s public `count`/`subscript` (the backing `caches`
    /// array itself is module-internal in vmlx); a nested `CacheList`
    /// child (none exist today) renders as its bare class name.
    static func cacheClassName(_ cache: KVCache) -> String {
        guard let list = cache as? CacheList else {
            return String(describing: type(of: cache))
        }
        let inner = (0..<list.count)
            .map { String(describing: type(of: list[$0])) }
            .joined(separator: "+")
        return "CacheList(\(inner))"
    }

    static func summarize(classNames: [String]) -> (classes: [String: Int], layout: String) {
        var classes: [String: Int] = [:]
        var runs: [(name: String, count: Int)] = []
        for name in classNames {
            classes[name, default: 0] += 1
            if let last = runs.indices.last, runs[last].name == name {
                runs[last].count += 1
            } else {
                runs.append((name: name, count: 1))
            }
        }
        let layout = runs.map { "\($0.count)x\($0.name)" }.joined(separator: ",")
        return (classes: classes, layout: layout)
    }
}
