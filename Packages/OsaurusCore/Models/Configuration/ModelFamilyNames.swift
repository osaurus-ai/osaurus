//
//  ModelFamilyNames.swift
//  osaurus
//
//  Small, exact family-name helpers shared by catalog/profile/runtime code.
//

import Foundation

enum ModelFamilyNames {
    /// Compiled-regex cache. `String.range(of:options:.regularExpression)`
    /// recompiles its pattern on every call, and these helpers run inside
    /// SwiftUI body getters (the model-type badge and capability rows read
    /// `MLXModel.isVLM`, which fans out to several family checks). Repeated
    /// renders turned that per-call compilation into a main-thread hang, so
    /// every pattern is compiled once and reused.
    private static let regexCache = RegexCache()

    private static func matches(_ pattern: String, in string: String) -> Bool {
        let regex = regexCache.regex(for: pattern)
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, range: range) != nil
    }

    /// Thread-safe pattern -> compiled-regex cache. Family checks are read
    /// from SwiftUI body getters (main actor today) but the cache is left
    /// lock-guarded so callers don't need any isolation guarantees.
    final class RegexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: NSRegularExpression] = [:]

        func regex(for pattern: String) -> NSRegularExpression {
            lock.lock()
            defer { lock.unlock() }
            if let cached = cache[pattern] { return cached }
            // Patterns are compile-time literals validated by the helpers
            // below, so a compilation failure is a programmer error.
            // swiftlint:disable:next force_try
            let compiled = try! NSRegularExpression(pattern: pattern)
            cache[pattern] = compiled
            return compiled
        }
    }

    static func isLingFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.hasPrefix("ling-") || lower.contains("/ling-")
    }

    /// Laguna bundles (poolside XS.2 + Mistral-lineage M.1) in repo,
    /// local-folder, and picker alias forms (`Laguna-M.1-JANG_2L`,
    /// `JANGQ-AI/Laguna-M.1-JANG_1L`). Both lines need the same serving
    /// loop hardening (repetition_penalty + a phrase-scale repetition
    /// window); bare greedy decode rambles post-answer at any precision.
    /// Strict enough to reject unrelated names like `notlaguna`.
    static func isLagunaFamily(_ modelId: String) -> Bool {
        matches(#"(^|/|[\-_])laguna($|[\-_/\.])"#, in: modelId.lowercased())
    }

    /// MiniMax M2/M2.7 bundles are always-reasoning at the template level:
    /// the generation prompt opens `<think>` and the model may complete with
    /// only that rail populated. Treat dash, underscore, dot, and owner/repo
    /// forms as the same family while rejecting unrelated names like
    /// `notminimax` or `minimaxed`.
    static func isMiniMaxFamily(_ modelId: String) -> Bool {
        matches(#"(^|/|[\-_])minimax($|[\-_/\.])"#, in: modelId.lowercased())
    }

    /// Qwen/Qwen3.x bundles in repo, local-folder, and picker alias forms.
    /// Keep this name-only helper strict enough to avoid words like
    /// `notqwen`, while accepting slash, dash, underscore, and versioned
    /// forms such as `qwen3.6-35b-a3b-mxfp4`.
    static func isQwenFamily(_ modelId: String) -> Bool {
        matches(#"(^|/|[\-_])qwen($|[\-_/\.0-9])"#, in: modelId.lowercased())
    }

    /// Gemma/Gemma3n/Gemma4 bundles in repo, local-folder, and picker alias
    /// forms. This is used for metadata surfaces only; tokenizer/template
    /// selection still comes from the resolved bundle.
    static func isGemmaFamily(_ modelId: String) -> Bool {
        matches(#"(^|/|[\-_])gemma($|[\-_/\.0-9])"#, in: modelId.lowercased())
    }

    /// DiffusionGemma block-diffusion bundles (`model_type=diffusion_gemma`).
    /// Keep this separate from ordinary Gemma 4 AR/QAT matching because the
    /// runtime needs a denoising-canvas engine, not TokenIterator decode.
    static func isDiffusionGemmaFamily(_ modelId: String) -> Bool {
        matches(#"(^|/|[\-_])diffusion[\-_]?gemma($|[\-_/\.0-9])"#, in: modelId.lowercased())
            || modelId.lowercased() == "diffusion_gemma"
    }

    /// LFM2 / LFM2.5 text and MoE bundles. Accept LiquidAI repo ids,
    /// local JANG bundle ids, and bare picker aliases while rejecting adjacent
    /// future-family names like `lfm21` / `lfm2x`.
    static func isLFM2Family(_ modelId: String) -> Bool {
        matches(#"(^|/)lfm2(([\._-]?5)?([\-_].*)?)?$"#, in: modelId.lowercased())
    }

    /// StepFun Step 3.5 / 3.7 bundles. Step 3.7 VLM-wrapped local
    /// JANG/JANGTQ models expose the Step 3.5-compatible text runtime and
    /// native template, but explicit required-tool calls need the corrected
    /// Step fallback template instead of the native always-open thinking rail.
    static func isStepFamily(_ modelId: String) -> Bool {
        matches(#"(^|/|[\-_])step($|[\-_/\.0-9])"#, in: modelId.lowercased())
    }

    /// MiMo V2.5 and Nex N2 local JANG/JANGTQ bundles are text/tool runtimes in
    /// this release lane. Matching is name-only and deliberately requires the
    /// JANG marker so future non-JANG MiMo/N2 media bundles still flow through
    /// bundle metadata detection.
    static func isMiMoOrN2JANGRuntimeFamily(_ modelId: String) -> Bool {
        let normalized =
            modelId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard normalized.contains("jang") else { return false }
        return normalized.contains("mimo-v2.5")
            || normalized.contains("nex-n2-pro")
    }

    /// DeepSeek-V4 / DSV4 Flash bundles (`model_type=deepseek_v4`).
    /// Match both public repo forms (`DeepSeek-V4-...`) and shorthand
    /// runtime names (`DSV4-...`, `deepseekv4-...`) while avoiding
    /// DeepSeek-V3 / R1 / generic DeepSeek matches.
    static func isDSV4Family(_ modelId: String) -> Bool {
        matches(#"(^|/|[\-_])(dsv4|deepseek[\-_]?v4|deepseekv4)($|[\-_/\.])"#, in: modelId.lowercased())
    }

    /// Nemotron Omni bundles. Match both the long public `Nemotron-3-Nano-Omni`
    /// naming and shorter local picker/API ids like `Nemotron-Omni-Nano`.
    static func isNemotronOmniFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return matches(#"(^|/)nemotron[\-_]3[\-_][^/]*omni($|[\-_/\.0-9])"#, in: lower)
            || matches(#"(^|/)nemotron[\-_]omni($|[\-_/\.0-9])"#, in: lower)
    }

    /// Nemotron bundles whose native template exposes an `enable_thinking`
    /// switch. Keep this broader than Omni media support but narrower than all
    /// historical Nemotron lineages.
    static func isNemotronThinkingFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return isNemotronOmniFamily(modelId)
            || matches(#"(^|/)nvidia[\-_]?nemotron[\-_]3[\-_]ultra($|[\-_/\.0-9])"#, in: lower)
            || matches(#"(^|/)nemotron[\-_]3[\-_]ultra($|[\-_/\.0-9])"#, in: lower)
    }

    /// Match Zyphra ZAYA bundles (`model_type=zaya`). Matches the bare
    /// repo form (`Zaya1-…`, `Zaya2-…`, `Zaya-S-…`) and any
    /// `<owner>/Zaya…` path. The required digit-or-dash boundary after
    /// `zaya` rejects unrelated names like `dataset/zayasaurus`,
    /// `lazyaardvark`, or `dazaya-llm` — mirror of `isLingFamily`'s
    /// dash-boundary trick, adjusted for ZAYA's digit-suffix naming.
    static func isZayaFamily(_ modelId: String) -> Bool {
        matches(#"(^|/)zaya[\-0-9]"#, in: modelId.lowercased())
    }

    /// ZAYA1-VL is a sibling family to text ZAYA: it shares the ZAYA name and
    /// CCA cache topology, but its production multimodal template lives in a
    /// `chat_template.json` sidecar and does not expose the text ZAYA
    /// `enable_thinking` branch. Keep the matcher separate so UI profiles do
    /// not advertise a toggle that the active template cannot consume.
    static func isZayaVLFamily(_ modelId: String) -> Bool {
        matches(#"(^|/)zaya[\-_]?1[\-_]?vl($|[\-_/\.0-9])"#, in: modelId.lowercased())
    }
}
