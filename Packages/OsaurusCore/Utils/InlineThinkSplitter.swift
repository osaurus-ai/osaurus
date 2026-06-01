//
//  InlineThinkSplitter.swift
//  osaurus
//
//  Streaming splitter that separates inline `<think>...</think>` reasoning from
//  visible content when a provider interleaves both on a single text channel.
//

import Foundation

/// Splits a streamed text channel that interleaves reasoning and visible
/// content inside `<think>...</think>` tags (e.g. MiniMax M-series over the
/// OpenAI-compatible API, which leaves `reasoning_content` empty and inlines
/// the think block in `content`).
///
/// Feed each streamed delta to `process(_:)`; it returns ordered `Segment`s
/// tagged `.reasoning` or `.content`. Tags may straddle delta boundaries, so
/// the splitter holds back a short tail that could be the start of a tag — a
/// partial `<thi` / `</thin` is never emitted as visible text. Call `flush()`
/// once at end-of-stream to drain any held-back tail.
///
/// The type is provider-agnostic: open/close tokens are configurable so it can
/// be reused for other tag pairs.
struct InlineThinkSplitter {
    enum Segment: Equatable {
        case reasoning(String)
        case content(String)
    }

    private let openToken: String
    private let closeToken: String
    private var insideThink = false
    /// Buffered tail that might be the prefix of a tag straddling two deltas.
    private var pending = ""

    init(openToken: String = "<think>", closeToken: String = "</think>") {
        self.openToken = openToken
        self.closeToken = closeToken
    }

    /// Consume one streamed delta, returning ordered reasoning/content segments.
    mutating func process(_ delta: String) -> [Segment] {
        guard !delta.isEmpty else { return [] }

        var work = pending + delta
        pending = ""
        var segments: [Segment] = []

        while !work.isEmpty {
            let token = insideThink ? closeToken : openToken
            if let range = work.range(of: token) {
                let before = String(work[work.startIndex ..< range.lowerBound])
                if !before.isEmpty {
                    segments.append(insideThink ? .reasoning(before) : .content(before))
                }
                insideThink.toggle()
                work = String(work[range.upperBound...])
            } else {
                // No complete token: emit everything except a suffix that could
                // be the start of the token we're still hunting for.
                let keep = Self.partialTokenSuffixLength(of: work, token: token)
                let splitIndex = work.index(work.endIndex, offsetBy: -keep)
                let emit = String(work[work.startIndex ..< splitIndex])
                if !emit.isEmpty {
                    segments.append(insideThink ? .reasoning(emit) : .content(emit))
                }
                pending = String(work[splitIndex...])
                work = ""
            }
        }

        return segments
    }

    /// Drain any held-back tail at end-of-stream. A leftover tail was a partial
    /// tag that never completed, so it is literal text on the current channel.
    mutating func flush() -> [Segment] {
        guard !pending.isEmpty else { return [] }
        let leftover = pending
        pending = ""
        return [insideThink ? .reasoning(leftover) : .content(leftover)]
    }

    /// Largest `k` in `1..<token.count` such that the last `k` characters of
    /// `text` equal the first `k` characters of `token`. Returns 0 when no
    /// suffix of `text` is a proper prefix of `token`.
    private static func partialTokenSuffixLength(of text: String, token: String) -> Int {
        let tokenChars = Array(token)
        let textChars = Array(text)
        let maxK = min(textChars.count, tokenChars.count - 1)
        guard maxK > 0 else { return 0 }

        var k = maxK
        while k > 0 {
            var matches = true
            for i in 0 ..< k where textChars[textChars.count - k + i] != tokenChars[i] {
                matches = false
                break
            }
            if matches { return k }
            k -= 1
        }
        return 0
    }
}
