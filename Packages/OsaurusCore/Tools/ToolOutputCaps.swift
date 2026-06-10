//
//  ToolOutputCaps.swift
//  osaurus
//
//  Single source of truth for the per-tool output character caps that
//  protect the context window from runaway tool results. Historically
//  these values were scattered as literals across `BuiltinSandboxTools`,
//  `FolderTools`, and `SandboxPluginTool`; centralising them keeps the
//  tiers deliberate and makes future tuning (e.g. context-size-class-aware
//  caps) a one-file edit.
//
//  Tier rationale (unchanged from the historical values):
//  - exec stdout gets the biggest budget (build logs, test output) with
//    head+tail bias applied by `truncateForModel`.
//  - stderr / shell output sit lower — they're usually short and the
//    interesting lines are at the tail.
//  - file_read sits in between: enough for a real source file, not enough
//    to dump a generated artifact.
//  - tree renders smallest: it's retained context on EVERY later turn.
//

import Foundation

enum ToolOutputCaps {
    /// `sandbox_exec` / plugin stdout — `truncateForModel`'s default
    /// budget (~12.5K tokens), head+tail biased.
    static let execStdout = 50_000

    /// stderr companion cap for exec/shell/plugin envelopes.
    static let execStderr = 10_000

    /// Combined stdout+stderr in a post-retry exec summary envelope.
    static let execRetryCombined = 20_000

    /// Combined first-attempt output embedded in a retry-failure envelope
    /// (the second attempt's output rides next to it, so keep it tight).
    static let execFirstAttemptCombined = 10_000

    /// `file_read` rendered output (also the workbook-preview cap).
    static let fileRead = 15_000

    /// `shell_run` combined output.
    static let shellOutput = 10_000

    /// `file_search` rendered content-match output. Sits between
    /// `shellOutput` and `fileRead`: match lines are information-dense,
    /// but a broad pattern over a big tree must not dump the tree.
    static let fileSearch = 12_000

    /// Hard ceiling on `file_search` / `sandbox_search_files`
    /// `max_results` regardless of what the model asks for.
    static let searchMaxResults = 500

    /// `git_diff` rendered diff.
    static let gitDiff = 20_000

    /// Rendered directory tree (folder context + `file_read` on a
    /// directory). Retained in context across later turns, so smallest.
    static let tree = 8_000

    /// Universal post-execute cap applied at the registry boundary
    /// (`ToolRegistry.normalizeToolResult`) to EVERY tool result — MCP
    /// base64 payloads, plugin prose, `capabilities_load` dumps. The
    /// per-tool caps above shape output deliberately; this is the
    /// backstop that guarantees no single call can blow the context.
    /// Sized above the largest legitimate per-tool envelope (a maximal
    /// `sandbox_exec` result: 50K stdout + 10K stderr, JSON-escaped) so
    /// deliberately-capped envelopes are never re-mangled. ~25K tokens.
    static let universalResult = 100_000
}

/// The one head+tail truncation used everywhere a cap from above is
/// enforced. Keeping both ends matters because a prefix-only cut drops
/// exactly the part the model usually needs next (a build's failure
/// summary, a diff's trailing files); a single implementation keeps the
/// omission marker byte-consistent across tools so models learn one shape.
enum HeadTailTruncation {
    /// Returns `text` unchanged when it fits `cap`; otherwise keeps
    /// `headFraction` of the budget from the front, the rest from the
    /// back, with an omission marker between them. `hint` rides inside
    /// the marker and should tell the model how to retrieve the missing
    /// middle (re-run narrower, scope to one file, …).
    static func apply(_ text: String, cap: Int, headFraction: Double, hint: String? = nil) -> String {
        guard text.count > cap else { return text }
        let headChars = Int(Double(cap) * headFraction)
        let tailChars = cap - headChars
        let omitted = text.count - headChars - tailChars
        let hintSuffix = hint.map { " — \($0)" } ?? ""
        return String(text.prefix(headChars))
            + "\n... [TRUNCATED: \(omitted) of \(text.count) chars omitted\(hintSuffix)] ...\n"
            + String(text.suffix(tailChars))
    }
}
