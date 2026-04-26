//
//  ThinkTagScrubber.swift
//  osaurus
//
//  Defensive post-filter for `Generation.chunk(String)` text on models
//  that have `LocalReasoningCapability.supportsThinking == true`.
//
//  vmlx's `ReasoningParser` only toggles state on a SEEN opener:
//  - In `content` mode it scans for `<think>` and switches to reasoning.
//  - In `reasoning` mode it scans for `</think>` and switches to content.
//
//  When a low-bit MoE checkpoint (MiniMax M2.7 Small JANGTQ 2-bit, GLM
//  JANG_2L, DSV4-Flash JANGTQ_2L, Kimi K2.6 REAP-30 JANGTQ_2L, etc.)
//  emits an ORPHAN `</think>` while the parser is in `content` mode —
//  i.e. without a matching `<think>` opener earlier — vmlx's parser
//  leaves the literal tag in the buffer and surfaces it as part of
//  `.content(text)` → osaurus receives `Generation.chunk("…</think>…")`
//  → tag leaks into the visible response. Symmetric leak for orphan
//  `<think>` while in reasoning mode.
//
//  This scrubber buffers up to `max(startTag, endTag).count - 1` bytes
//  at the chunk-stream tail (mirroring vmlx's partial-tag handling) so
//  literal `<think>` / `</think>` substrings get dropped even when the
//  model emits them across two adjacent tokens (e.g. `<` + `think>`).
//
//  Only engaged when `modelSupportsThinking == true` — non-thinking
//  models route through `ModelRuntime.streamWithTools`'s untouched
//  passthrough so legitimate `<think>` text in code blocks / technical
//  prose isn't molested.
//

import Foundation

/// Stateful, streaming-safe substring scrubber for `<think>` / `</think>`.
/// Mirrors the buffering pattern of vmlx's `ReasoningParser` but only
/// REMOVES the tags — never toggles a state machine. The actual reasoning
/// split is owned by vmlx; this is a defensive layer that catches
/// orphan-tag leakage from low-bit MoE checkpoints whose token stream
/// confuses the parser's state machine.
struct ThinkTagScrubber {

    private static let openTag = "<think>"
    private static let closeTag = "</think>"
    private static let holdLength = max(openTag.count, closeTag.count) - 1  // 7

    /// Buffered tail that MIGHT be the prefix of an `<think>` or `</think>`
    /// tag we're about to receive in the next chunk. Drained on flush.
    private var pending: String = ""

    /// Feed a chunk text. Returns the scrubbed text safe to forward to
    /// downstream consumers. May return an empty string if the entire
    /// input was buffered as a partial-tag candidate.
    mutating func scrub(_ chunk: String) -> String {
        // Concatenate any buffered tail with the new chunk so split-token
        // tags (`<` + `think>`) get caught at the boundary.
        var working = pending + chunk
        pending = ""

        // Remove every WHOLE occurrence of either tag. Cheap String API
        // — both tags are short literals, no regex compile cost.
        if working.contains(Self.openTag) {
            working = working.replacingOccurrences(of: Self.openTag, with: "")
        }
        if working.contains(Self.closeTag) {
            working = working.replacingOccurrences(of: Self.closeTag, with: "")
        }

        // Hold the tail bytes that COULD be the start of a tag arriving
        // in the next chunk. We only need to hold `holdLength` bytes
        // (one less than the longest tag) because anything shorter than
        // that can't be a full match yet, and anything longer would
        // already have been matched above.
        guard !working.isEmpty else { return "" }

        if let suffix = Self.maybeTagPrefix(of: working) {
            pending = String(suffix)
            return String(working.dropLast(suffix.count))
        }
        return working
    }

    /// Drain any held tail. Called once when the upstream stream
    /// finishes; whatever's left in the buffer is yielded as-is because
    /// no further chunks will arrive to complete a tag.
    mutating func flush() -> String {
        let drained = pending
        pending = ""
        return drained
    }

    /// Returns the longest suffix of `text` that could be a prefix of
    /// either `<think>` or `</think>`. `nil` when no tail bytes need
    /// to be held back. Operates on Swift `Character` (grapheme
    /// clusters) so it never splits a multi-byte emoji that happens
    /// to start with `<` (the `<` ASCII byte isn't a leading byte for
    /// any non-ASCII grapheme, but the grapheme-cluster discipline keeps
    /// us safe for any future tag rename).
    private static func maybeTagPrefix(of text: String) -> Substring? {
        let maxHold = min(holdLength, text.count)
        guard maxHold > 0 else { return nil }
        // Walk longest-first so we hold the largest plausible partial tag.
        for length in stride(from: maxHold, through: 1, by: -1) {
            let suffix = text.suffix(length)
            if Self.openTag.hasPrefix(suffix) || Self.closeTag.hasPrefix(suffix) {
                return suffix
            }
        }
        return nil
    }
}
