//
//  ToolOutputCompressor.swift
//  osaurus
//
//  Lossless, deterministic compaction applied to a tool result the moment it
//  is produced — at the `ToolRegistry.normalizeToolResult` boundary, BEFORE
//  the per-tool / universal caps (`ToolOutputCaps`), head/tail truncation, and
//  conversation budgeting (`ContextBudgetManager`) ever see it.
//
//  Why this lives at ingest, and why it is strictly lossless:
//  - Every tool result costs fewer context tokens immediately, on the turn it
//    lands and on every later turn it is replayed.
//  - More *real* content fits under `ToolOutputCaps` before the head/tail
//    backstop has to cut — so this is also a correctness win (less lossy
//    truncation of legitimately large-but-formatting-heavy payloads).
//  - History grows slower, so compaction pressure (the lossy
//    `summarizeToolResult` stub path) is reached later.
//
//  This is deliberately *lossless*: there is no out-of-band store and nothing
//  to "re-expand". A model re-reading the value sees identical semantics. That
//  is what makes the transform safe to apply unconditionally and keeps the
//  KV-prefix byte-stable — the same input always maps to the same output, so a
//  replayed tool message hashes identically turn over turn.
//
//  Scope of the two transforms (both provably meaning-preserving):
//  1. JSON whitespace crush. JSON inter-token whitespace carries zero meaning;
//     whitespace *inside* string literals does and is preserved verbatim. We
//     only crush a payload we have first validated as well-formed JSON, and we
//     scan the ORIGINAL bytes (never reserialize), so key order, string
//     contents, number lexemes, and escaping are all preserved exactly.
//     NB: Osaurus's own envelopes already serialize compact
//     (`.osaurusCanonical` = `[.sortedKeys, .withoutEscapingSlashes]`), so this
//     is a no-op on our own tool JSON. The win lands on EXTERNAL pretty JSON
//     that arrives as a raw result — `shell_run` of `… | jq .`, MCP provider
//     text, a pretty `.json` read via `file_read`, plugin prose.
//  2. Trailing-whitespace strip. Trailing spaces/tabs on a line are never
//     semantically meaningful; interior whitespace, line structure, and the
//     final newline are all preserved. Applied to any non-JSON payload.
//

import Foundation

public enum ToolOutputCompressor {
    /// Escape hatch (default ON). Set `OSAURUS_DISABLE_TOOL_OUTPUT_COMPRESSION=1`
    /// to bypass entirely. Used by the eval gate to A/B the transform, and an
    /// out for any caller that must preserve byte-exact upstream formatting.
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["OSAURUS_DISABLE_TOOL_OUTPUT_COMPRESSION"] != "1"
    }

    /// Below this many UTF-8 bytes the formatting savings cannot beat the cost
    /// of an extra scan + allocation, and tiny payloads are not where context
    /// goes. Measured on bytes so it is cheap and encoding-stable.
    static let minimumLength = 256

    /// Above this many UTF-8 bytes we skip the JSON validate+crush passes:
    /// `normalizeToolResult` runs on the main-actor registry path, the two
    /// O(n) passes would add latency there, and any payload this large is
    /// already past the universal cap (`ToolOutputCaps.universalResult`) and
    /// will be head/tail truncated regardless — crushing it first cannot save
    /// it. Trailing-whitespace stripping is a single cheap pass and still runs.
    static let maximumJSONScanBytes = 512 * 1024

    /// Returns `raw` with insignificant formatting removed, preserving meaning
    /// exactly. Deterministic and idempotent: `compact(compact(x)) == compact(x)`.
    public static func compact(_ raw: String) -> String {
        guard isEnabled else { return raw }
        let byteCount = raw.utf8.count
        guard byteCount >= minimumLength else { return raw }

        // Classify on the first non-whitespace scalar. JSON is the high-value,
        // provably-safe target; everything else only gets trailing-strip.
        let scalars = raw.unicodeScalars
        guard let firstIdx = scalars.firstIndex(where: { !isJSONWhitespace($0) }) else {
            return raw
        }
        let first = scalars[firstIdx]
        if (first == "{" || first == "["), byteCount <= maximumJSONScanBytes,
            let crushed = crushedJSONIfValid(raw)
        {
            return crushed
        }
        return strippedTrailingWhitespace(raw)
    }

    // MARK: - JSON whitespace crush

    /// Validates `s` as well-formed JSON, then returns it with all whitespace
    /// *outside* string literals removed. Returns `nil` when `s` is not valid
    /// JSON, so a `{`/`[`-leading non-JSON payload (a brace-y template, a log
    /// line) is never corrupted — it falls through to the trailing-strip path.
    ///
    /// We scan the original string rather than reserialize the parsed object so
    /// that key order, duplicate keys, number lexemes (e.g. `1.0` vs `1`), and
    /// the source's slash/unicode escaping are all preserved byte-for-byte. In
    /// well-formed JSON, value tokens are always delimited by structural
    /// characters (`{}[],:`) or strings, never by whitespace alone, so dropping
    /// inter-token whitespace can never merge two tokens.
    static func crushedJSONIfValid(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data, options: [])) != nil
        else { return nil }

        var out = ""
        out.reserveCapacity(s.utf8.count)
        var inString = false
        var escaped = false
        for ch in s.unicodeScalars {
            if inString {
                out.unicodeScalars.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            if ch == "\"" {
                inString = true
                out.unicodeScalars.append(ch)
                continue
            }
            if isJSONWhitespace(ch) {
                continue  // insignificant whitespace between tokens
            }
            out.unicodeScalars.append(ch)
        }
        return out
    }

    // MARK: - Trailing-whitespace strip

    /// Removes runs of spaces/tabs that sit immediately before a line break or
    /// the end of input. Interior whitespace, every line break (LF or CRLF),
    /// and the final newline are preserved. Returns the original string
    /// (identity) when nothing changed, to avoid a needless allocation.
    static func strippedTrailingWhitespace(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var pending: [Unicode.Scalar] = []  // buffered space/tab run
        var changed = false
        for ch in s.unicodeScalars {
            if ch == " " || ch == "\t" {
                pending.append(ch)
                continue
            }
            if ch == "\n" || ch == "\r" {
                if !pending.isEmpty {
                    changed = true
                    pending.removeAll(keepingCapacity: true)
                }
                out.unicodeScalars.append(ch)
                continue
            }
            if !pending.isEmpty {
                out.unicodeScalars.append(contentsOf: pending)  // interior run — keep it
                pending.removeAll(keepingCapacity: true)
            }
            out.unicodeScalars.append(ch)
        }
        if !pending.isEmpty { changed = true }  // trailing run at EOF — drop it
        return changed ? out : s
    }

    // MARK: - Helpers

    /// The four characters JSON (RFC 8259) treats as insignificant whitespace.
    static func isJSONWhitespace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\r"
    }
}
