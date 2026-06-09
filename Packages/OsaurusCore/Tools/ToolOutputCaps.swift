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

    /// `git_diff` rendered diff.
    static let gitDiff = 20_000

    /// Rendered directory tree (folder context + `file_read` on a
    /// directory). Retained in context across later turns, so smallest.
    static let tree = 8_000
}
