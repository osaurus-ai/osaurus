//
//  ModelFamilyGuidance.swift
//  osaurus
//
//  Per-model-family operational guidance appended to the system prompt.
//
//  Different model families have different reliability gaps:
//    - Gemma tends to enumerate tools, hallucinate names, and get chatty.
//    - Gemini (frontier API models) shares Gemma's lineage but not its
//      failure modes — it gets a persistence/verification block without
//      the brevity clamp written for 4B local Gemma.
//    - GPT/Codex needs explicit "act, don't promise" + verification framing.
//    - GLM/Qwen are usually well-behaved; a small reminder is enough.
//    - DeepSeek/DSV4 can narrate a tool plan instead of emitting DSML, so
//      it gets a compact act-now reminder.
//    - LFM2 (Liquid) is a small-active MoE that, without an obedience
//      counterweight, over-applies the prohibition sections (codeStyle /
//      riskAware) and refuses or hedges. It gets a persistence block.
//    - Everything else gets a minimal default obedience block. An
//      unguided model paired with the always-on prohibition sections
//      reads as net-restrictive (refuses more) and, when it does act
//      with no fitting tool, fabricates. The default block is the
//      smallest counterweight that keeps it obedient; the anti-invention
//      guardrail is owned by `SystemPromptTemplates.groundingDirective`,
//      which co-fires for every tool-enabled chat with a non-empty schema.
//
//  Each family gets a tightly-targeted block; the default block is kept
//  minimal so it does not inflate every prompt the way a full universal
//  agentic addendum would.
//
//  The blocks are static strings so they survive the prompt-caching path.
//  Resolution is a case-insensitive substring match on the model id, with
//  a precedence order chosen so e.g. "gpt-codex-gemma-finetune" maps to
//  GPT/Codex (the most distinctive marker wins).
//

import Foundation

enum ModelFamily: String, Sendable {
    case gptCodex
    case googleGemma
    case googleGemini
    case glmQwen
    case deepSeek
    case lfm2
    case other
}

enum ModelFamilyGuidance {

    /// Resolve the family for a model id (e.g. "gpt-4o", "gemma-4-26b-it", "qwen3-32b-mlx").
    /// Markers checked in order of specificity — `gpt`/`codex`/`o-series`
    /// first because a finetune name might mention multiple families.
    static func family(for modelId: String?) -> ModelFamily {
        guard let raw = modelId?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return .other }

