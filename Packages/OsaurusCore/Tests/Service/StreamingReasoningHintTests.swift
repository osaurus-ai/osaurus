//
//  StreamingReasoningHintTests.swift
//  osaurusTests
//
//  Round-trip tests for the in-band reasoning sentinel.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("StreamingReasoningHint encode/decode")
struct StreamingReasoningHintTests {

    @Test func roundtrip_preserves_text() {
        let cases = ["hello world", "<think>nested?</think>", "", "multi\nline\ntext"]
        for original in cases {
            let encoded = StreamingReasoningHint.encode(original)
            let decoded = StreamingReasoningHint.decode(encoded)
            #expect(decoded == original)
        }
    }

    @Test func decode_returns_nil_for_non_reasoning_delta() {
        #expect(StreamingReasoningHint.decode("plain text") == nil)
        #expect(StreamingReasoningHint.decode("\u{FFFE}tool:foo") == nil)
        #expect(StreamingReasoningHint.decode("\u{FFFE}stats:1;2.0") == nil)
    }

    @Test func sentinel_filter_recognizes_reasoning_hint() {
        // The shared `\u{FFFE}` first char ensures `StreamingToolHint.isSentinel`
        // catches reasoning hints too — HTTP NDJSON skips them via that test.
        let encoded = StreamingReasoningHint.encode("anything")
        #expect(StreamingToolHint.isSentinel(encoded))
    }
}
