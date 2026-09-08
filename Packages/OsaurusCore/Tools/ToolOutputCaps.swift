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

    /// Absolute `file_read` ceiling. A file whose full content fits under
    /// this serves in ONE call, and an explicit `max_chars` may raise the
    /// per-call cap up to it (previously `max_chars` was clamped DOWN to
    /// `fileRead`, so a 36KB attachment always cost three chunked reads —
    /// three decode-bound agent turns). `next_start_line` continuation
    /// chunking remains for files above this ceiling.
    static let fileReadMax = 60_000

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

    /// Byte-exact form for a BYTE budget. Character slicing cannot bound bytes:
    /// one `Character` may carry an unbounded combining sequence (an "x"
    /// followed by 60,000 combining acutes is a single 120,001-byte grapheme,
    /// and `apply` returns it unchanged for any cap ≥ 1). This keeps a UTF-8
    /// head and tail cut at Unicode-scalar boundaries — always valid UTF-8, a
    /// grapheme may be split — with the same marker, whose own bytes count
    /// against the cap. The result is never longer than `byteCap` bytes
    /// whenever the cap covers the marker (a cap smaller than the ~100-byte
    /// marker returns the marker alone).
    static func applyByteExact(_ text: String, byteCap: Int, headFraction: Double, hint: String? = nil) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > byteCap else { return text }
        let hintSuffix = hint.map { " — \($0)" } ?? ""
        // The largest scalar start at or before `i` (a UTF-8 continuation
        // byte is 0b10xxxxxx).
        func scalarStart(_ i: Int) -> Int {
            var j = min(max(i, 0), utf8.count)
            while j > 0, j < utf8.count, utf8[j] & 0xC0 == 0x80 { j -= 1 }
            return j
        }
        func nextScalarStart(_ i: Int) -> Int {
            var j = i + 1
            while j < utf8.count, utf8[j] & 0xC0 == 0x80 { j += 1 }
            return min(j, utf8.count)
        }
        let marker = "\n... [TRUNCATED: \(utf8.count) bytes total, head and tail kept\(hintSuffix)] ...\n"
        let contentBudget = max(0, byteCap - marker.utf8.count)
        var headEnd = scalarStart(Int(Double(contentBudget) * headFraction))
        var tailStart = scalarStart(utf8.count - max(0, contentBudget - headEnd))
        if tailStart < headEnd { tailStart = headEnd }
        // Backing the tail off to a scalar start can only grow it; advance to
        // the next scalar start until head + tail fit the content budget.
        while tailStart < utf8.count, headEnd + (utf8.count - tailStart) > contentBudget {
            tailStart = nextScalarStart(tailStart)
        }
        while headEnd > 0, headEnd + (utf8.count - tailStart) > contentBudget {
            headEnd = scalarStart(headEnd - 1)
        }
        let head = String(decoding: utf8[0..<headEnd], as: UTF8.self)
        let tail = String(decoding: utf8[tailStart...], as: UTF8.self)
        return head + marker + tail
    }
}