        // GPT/Codex first (most distinctive markers win on finetune mashups).
        // The o-series markers are matched on token boundaries, NOT bare
        // substrings — `contains("o3")` would misroute `molmo3`, `yolo11`
        // etc. into the GPT XML block.
        if raw.contains("gpt") || raw.contains("codex") || containsOSeriesToken(raw) {
            return .gptCodex
        }
        let groups: [(ModelFamily, [String])] = [
            (.googleGemini, ["gemini"]),
            (.googleGemma, ["gemma"]),
            (.glmQwen, ["glm", "qwen"]),
            (.deepSeek, ["deepseek", "dsv4"]),
        ]
        for (family, markers) in groups where markers.contains(where: raw.contains) {
            return family
        }
        // LFM2 uses the precise name matcher (rejects adjacent future
        // families like `lfm21`) rather than a bare substring so it stays
        // consistent with the rest of the runtime's family detection.
        if ModelFamilyNames.isLFM2Family(raw) {
            return .lfm2
        }
        return .other
    }

    /// OpenAI o-series markers that need token-boundary matching. A token
    /// is a maximal run of alphanumerics in the id (separators: `-`, `_`,
    /// `/`, `.`, spaces…), so `o1-preview`, `openai/o3-mini`, and a bare
    /// `o4` match while `molmo3`, `yolo11`, and `turbo4` do not.
    private static let oSeriesTokens: Set<String> = ["o1", "o3", "o4"]

    private static func containsOSeriesToken(_ raw: String) -> Bool {
        raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { oSeriesTokens.contains(String($0)) }
    }

    /// The guidance block for a family. Every family — including `.other` —
    /// now returns a block: the family-specific ones target known failure
    /// modes, and the default block is the minimal obedience counterweight
    /// for unrecognised families (Apple Foundation, etc.) so they are not
    /// left with only the prohibition sections. Blocks are intentionally
    /// short — targeted nudges, not a manual. Non-optional: every family
    /// resolves to a block now, so the "skip the row" decision lives one
    /// level up in `guidance(forModelId:)` (which still returns nil for a
    /// blank id).
    static func guidance(for family: ModelFamily) -> String {
        switch family {
        case .gptCodex: return gptCodexGuidance
        case .googleGemma: return googleGemmaGuidance
        case .googleGemini: return googleGeminiGuidance
        case .glmQwen: return glmQwenGuidance
        case .deepSeek: return deepSeekGuidance
        case .lfm2: return lfm2Guidance
        case .other: return defaultGuidance
        }
    }

    /// Compact variant for small-context (`.small`, ~8K window) models.
    /// Only the two blocks with meaningful token weight have a dedicated
    /// compact form (GPT/Codex's XML block and Gemma's bullet list); the
    /// rest are already minimal, so compact == full for them. Both variants
    /// are static strings keyed on session-constant inputs (family + size
    /// class), so the choice is KV-cache safe.
    static func compactGuidance(for family: ModelFamily) -> String {
        switch family {
        case .gptCodex: return gptCodexGuidanceCompact
        case .googleGemma: return googleGemmaGuidanceCompact
        default: return guidance(for: family)
        }
    }

    /// Convenience: resolve and return guidance for a model id in one call.
    /// Returns `nil` for a nil/blank id (the fresh-preview state before a
    /// model is picked) — the default obedience block is for known-but-
    /// unrecognised models, not "no model yet", and emitting it speculatively
    /// would bias the budget popover before the model is even chosen.
    ///
    /// `compact` selects the small-context variant where one exists (see
    /// `compactGuidance(for:)`); callers pass `sizeClass == .small`.
    static func guidance(forModelId modelId: String?, compact: Bool = false) -> String? {
        guard let raw = modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        let resolved = family(for: raw)
        return compact ? compactGuidance(for: resolved) : guidance(for: resolved)
    }

    // MARK: - Family blocks
    //
    // None of the blocks restate the tool-grounding rule ("only call tools
    // that exist in your schema / never invent a tool name / never deny a
    // listed capability"). That statement is owned by
    // `SystemPromptTemplates.groundingDirective`, which co-fires with every
    // family block that has a non-empty tool schema — and, unlike a shared
    // line here, it picks the schema-correct variant (the tool-name-free
    // base when `capabilities_discover` isn't resolvable). Re-stating it
    // here both duplicated ~40 tokens per prompt and named tools that some
    // schemas (Default agent, manual mode) cannot call.

    /// GPT / Codex / o-series: persistence + verification + act-don't-ask.
    /// The XML-tag shape matters — these models were trained to weight
    /// `<tag>...</tag>` blocks as structured directives rather than as
    /// prose suggestions, so we keep that wrapping for each section.
    static let gptCodexGuidance = """
        ## Execution discipline

        <tool_persistence>
        - Use tools whenever they improve correctness, completeness, or grounding.
        - Do not stop early when another tool call would materially improve the result.
        - If a tool returns empty or partial results, retry with a different query \
        or strategy before giving up.
        - Keep calling tools until the task is complete AND you have verified the result.
        </tool_persistence>

        <act_dont_ask>
        When a question has an obvious default interpretation, act on it immediately \
        instead of asking. Examples:
        - "What's in this directory?" → list it. Don't ask "which one?".
        - "Is this command available?" → check it. Don't guess.
        - "What's the current time?" → run `date`. Don't approximate.
        Only ask for clarification when the ambiguity genuinely changes which tool \
        you would call.
        </act_dont_ask>

        <verification>
        Before declaring the task done:
        - Correctness: does the output satisfy every stated requirement?
        - Grounding: are factual claims backed by tool outputs?
        - Format: does the output match the requested shape?
        If you used a shell command to make a change, run a follow-up command to \
        confirm the change took effect.
        </verification>

        <missing_context>
        - If required context is missing, do NOT guess or hallucinate.
        - Use the appropriate lookup tool (read a file, run a command, search the web) \
        when the missing info is retrievable.
        - Ask a clarifying question only when the information cannot be retrieved \
        by tools.
        - If you must proceed with incomplete info, label assumptions explicitly.
        </missing_context>
        """

    /// Compact GPT/Codex variant for `.small` windows. Keeps the four
    /// themes (persistence, act-don't-ask, verification, missing context)
    /// as one bullet each; drops the XML wrapping and worked examples that
    /// dominate the full block's token cost.
    static let gptCodexGuidanceCompact = """
        ## Execution discipline

        - Use tools whenever they improve correctness or grounding; keep \
        calling tools until the task is complete AND verified. Retry with a \
        different strategy before giving up on empty or partial results.
        - When a question has an obvious default interpretation, act on it \
        immediately instead of asking.
        - Before declaring done, check correctness, grounding, and format. \
        After a change, run a follow-up command to confirm it took effect.
        - If required context is missing, retrieve it with a tool; ask only \
        when it cannot be retrieved. Label assumptions if you must proceed.
        """

    /// Google Gemini (frontier API models): persistence + verification +
    /// parallel batching. Shares Gemma's lineage marker but NOT its block —
    /// the "few sentences" brevity clamp and anti-enumeration paranoia were
    /// written for 4B local Gemma's failure modes and actively hurt a
    /// frontier Gemini doing multi-step agentic work.
    static let googleGeminiGuidance = """
        ## Operational directives

        - Act, don't narrate. When the next step is a tool call, emit it in \
        this response — don't describe what you would do.
        - Parallel tool calls when independent: batch reads and searches in \
        one response instead of sequencing them.
        - Keep going until the task is complete and verified; after a change, \
        confirm it took effect.
        - Use non-interactive flags (`-y`, `--yes`, `--non-interactive`) so \
        shell tools don't hang waiting for prompts.
        """

    /// Google Gemma: anti-hallucination + execute-don't-narrate.
    /// Includes an explicit "do not enumerate tools" line because Gemma
    /// has been observed listing fictional tool names in its thinking.
    /// The path-style line is intentionally absent — folder mode requires
    /// relative paths for `file_*` tools and sandbox mode is path-agnostic
    /// inside the container, so a global "use absolute paths" directive
    /// would actively conflict with the active mode template.
    static let googleGemmaGuidance = """
        ## Operational directives

        - **Don't enumerate tools.** Never list or describe your available \
        tools in your reply, and never mention a name that isn't in your schema.
        - **Verify before you act.** Read the file or list the directory first \
        when a path is involved; never guess at file contents.
        - **Be concise.** Brief plain-language answers — a few sentences, not \
        paragraphs. Save the exposition for when the user asks for it.
        - **Parallel tool calls when independent.** When you need to read three \
        files, call all three reads in one response, not sequentially.
        - **Non-interactive flags.** Use `-y`, `--yes`, `--non-interactive` so \
        shell tools don't hang waiting for prompts.
        - **Keep going until done.** Don't stop with a plan or a promise — \
        execute it. Either make a tool call that progresses the task, or \
        deliver the final result.
        """

    /// Compact Gemma variant for `.small` windows: the same guardrails,
    /// one line each.
    static let googleGemmaGuidanceCompact = """
        ## Operational directives

        - Never list or describe your tools in a reply, and never mention a \
        name that isn't in your schema.
        - Be concise — a few sentences, not paragraphs.
        - Verify before you act: read the file or list the directory first \
        when a path is involved; never guess at contents.
        - Keep going until done — make a tool call that progresses the task \
        or deliver the final result.
        """

    /// GLM / Qwen: persistence + termination, both explicit. Without the
    /// "keep going" bullet these models read a single tool result and
    /// summarise instead of taking the next step; without the tightened
    /// "stop only when genuinely done" bullet they invent extra steps to
    /// look thorough. Pairs well with the folder-context act-don't-narrate
    /// line for `.hostFolder` chats.
    static let glmQwenGuidance = """
        ## Reminders

        - Prefer one rich shell invocation over many small calls when the \
        steps are mechanical.
        - Keep going until the task is done. After a tool returns, take \
        the next concrete action — read a file, write a file, run a \
        command. Don't stop after a single exploration step to describe \
        what you'll do next; just do the next step.
        - When you've genuinely finished, say so plainly and stop calling \
        tools. Don't invent extra steps to look thorough.
        """

    /// DeepSeek / DSV4: strong act-now guidance. DSV4 local rows prove it can
    /// emit structured DSML tool calls, but in app chat it may otherwise say
    /// "let me look" and then stop with text. This block avoids naming any
    /// specific tool so it stays safe outside folder/sandbox mode; the active
    /// schema and mode-specific prompt sections carry the actual tool names.
    static let deepSeekGuidance = """
        ## Tool-use discipline

        - If the next step is to inspect files, list a directory, run a \
        command, check state, or verify a claim, emit the appropriate tool \
        call now. Do not say you will do it and then stop.
        - If you mention looking, checking, reading, listing, running, editing, \
        or verifying something, perform that action with a listed tool in the \
        same response.
        - After a tool result, continue with the next concrete tool call when \
        more evidence is needed. Only answer in prose once the requested work \
        is actually grounded or complete.
        """

    /// LFM2 / Liquid: small-active MoE that hedges and refuses when it sees
    /// the prohibition sections (codeStyle / riskAware) without an obedience
    /// counterweight. This block restores the "you have tools, act when you
    /// can" framing. The anti-fabrication push lives once in
    /// `SystemPromptTemplates.groundingDirective`, but the no-direct-tool →
    /// fetch case IS reinforced here: this family reliably reads the directive's
    /// caution half and skips its action half (observed: declining a weather
    /// query with sandbox + network tools available), so the imperative belongs
    /// where the family actually acts on it.
    static let lfm2Guidance = """
        ## Reminders

        - You have tools. When a listed tool can satisfy the request, call it — \
        do not decline, and do not just describe what you would do.
        - When NO listed tool directly fits a live-data request (weather, prices, \
        web pages, current state), don't decline — fetch it yourself with \
        sandbox_exec (e.g. curl) or run capabilities_discover first. Treating a \
        missing purpose-built tool as a dead end is an error.
        - For local, reversible work (reading, editing a file, running a test), \
        just proceed. Ask a clarifying question only when guessing wrong would \
        change the result.
        - Keep going until the task is done, then stop — don't add extra steps \
        to look thorough.
        """

    /// Default block for unrecognised families (Apple Foundation and any
    /// future model). The smallest obedience counterweight that offsets the
    /// always-on prohibition sections without encouraging tool enumeration —
    /// "a listed tool" keeps the framing anchored to the schema. Live-data /
    /// anti-invention rules ("never invent a tool name", capability claims
    /// need backing) are owned by `SystemPromptTemplates.groundingDirective`,
    /// which co-fires whenever the request carries a tool schema, so they are
    /// intentionally not repeated here.
    static let defaultGuidance = """
        ## Reminders

        - Use a listed tool when it improves correctness or grounds a claim. \
        Don't decline a request you have the tools to satisfy.
        """
}
