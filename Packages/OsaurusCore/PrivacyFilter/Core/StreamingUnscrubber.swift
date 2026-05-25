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
//       are logged + left in place).
//    2. Find the rightmost `[` with no `]` after it. Everything strictly
//       before it is safe to emit; everything from `[` onward stays
//       buffered.
//    3. If the buffered tail exceeds `maxTokenLength + safetyMargin`,
//       it cannot become a valid placeholder anymore — emit it.
//
//  Step 3 is what keeps the buffer bounded even when the model emits
//  prose containing stray `[`s.
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
        return remaining
    }

    // MARK: - Internals

    /// Walk the buffer scanning for complete `[CATEGORY_N]` tokens and
    /// rewrite each in place with its mapped original.
    private func replaceCompletedTokens() async {
        var search = buffer.startIndex
        while search < buffer.endIndex {
            guard let openIdx = buffer.range(of: "[", range: search ..< buffer.endIndex) else {
                break
            }
            guard let closeIdx = buffer.range(of: "]", range: openIdx.upperBound ..< buffer.endIndex) else {
                // No closing bracket yet — leave for the next chunk.
                break
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
                debugLog("[PrivacyFilter] Unknown placeholder in stream: \(token)")
            }
            // Either not a placeholder shape or unknown — skip past it.
            search = closeIdx.upperBound
        }
    }

    /// Find the rightmost `[` with no closing `]` after it. Emit
    /// everything strictly before it; keep the rest buffered. If the
    /// tail is already too long to ever match a placeholder, emit it.
    private func drainSafePrefix() -> String {
        guard let lastOpen = buffer.lastIndex(of: "[") else {
            // No open bracket — every byte is safe.
            let out = buffer
            buffer = ""
            return out
        }
        // Is there a `]` after this `[`? Then there's no pending
        // incomplete token; flush everything.
        if buffer.range(of: "]", range: lastOpen ..< buffer.endIndex) != nil {
            let out = buffer
            buffer = ""
            return out
        }

        // Pending tail = buffer[lastOpen..<endIndex].
        let tailLength = buffer.distance(from: lastOpen, to: buffer.endIndex)
        let limit = maxTokenLength + Self.safetyMargin
        if tailLength > limit {
            // Can't possibly be a placeholder anymore. Flush.
            let out = buffer
            buffer = ""
            return out
        }

        // Emit prefix, keep tail.
        let prefix = String(buffer[..<lastOpen])
        buffer = String(buffer[lastOpen...])
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
