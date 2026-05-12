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
