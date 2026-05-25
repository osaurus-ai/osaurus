//
//  StreamingUnscrubber.swift
//  osaurus / PrivacyFilter
//
//  Token replacer for SSE response bodies. The provider stream yields
//  text deltas that may carry our `[CATEGORY_N]` placeholders. We pass
//  every chunk through `push(_:)`, which returns only the prefix safe
//  to emit; the rest stays buffered until we either confirm a complete
//  token, prove the buffered tail can't become one, or `flush()` runs
//  at stream close.
//
//  Buffering rules:
//    1. After every push, replace every COMPLETE `[CATEGORY_N]` token
//       found in the buffer with its mapped original (unknown tokens
//       are logged + left in place — see "Hallucinated placeholder
//       policy" below).
//    2. Find the rightmost `[` with no `]` after it. Everything strictly
//       before it is safe to emit; everything from `[` onward stays
//       buffered.
//    3. If the buffered tail exceeds `maxTokenLength + safetyMargin`,
//       it cannot become a valid placeholder anymore — emit it.
//
//  Step 3 is what keeps the buffer bounded even when the model emits
//  prose containing stray `[`s.
//
//  Hallucinated placeholder policy
//  -------------------------------
//  Some models invent placeholder tokens we never minted — e.g. the
//  prompt asks "how many people did I mention?" and the model parrots
//  back `[PERSON_7]` even though our map only has `[PERSON_1]`. The
//  ideal answer is model-specific (Claude almost never does this;
//  small local models do it constantly) and the choice involves UX
//  trade-offs:
//
//    * **Strip with footnote** would silently delete content the model
//      generated. The user can't tell why a sentence is suddenly
//      missing a clause.
//    * **Dim / italicize** requires the chat layer to round-trip an
//      "this is a hallucinated placeholder" attribute and we'd have
//      to enumerate them after streaming completes — costly on the
//      hot path.
//    * **Keep as-is** preserves the model's literal output and lets
//      the user notice the bracketed token themselves. They'll click
//      it (if rendered as code by markdown) or ignore it.
//
//  We pick **keep as-is** because:
//    1. It's the least-surprising behaviour for a translator-style
//       component: the unscrubber's job is to restore real
//       placeholders, not to censor the model.
//    2. The frequency in practice is low — assistant text that
//       references a known entity by index almost always resolves
//       correctly because the model is mimicking text that already
//       contained the right placeholder.
//    3. Stripping would interact badly with code samples and
//       markdown links (`[link]`) — a strip rule keyed on
//       `looksLikePlaceholder` would risk false positives on
//       `[CODE_BLOCK]`-style language tokens that some models
//       emit verbatim.
//
//  Diagnostics: `unknownPlaceholderCount` exposes how many unknown
//  tokens slipped through across the lifetime of one stream so the
//  chat layer (or Insights) can surface a "model emitted N tokens
//  we couldn't restore" hint without re-scanning the rendered body.
//

import Foundation

public final class StreamingUnscrubber {
    /// Extra bytes we allow on top of the longest known token before
    /// flushing the buffered tail. Covers single-character token-name
    /// drift between map snapshots and stray brackets in prose.
    private static let safetyMargin: Int = 16

    private let map: RedactionMap

    /// Snapshot of `map.maxTokenLength` captured at construction time.
    /// Re-reading every push would require an `await` per chunk; the
    /// outbound side never shrinks the map mid-conversation so the
    /// snapshot stays correct for the lifetime of one response.
    private let maxTokenLength: Int

    private var buffer: String = ""

    /// Character offset (from `buffer.startIndex`) up to which the
    /// buffer has already been scanned for complete placeholder
    /// tokens. The next `replaceCompletedTokens` pass only re-scans
    /// from `cleanOffset - lookback` onward (lookback covers a token
    /// that started before the cursor and was completed by the new
    /// chunk). This collapses the per-push cost from `O(buffer)` to
    /// `O(delta + lookback)` even when the model produces heavy
    /// markdown traffic that keeps the buffer warm.
    private var cleanOffset: Int = 0

    /// Count of `[CATEGORY_N]`-shaped tokens that passed
    /// `looksLikePlaceholder` but were absent from the
    /// `RedactionMap`. Exposed read-only so the chat layer can
    /// surface a "model produced unknown placeholders" hint without
    /// re-scanning the rendered text. Monotonic across the lifetime
    /// of one `StreamingUnscrubber` (one stream / one response).
    /// See the file header for the policy choice (keep as-is).
    public private(set) var unknownPlaceholderCount: Int = 0

    public init(map: RedactionMap, maxTokenLength: Int) {
        self.map = map
        self.maxTokenLength = maxTokenLength
    }

    /// Convenience initializer that reads `maxTokenLength` from the
    /// map. Use the explicit-length init when you want to avoid the
    /// awaitable property read at the per-stream hot path.
    public static func make(for map: RedactionMap) async -> StreamingUnscrubber {
        let max = await map.maxTokenLength
        return StreamingUnscrubber(map: map, maxTokenLength: max)
    }

    /// Append a streamed chunk and return the prefix safe to emit.
    /// The remainder stays buffered until the next push or `flush`.
    public func push(_ chunk: String) async -> String {
        buffer.append(chunk)
        await replaceCompletedTokens()
        return drainSafePrefix()
    }

