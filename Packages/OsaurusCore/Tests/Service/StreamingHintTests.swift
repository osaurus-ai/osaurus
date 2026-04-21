//
//  StreamingHintTests.swift
//  osaurusTests
//
//  Regression tests for the streaming sentinel encoders/decoders
//  (StreamingToolHint + StreamingStatsHint). The stats sentinel
//  historically leaked into visible tool-call output (issue #856)
//  because consumers handled the tool sentinel but not the stats
//  sentinel — these tests lock in the round-trip + decoder contract
//  so a future refactor doesn't re-break it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct StreamingHintTests {

    // MARK: - StreamingStatsHint

    @Test func statsHint_encode_prefixedWithFFFESentinel() {
        let encoded = StreamingStatsHint.encode(tokenCount: 24, tokensPerSecond: 85.4607)
        #expect(encoded.hasPrefix("\u{FFFE}stats:"))
        #expect(encoded.contains("24;"))
        #expect(encoded.contains("85.4607"))
    }

    @Test func statsHint_decode_recoversValues() {
        let encoded = StreamingStatsHint.encode(tokenCount: 128, tokensPerSecond: 99.4321)
        let decoded = StreamingStatsHint.decode(encoded)
        #expect(decoded?.tokenCount == 128)
        #expect(abs((decoded?.tokensPerSecond ?? 0.0) - 99.4321) < 0.0001)
    }

    @Test func statsHint_decode_rejectsNonSentinelDelta() {
        // Plain text must not be mistaken for a sentinel.
        #expect(StreamingStatsHint.decode("Hello world") == nil)
        #expect(StreamingStatsHint.decode("") == nil)
        #expect(StreamingStatsHint.decode("stats:10;20.0") == nil)
    }

    @Test func statsHint_decode_rejectsMalformedPayload() {
        // Sentinel present but payload malformed — decode should return nil
        // rather than surface a partial value.
        #expect(StreamingStatsHint.decode("\u{FFFE}stats:") == nil)
        #expect(StreamingStatsHint.decode("\u{FFFE}stats:notanint;99.0") == nil)
        #expect(StreamingStatsHint.decode("\u{FFFE}stats:10") == nil)
    }

    @Test func statsHint_decode_isOrthogonalToToolHint() {
        // Stats decoder must not match tool-hint sentinels and vice versa.
        let toolEncoded = StreamingToolHint.encode("read_file")
        #expect(StreamingStatsHint.decode(toolEncoded) == nil)

        let statsEncoded = StreamingStatsHint.encode(tokenCount: 5, tokensPerSecond: 10.0)
        #expect(StreamingToolHint.decode(statsEncoded) == nil)
        #expect(StreamingToolHint.decodeArgs(statsEncoded) == nil)
    }

    // Issue #856 regression: the sentinel must NEVER appear in the
    // visible text of an assistant message. ChatView filters it out
    // before render. Here we lock in the contract that the decoder
    // will correctly identify the sentinel so filtering is possible,
    // and that the encoded form always carries the U+FFFE prefix that
    // consumers check for.
    @Test func statsHint_encodedForm_alwaysCarriesNoncharacterPrefix() {
        let samples: [(Int, Double)] = [
            (0, 0.0),
            (1, 1.0),
            (1_000_000, 999.9999),
            (42, 3.14159),
        ]
        for (count, tps) in samples {
            let encoded = StreamingStatsHint.encode(tokenCount: count, tokensPerSecond: tps)
            #expect(
                encoded.unicodeScalars.first == Unicode.Scalar(0xFFFE),
                "encoded stats hint must start with U+FFFE noncharacter (got: \(encoded.debugDescription))"
            )
        }
    }
}
