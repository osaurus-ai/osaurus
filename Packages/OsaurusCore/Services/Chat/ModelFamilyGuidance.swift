//
//  ModelFamilyGuidance.swift
//  osaurus
//
//  Per-model-family operational guidance appended to the system prompt.
//
//  Different model families have different reliability gaps:
//    - Gemma tends to enumerate tools, hallucinate names, and get chatty.
//    - GPT/Codex needs explicit "act, don't promise" + verification framing.
//    - GLM/Qwen are usually well-behaved; a small reminder is enough.
//    - Everything else gets nothing — silence is a feature.
//
//  Each family gets a tightly-targeted block instead of one universal
//  addendum that satisfies no one and inflates every prompt.
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
    case glmQwen
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

        let groups: [(ModelFamily, [String])] = [
            (.gptCodex, ["gpt", "codex", "o1", "o3", "o4"]),
            (.googleGemma, ["gemma", "gemini"]),
            (.glmQwen, ["glm", "qwen"]),
        ]
        for (family, markers) in groups where markers.contains(where: raw.contains) {
            return family
        }
        return .other
    }

    /// The guidance block for a family, or nil when no extra guidance is warranted.
    /// Blocks are intentionally short — the goal is targeted nudges, not a manual.
    static func guidance(for family: ModelFamily) -> String? {
        switch family {
        case .gptCodex: return gptCodexGuidance
        case .googleGemma: return googleGemmaGuidance
        case .glmQwen: return glmQwenGuidance
        case .other: return nil
        }
    }

    /// Convenience: resolve and return guidance for a model id in one call.
    static func guidance(forModelId modelId: String?) -> String? {
        guidance(for: family(for: modelId))
    }

    // MARK: - Family blocks

    /// GPT / Codex / o-series: persistence + verification + act-don't-ask.
    /// The XML-tag shape matters — these models were trained to weight
    /// `<tag>...</tag>` blocks as structured directives rather than as
    /// prose suggestions, so we keep that wrapping for each section.
    static let gptCodexGuidance = """
        # Execution discipline

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

    /// Google Gemma / Gemini: anti-hallucination + execute-don't-narrate.
    /// Includes an explicit "do not enumerate tools" line because Gemma
    /// has been observed listing fictional tool names in its thinking.
    /// The path-style line is intentionally absent — folder mode requires
    /// relative paths for `file_*` tools and sandbox mode is path-agnostic
    /// inside the container, so a global "use absolute paths" directive
    /// would actively conflict with the active mode template.
    static let googleGemmaGuidance = """
        # Operational directives

        - **Only call tools that exist in your schema.** Do not enumerate, list, \
          or describe your available tools in your reply. If you don't see a tool \
          you'd want, work around it or ask the user — never call or mention a \
          name that isn't in your schema.
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

    /// GLM / Qwen: persistence + termination, both explicit. Without the
    /// "keep going" bullet these models read a single tool result and
    /// summarise instead of taking the next step; without the tightened
    /// "stop only when genuinely done" bullet they invent extra steps to
    /// look thorough. Pairs well with the folder-context act-don't-narrate
    /// line for `.hostFolder` chats.
    static let glmQwenGuidance = """
        # Reminders

        - Only call tools that exist in your schema. If a capability is \
          missing, work around it or tell the user.
        - Prefer one rich shell invocation over many small calls when the \
          steps are mechanical.
        - Keep going until the task is done. After a tool returns, take \
          the next concrete action — read a file, write a file, run a \
          command. Don't stop after a single exploration step to describe \
          what you'll do next; just do the next step.
        - When you've genuinely finished, say so plainly and stop calling \
          tools. Don't invent extra steps to look thorough.
        """
}
