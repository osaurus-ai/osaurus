//
//  StreamingStatsHintMTPTests.swift
//  osaurusTests
//
//  Round-trip tests for the native-MTP evidence flag on the streaming
//  stats hint (osaurus#2526). The MTP fields are how an eval report PROVES
//  which decode path a step ran on, so encode→decode must be lossless —
//  including a fallback reason containing `=` and `,`, which would corrupt
//  the comma-separated flag list without percent-encoding.
//

import Foundation
import Testing

@testable import OsaurusCore

struct StreamingStatsHintMTPTests {

    private let summary = MTPStatsSummary(
        depth: 2,
        activeDepth: 1,
        verifyCalls: 146,
        acceptedDraftTokens: 151,
        bonusTokens: 68,
        rejectedTokens: 78,
        arFallbackTokens: 407,
        adaptiveDownshifts: 3,
        adaptiveFallbackReason: "adaptive_accept_ratio=0.33_depth=1"
    )

    @Test func mtpFlagRoundTrips() {
        let wire = StreamingStatsHint.encode(
            tokenCount: 704,
            tokensPerSecond: 33.5,
            unclosedReasoning: false,
            stopReason: "stop",
            prefillTokensPerSecond: 14833.2,
            mtp: summary
        )
        let decoded = StreamingStatsHint.decode(wire)
        #expect(decoded != nil)
        #expect(decoded?.tokenCount == 704)
        #expect(decoded?.stopReason == "stop")
        #expect(decoded?.mtp == summary)
    }

    @Test func mtpFlagAbsentDecodesNil() {
        let wire = StreamingStatsHint.encode(tokenCount: 10, tokensPerSecond: 50)
        let decoded = StreamingStatsHint.decode(wire)
        #expect(decoded != nil)
        #expect(decoded?.mtp == nil)
    }

    /// The reason is optional — a healthy run has none.
    @Test func mtpFlagWithoutReasonRoundTrips() {
        let healthy = MTPStatsSummary(
            depth: 2, activeDepth: 2, verifyCalls: 12,
            acceptedDraftTokens: 12, bonusTokens: 12, rejectedTokens: 0,
            arFallbackTokens: 0, adaptiveDownshifts: 0,
            adaptiveFallbackReason: nil)
        let wire = StreamingStatsHint.encode(
            tokenCount: 25, tokensPerSecond: 40, mtp: healthy)
        #expect(StreamingStatsHint.decode(wire)?.mtp == healthy)
    }

    /// Older decoders split flags on commas; the encoded reason must not
    /// introduce one, and the other flags must survive alongside mtp.
    @Test func mtpFlagCoexistsWithLegacyFlags() {
        let wire = StreamingStatsHint.encode(
            tokenCount: 5,
            tokensPerSecond: 1,
            unclosedReasoning: true,
            stopReason: "length",
            prefillTokensPerSecond: 100,
            mtp: summary
        )
        let decoded = StreamingStatsHint.decode(wire)
        #expect(decoded?.unclosedReasoning == true)
        #expect(decoded?.stopReason == "length")
        #expect(decoded?.prefillTokensPerSecond == 100)
        #expect(decoded?.mtp?.adaptiveFallbackReason == "adaptive_accept_ratio=0.33_depth=1")
    }
}
