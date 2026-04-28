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

    // MARK: - StreamingStatsHint — unclosedReasoning flag

    @Test func statsHint_encode_omitsFlagsWhenUnclosedFalse() {
        // Default-false: encoded payload must NOT contain the trailing
        // `;unclosed` field — keeps the wire compact and matches the legacy
        // 2-field form so the bumped pin doesn't change wire bytes for
        // healthy generations.
        let encoded = StreamingStatsHint.encode(
            tokenCount: 50, tokensPerSecond: 12.5)
        #expect(!encoded.contains("unclosed"))
    }

    @Test func statsHint_encode_includesFlagWhenUnclosedTrue() {
        let encoded = StreamingStatsHint.encode(
            tokenCount: 1024, tokensPerSecond: 12.27, unclosedReasoning: true)
        #expect(encoded.hasPrefix("\u{FFFE}stats:"))
        #expect(encoded.hasSuffix(";unclosed"))
    }

    @Test func statsHint_decode_recoversUnclosedFlagWhenPresent() {
        let encoded = StreamingStatsHint.encode(
            tokenCount: 424, tokensPerSecond: 7.8, unclosedReasoning: true)
        let decoded = StreamingStatsHint.decode(encoded)
        #expect(decoded?.tokenCount == 424)
        #expect(abs((decoded?.tokensPerSecond ?? 0) - 7.8) < 0.0001)
        #expect(decoded?.unclosedReasoning == true)
    }

    @Test func statsHint_decode_defaultsUnclosedFalseOnLegacyTwoFieldPayload() {
        // Forward-compat: a payload encoded by the legacy 2-field form
        // (no flags suffix) must still decode cleanly with unclosed=false.
        // This guards against pin-bump asymmetry where a streaming
        // session straddles the upgrade and still works.
        let legacy = "\u{FFFE}stats:128;99.4321"
        let decoded = StreamingStatsHint.decode(legacy)
        #expect(decoded?.tokenCount == 128)
        #expect(decoded?.unclosedReasoning == false)
    }

    @Test func statsHint_decode_ignoresUnknownFlags() {
        // Forward-compat for future flags — an unknown flag in the third
        // field must not crash the decoder, and unclosed stays false.
        let payload = "\u{FFFE}stats:10;5.0;futureflag,anotherflag"
        let decoded = StreamingStatsHint.decode(payload)
        #expect(decoded?.tokenCount == 10)
        #expect(decoded?.unclosedReasoning == false)
    }

    @Test func statsHint_decode_recoversUnclosedFlagAlongsideUnknownFlags() {
        // `unclosed` mixed with future flags in a comma list — still detected.
        let payload = "\u{FFFE}stats:10;5.0;futureflag,unclosed"
        let decoded = StreamingStatsHint.decode(payload)
        #expect(decoded?.unclosedReasoning == true)
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
