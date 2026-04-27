//
//  ThinkTagScrubberTests.swift
//
//  Regression coverage for `ThinkTagScrubber` — the defensive layer that
//  strips orphan `<think>` / `</think>` markers from `Generation.chunk`
//  text on models that have `LocalReasoningCapability.supportsThinking
//  == true`. See `ThinkTagScrubber.swift` header for context.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ThinkTagScrubber orphan-tag defense")
struct ThinkTagScrubberTests {

    // MARK: - Whole-tag occurrences in a single chunk

    @Test("orphan </think> in single chunk is removed")
    func orphanCloseTag() {
        var s = ThinkTagScrubber()
        let out = s.scrub("Here is the answer.</think>")
        #expect(out == "Here is the answer.")
        #expect(s.flush() == "")
    }

    @Test("orphan <think> in single chunk is removed")
    func orphanOpenTag() {
        var s = ThinkTagScrubber()
        let out = s.scrub("<think>Some text after.")
        #expect(out == "Some text after.")
        #expect(s.flush() == "")
    }

    @Test("multiple tags in a single chunk are all removed")
    func multipleTagsInChunk() {
        var s = ThinkTagScrubber()
        let out = s.scrub("<think>x</think>y<think>z</think>w")
        #expect(out == "xyzw")
    }

    @Test("chunk with no tags passes through unchanged")
    func noTagPassthrough() {
        var s = ThinkTagScrubber()
        let out = s.scrub("Hello, world!")
        #expect(out == "Hello, world!")
        #expect(s.flush() == "")
    }

    // MARK: - Split-token tags (the hard case)

    /// MiniMax M2.7 Small JANGTQ at 2-bit can emit a tag across two
    /// adjacent tokens (e.g. token 1 = `<`, token 2 = `think>`). The
    /// scrubber must hold a partial-tag suffix in its buffer until the
    /// next chunk arrives so the full tag gets matched and stripped.
    @Test("split-token <think> across two chunks is stripped")
    func splitOpenTagAcrossChunks() {
        var s = ThinkTagScrubber()
        let first = s.scrub("Some prefix <")
        let second = s.scrub("think>visible")
        let combined = first + second
        #expect(combined == "Some prefix visible")
    }

    @Test("split-token </think> across two chunks is stripped")
    func splitCloseTagAcrossChunks() {
        var s = ThinkTagScrubber()
        let first = s.scrub("Answer<")
        let second = s.scrub("/think>more text")
        let combined = first + second
        #expect(combined == "Answermore text")
    }

    @Test("three-way split <think> is stripped")
    func threeWaySplitOpenTag() {
        var s = ThinkTagScrubber()
        var combined = s.scrub("prefix <th")
        combined += s.scrub("ink")
        combined += s.scrub(">tail")
        #expect(combined == "prefix tail")
    }

    /// If the chunk ends on `<` and no continuation arrives, we MUST
    /// surface that `<` on flush — it was real content (e.g. a math
    /// expression or HTML), not a partial tag.
    @Test("trailing < with no continuation surfaces on flush")
    func trailingPartialFlushed() {
        var s = ThinkTagScrubber()
        let out = s.scrub("a < b means less than: <")
        // `<` is held as potential `<think>` start.
        #expect(out == "a < b means less than: ")
        let tail = s.flush()
        #expect(tail == "<")
    }

    @Test("trailing <th with no continuation surfaces on flush")
    func trailingPartialThFlushed() {
        var s = ThinkTagScrubber()
        let out = s.scrub("ends with <th")
        #expect(out == "ends with ")
        let tail = s.flush()
        #expect(tail == "<th")
    }

    /// Tail `<thinkX` does NOT match `<think>` exactly — but its longest
    /// would-be suffix is `<thinkX`, which is NOT a prefix of `<think>`.
    /// So nothing is held; the whole text passes through.
    @Test("non-matching prefix that contains < is held only at the boundary")
    func nonMatchingPrefixPassesThrough() {
        var s = ThinkTagScrubber()
        let out = s.scrub("ends with <thinkX")
        // `<thinkX` is not a prefix of `<think>` or `</think>` so no
        // suffix is held. Whole text surfaces.
        #expect(out == "ends with <thinkX")
    }

    // MARK: - Real-world scenario from MiniMax M2.7 Small JANGTQ

    /// Exact pattern reported 2026-04-25: model emits visible response
    /// with literal `</think>` interspersed. Scrubber must produce the
    /// clean visible answer.
    @Test("real-world MiniMax leakage pattern")
    func realWorldMiniMaxPattern() {
        var s = ThinkTagScrubber()
        let out = s.scrub("Here's what I can do:\n• Read files</think>\n• Run commands</think>\n• Write task lists")
        #expect(out == "Here's what I can do:\n• Read files\n• Run commands\n• Write task lists")
    }

    @Test("flush yields empty when no buffer pending")
    func flushEmptyWhenClean() {
        var s = ThinkTagScrubber()
        _ = s.scrub("clean text")
        #expect(s.flush() == "")
    }

    /// Calling flush twice in a row is idempotent — the second call
    /// returns empty because the first drained the buffer.
    @Test("flush is idempotent")
    func flushIdempotent() {
        var s = ThinkTagScrubber()
        _ = s.scrub("trailing <th")
        let first = s.flush()
        let second = s.flush()
        #expect(first == "<th")
        #expect(second == "")
    }
}
