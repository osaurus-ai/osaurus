//
//  StreamingBillingHintTests.swift
//  osaurusTests
//
//  Round-trip tests for the in-band router billing sentinel. The hint carries
//  the router's per-turn charge (cost, tokens, status) through the delta stream
//  so the chat layer can keep a billed-but-empty turn and write the ledger row.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("StreamingBillingHint encode/decode")
struct StreamingBillingHintTests {

    @Test func roundtrip_preservesAllFields() {
        let summary = RouterBillingSummary(
            requestId: "run-abc:1",
            costMicro: "1234",
            status: "completed",
            tokenSource: "provider",
            inputTokens: 11,
            outputTokens: 3
        )

        let encoded = StreamingBillingHint.encode(summary)
        let decoded = StreamingBillingHint.decode(encoded)

        #expect(decoded == summary)
    }

    @Test func encoded_isSentinel_soHTTPLayerSkipsIt() {
        // Shares the `\u{FFFE}` first char with the other hints so the NDJSON
        // sentinel filter keeps it out of visible output and token counting.
        let encoded = StreamingBillingHint.encode(
            RouterBillingSummary(
                costMicro: "0",
                status: "completed",
                tokenSource: "estimated",
                inputTokens: 0,
                outputTokens: 0
            )
        )
        #expect(StreamingToolHint.isSentinel(encoded))
    }

    @Test func decode_returnsNil_forNonBillingDeltas() {
        #expect(StreamingBillingHint.decode("plain text") == nil)
        #expect(StreamingBillingHint.decode("\u{FFFE}tool:foo") == nil)
        #expect(StreamingBillingHint.decode(StreamingReasoningHint.encode("thinking")) == nil)
    }
}
