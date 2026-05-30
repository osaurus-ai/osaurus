//
//  ModelFamilyNames.swift
//  osaurus
//
//  Small, exact family-name helpers shared by catalog/profile/runtime code.
//

enum ModelFamilyNames {
    static func isLingFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.hasPrefix("ling-") || lower.contains("/ling-")
    }

    /// MiniMax M2/M2.7 bundles are always-reasoning at the template level:
    /// the generation prompt opens `<think>` and the model may complete with
    /// only that rail populated. Treat dash, underscore, dot, and owner/repo
    /// forms as the same family while rejecting unrelated names like
    /// `notminimax` or `minimaxed`.
    static func isMiniMaxFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/|[\-_])minimax($|[\-_/\.])"#,
            options: .regularExpression
        ) != nil
    }

    /// Qwen/Qwen3.x bundles in repo, local-folder, and picker alias forms.
    /// Keep this name-only helper strict enough to avoid words like
    /// `notqwen`, while accepting slash, dash, underscore, and versioned
    /// forms such as `qwen3.6-35b-a3b-mxfp4`.
    static func isQwenFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/|[\-_])qwen($|[\-_/\.0-9])"#,
            options: .regularExpression
        ) != nil
    }

    /// Gemma/Gemma3n/Gemma4 bundles in repo, local-folder, and picker alias
    /// forms. This is used for metadata surfaces only; tokenizer/template
    /// selection still comes from the resolved bundle.
    static func isGemmaFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/|[\-_])gemma($|[\-_/\.0-9])"#,
            options: .regularExpression
        ) != nil
    }

    /// LFM2 / LFM2.5 text and MoE bundles. Accept LiquidAI repo ids,
    /// local JANG bundle ids, and bare picker aliases while rejecting adjacent
    /// future-family names like `lfm21` / `lfm2x`.
    static func isLFM2Family(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/)lfm2(([\._-]?5)?([\-_].*)?)?$"#,
            options: .regularExpression
        ) != nil
    }

    /// DeepSeek-V4 / DSV4 Flash bundles (`model_type=deepseek_v4`).
    /// Match both public repo forms (`DeepSeek-V4-...`) and shorthand
    /// runtime names (`DSV4-...`, `deepseekv4-...`) while avoiding
    /// DeepSeek-V3 / R1 / generic DeepSeek matches.
    static func isDSV4Family(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/|[\-_])(dsv4|deepseek[\-_]?v4|deepseekv4)($|[\-_/\.])"#,
            options: .regularExpression
        ) != nil
    }

    /// Nemotron Omni bundles. Match both the long public `Nemotron-3-Nano-Omni`
    /// naming and shorter local picker/API ids like `Nemotron-Omni-Nano`.
    static func isNemotronOmniFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/)nemotron[\-_]3[\-_][^/]*omni($|[\-_/\.0-9])"#,
            options: .regularExpression
        ) != nil
            || lower.range(
                of: #"(^|/)nemotron[\-_]omni($|[\-_/\.0-9])"#,
                options: .regularExpression
            ) != nil
    }

    /// Match Zyphra ZAYA bundles (`model_type=zaya`). Matches the bare
    /// repo form (`Zaya1-…`, `Zaya2-…`, `Zaya-S-…`) and any
    /// `<owner>/Zaya…` path. The required digit-or-dash boundary after
    /// `zaya` rejects unrelated names like `dataset/zayasaurus`,
    /// `lazyaardvark`, or `dazaya-llm` — mirror of `isLingFamily`'s
    /// dash-boundary trick, adjusted for ZAYA's digit-suffix naming.
    static func isZayaFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/)zaya[\-0-9]"#,
            options: .regularExpression
        ) != nil
    }

    /// ZAYA1-VL is a sibling family to text ZAYA: it shares the ZAYA name and
    /// CCA cache topology, but its production multimodal template lives in a
    /// `chat_template.json` sidecar and does not expose the text ZAYA
    /// `enable_thinking` branch. Keep the matcher separate so UI profiles do
    /// not advertise a toggle that the active template cannot consume.
    static func isZayaVLFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/)zaya[\-_]?1[\-_]?vl($|[\-_/\.0-9])"#,
            options: .regularExpression
        ) != nil
    }
}