    /// Drain whatever is left in the buffer with one final replacement
    /// pass. Always returns the empty string after — `flush` is
    /// idempotent.
    public func flush() async -> String {
        await replaceCompletedTokens()
        let remaining = buffer
        buffer = ""
        cleanOffset = 0
        return remaining
    }

    // MARK: - Internals

    /// Walk the buffer scanning for complete `[CATEGORY_N]` tokens and
    /// rewrite each in place with its mapped original. Resumes from
    /// `cleanOffset - lookback` so we don't re-walk text that was
    /// already verified clean on a prior push.
    private func replaceCompletedTokens() async {
        let lookback = maxTokenLength + Self.safetyMargin
        let bufferCount = buffer.count
        let startOffset = max(0, min(cleanOffset, bufferCount) - lookback)
        var search = buffer.index(buffer.startIndex, offsetBy: startOffset)
        while search < buffer.endIndex {
            guard let openIdx = buffer.range(of: "[", range: search ..< buffer.endIndex) else {
                break
            }
            guard let closeIdx = buffer.range(of: "]", range: openIdx.upperBound ..< buffer.endIndex) else {
                // No closing bracket yet — leave for the next chunk.
                // Don't advance `cleanOffset` past this point; the
                // tail belongs to a still-incomplete token.
                cleanOffset = buffer.distance(from: buffer.startIndex, to: openIdx.lowerBound)
                return
            }
            let tokenRange = openIdx.lowerBound ..< closeIdx.upperBound
            let token = String(buffer[tokenRange])
            if Self.looksLikePlaceholder(token) {
                if let original = await map.resolve(token: token) {
                    buffer.replaceSubrange(tokenRange, with: original)
                    // Advance past the substituted original. Compute
                    // a fresh index — replaceSubrange invalidates
                    // every index past the replacement point.
                    search =
                        buffer.index(openIdx.lowerBound, offsetBy: original.count, limitedBy: buffer.endIndex)
                        ?? buffer.endIndex
                    continue
                }
                // Hallucinated / unknown placeholder. Policy: leave
                // the literal token in the stream so the user can
                // see what the model emitted (see file header for
                // rationale). Bump the counter so callers can react
                // out-of-band without re-parsing the rendered text.
                unknownPlaceholderCount &+= 1
                debugLog("[PrivacyFilter] Unknown placeholder in stream: \(token)")
            }
            // Either not a placeholder shape or unknown — skip past it.
            search = closeIdx.upperBound
        }
        // Reached end of buffer with no pending open token: every
        // byte has been considered. Next push only needs to look at
        // text that arrives after this point (plus the lookback
        // overlap for straddling tokens).
        cleanOffset = buffer.count
    }

    /// Find the rightmost `[` with no closing `]` after it. Emit
    /// everything strictly before it; keep the rest buffered. If the
    /// tail is already too long to ever match a placeholder, emit it.
    private func drainSafePrefix() -> String {
        guard let lastOpen = buffer.lastIndex(of: "[") else {
            // No open bracket — every byte is safe.
            let out = buffer
            buffer = ""
            cleanOffset = 0
            return out
        }
        // Is there a `]` after this `[`? Then there's no pending
        // incomplete token; flush everything.
        if buffer.range(of: "]", range: lastOpen ..< buffer.endIndex) != nil {
            let out = buffer
            buffer = ""
            cleanOffset = 0
            return out
        }

        // Pending tail = buffer[lastOpen..<endIndex].
        let tailLength = buffer.distance(from: lastOpen, to: buffer.endIndex)
        let limit = maxTokenLength + Self.safetyMargin
        if tailLength > limit {
            // Can't possibly be a placeholder anymore. Flush.
            let out = buffer
            buffer = ""
            cleanOffset = 0
            return out
        }

        // Emit prefix, keep tail. Shift `cleanOffset` left by the
        // dropped prefix length so it still points at the same byte
        // in the remaining tail.
        let dropped = buffer.distance(from: buffer.startIndex, to: lastOpen)
        let prefix = String(buffer[..<lastOpen])
        buffer = String(buffer[lastOpen...])
        cleanOffset = max(0, cleanOffset - dropped)
        return prefix
    }

    /// Cheap shape check: starts with `[`, ends with `]`, contains a
    /// single underscore, and the part after `_` parses as an integer.
    /// Filters out other bracketed text (e.g. markdown links) so we
    /// don't pay for a map lookup per such token.
    private static func looksLikePlaceholder(_ token: String) -> Bool {
        guard token.count >= 5,
            token.first == "[",
            token.last == "]"
        else { return false }
        // Strip the brackets.
        let inner = token.dropFirst().dropLast()
        guard let underscore = inner.firstIndex(of: "_") else { return false }
        let prefix = inner[..<underscore]
        let suffix = inner[inner.index(after: underscore)...]
        guard !prefix.isEmpty, !suffix.isEmpty else { return false }
        // Prefix should be all uppercase ASCII letters.
        for ch in prefix {
            guard ch.isASCII, ch.isUppercase else { return false }
        }
        // Suffix should be all decimal digits.
        for ch in suffix {
            guard ch.isASCII, ch.isNumber else { return false }
        }
        return true
    }
}
