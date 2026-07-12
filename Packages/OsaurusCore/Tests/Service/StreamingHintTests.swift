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

    @Test func prefillProgressHint_roundTripsJSONPayload() {
        let progress = PrefillProgressState(
            stage: .prefill,
            completedUnitCount: 384,
            totalUnitCount: 1024,
            detail: "model.prepare"
        )
        let encoded = StreamingPrefillProgressHint.encode(progress)
        #expect(encoded.hasPrefix("\u{FFFE}prefill:"))
        #expect(StreamingPrefillProgressHint.decode(encoded) == progress)
    }

    @Test func prefillProgressHint_isOrthogonalToOtherSentinels() {
        let progress = PrefillProgressState(
            stage: .cacheRestore,
            completedUnitCount: 512,
            totalUnitCount: 1024,
            detail: nil
        )
        let encoded = StreamingPrefillProgressHint.encode(progress)
        #expect(StreamingToolHint.isSentinel(encoded))
        #expect(StreamingStatsHint.decode(encoded) == nil)
        #expect(StreamingReasoningHint.decode(encoded) == nil)
        #expect(StreamingPrefillProgressHint.decode("plain text") == nil)
    }

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
            tokenCount: 50,
            tokensPerSecond: 12.5
        )
        #expect(!encoded.contains("unclosed"))
    }

    @Test func statsHint_encode_includesFlagWhenUnclosedTrue() {
        let encoded = StreamingStatsHint.encode(
            tokenCount: 1024,
            tokensPerSecond: 12.27,
            unclosedReasoning: true
        )
        #expect(encoded.hasPrefix("\u{FFFE}stats:"))
        #expect(encoded.hasSuffix(";unclosed"))
    }

    @Test func statsHint_decode_recoversUnclosedFlagWhenPresent() {
        let encoded = StreamingStatsHint.encode(
            tokenCount: 424,
            tokensPerSecond: 7.8,
            unclosedReasoning: true
        )
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

    @Test func statsHint_encode_includesStopReasonWhenPresent() {
        let encoded = StreamingStatsHint.encode(
            tokenCount: 300,
            tokensPerSecond: 5.25,
            stopReason: "length"
        )
        #expect(encoded.hasSuffix(";stop=length"))
    }

    @Test func statsHint_decode_recoversStopReasonAlongsideUnclosedFlag() {
        let payload = "\u{FFFE}stats:10;5.0;futureflag,unclosed,stop=length"
        let decoded = StreamingStatsHint.decode(payload)
        #expect(decoded?.unclosedReasoning == true)
        #expect(decoded?.stopReason == "length")
    }

    @Test func statsHint_roundTrips_prefillTokensPerSecond() {
        let encoded = StreamingStatsHint.encode(
            tokenCount: 128,
            tokensPerSecond: 60.0,
            prefillTokensPerSecond: 412.5
        )
        #expect(encoded.contains("prefill=412.5"))
        let decoded = StreamingStatsHint.decode(encoded)
        #expect(decoded?.tokenCount == 128)
        #expect(abs((decoded?.tokensPerSecond ?? 0) - 60.0) < 0.0001)
        #expect(abs((decoded?.prefillTokensPerSecond ?? 0) - 412.5) < 0.01)
    }

    @Test func statsHint_omitsPrefillFlagWhenAbsentOrNonPositive() {
        // nil and 0/negative prefill keep the compact 2-field wire so the
        // healthy bytes are unchanged and old decoders see no new flag.
        let none = StreamingStatsHint.encode(tokenCount: 5, tokensPerSecond: 10.0)
        #expect(!none.contains("prefill="))
        #expect(StreamingStatsHint.decode(none)?.prefillTokensPerSecond == nil)
        let zero = StreamingStatsHint.encode(
            tokenCount: 5,
            tokensPerSecond: 10.0,
            prefillTokensPerSecond: 0
        )
        #expect(!zero.contains("prefill="))
    }

    @Test func statsHint_encode_normalizesNonFiniteTokensPerSecondToZero() {
        // A zero-token cancelled stream (e.g. the engine's
        // engine_iterator_gate path) carries
        // GenerateCompletionInfo.tokensPerSecond = 0/0 = NaN. "%.4f" would
        // render the bare token "nan" on the wire, which decodes back to a
        // non-finite Double and previously reached the OpenAI `usage`
        // chunk as invalid JSON. Encode must normalize to 0 — the same
        // value a genuine zero-rate step (0 tokens over nonzero time)
        // reports — and never emit "nan"/"inf".
        for nonFinite in [Double.nan, .infinity, -.infinity] {
            let encoded = StreamingStatsHint.encode(
                tokenCount: 0,
                tokensPerSecond: nonFinite,
                stopReason: "cancelled",
                engine: "solo_mtp",
                mtpFallbackReason: "engine_iterator_gate"
            )
            #expect(!encoded.contains("nan"))
            #expect(!encoded.contains("inf"))
            let decoded = StreamingStatsHint.decode(encoded)
            #expect(decoded?.tokenCount == 0)
            #expect(decoded?.tokensPerSecond == 0)
            #expect(decoded?.stopReason == "cancelled")
            #expect(decoded?.engine == "solo_mtp")
            #expect(decoded?.mtpFallbackReason == "engine_iterator_gate")
        }
        // Non-finite prefill tps rides the existing isFinite && > 0 guard:
        // the optional flag is omitted entirely.
        let badPrefill = StreamingStatsHint.encode(
            tokenCount: 0,
            tokensPerSecond: .nan,
            prefillTokensPerSecond: .infinity
        )
        #expect(!badPrefill.contains("prefill="))
        #expect(StreamingStatsHint.decode(badPrefill)?.prefillTokensPerSecond == nil)
    }

    @Test func statsHint_decode_legacyNonFiniteWire_parsesToNonFinite() {
        // A pre-fix producer (or the live-observed chunk) can still put the
        // bare token "nan" on the in-band wire; Double("nan") parses, so
        // decode surfaces a NaN — the usage serializers (Usage.encode /
        // chatCompletionResponseJSONObject) are the boundary that must
        // then omit the key. Pin the parse so that boundary keeps being
        // exercised.
        let decoded = StreamingStatsHint.decode("\u{FFFE}stats:0;nan;stop=cancelled")
        #expect(decoded?.tokenCount == 0)
        #expect(decoded?.tokensPerSecond.isNaN == true)
        #expect(decoded?.stopReason == "cancelled")
    }

    @Test func statsHint_decode_recoversPrefillAlongsideOtherFlags() {
        let payload = "\u{FFFE}stats:10;5.0;unclosed,stop=length,prefill=300.25"
        let decoded = StreamingStatsHint.decode(payload)
        #expect(decoded?.unclosedReasoning == true)
        #expect(decoded?.stopReason == "length")
        #expect(abs((decoded?.prefillTokensPerSecond ?? 0) - 300.25) < 0.01)
    }

    @Test func statsHint_legacyWire_hasNilPrefill() {
        // Wire written by a pre-prefill encoder must decode with nil
        // prefill (forward/backward-compat across an upgrade straddle).
        let decoded = StreamingStatsHint.decode("\u{FFFE}stats:128;99.4321")
        #expect(decoded?.tokenCount == 128)
        #expect(decoded?.prefillTokensPerSecond == nil)
    }

    // MARK: - StreamingStatsHint — engine attribution flags

    @Test func statsHint_roundTrips_engineAndMTPOffFlags() {
        let encoded = StreamingStatsHint.encode(
            tokenCount: 64,
            tokensPerSecond: 42.0,
            engine: "solo_ar",
            mtpFallbackReason: "explicit_sampling"
        )
        #expect(encoded.contains("engine=solo_ar"))
        #expect(encoded.contains("mtp_off=explicit_sampling"))
        let decoded = StreamingStatsHint.decode(encoded)
        #expect(decoded?.tokenCount == 64)
        #expect(decoded?.engine == "solo_ar")
        #expect(decoded?.mtpFallbackReason == "explicit_sampling")
    }

    @Test func statsHint_roundTrips_engineSamplingGateFallbackReason() {
        // The engine-side veto value ("engine_sampling_gate": strategy
        // submitted but vmlx's own eligibility gate rejected MTP) must
        // ride the wire verbatim like the three pre-submit reasons.
        let encoded = StreamingStatsHint.encode(
            tokenCount: 8,
            tokensPerSecond: 21.0,
            engine: "solo_ar",
            mtpFallbackReason: "engine_sampling_gate"
        )
        #expect(encoded.contains("mtp_off=engine_sampling_gate"))
        let decoded = StreamingStatsHint.decode(encoded)
        #expect(decoded?.engine == "solo_ar")
        #expect(decoded?.mtpFallbackReason == "engine_sampling_gate")
    }

    @Test func statsHint_roundTrips_iteratorGateAndDiffusionFlagValues() {
        // engine_iterator_gate pairs with engine=solo_mtp (the submitted
        // native-MTP branch the engine takes and then CANCELS — see the
        // `EngineAttribution.engineFlag` taxonomy), and block-diffusion
        // steps carry the solo_diffusion path value.
        let iteratorGated = StreamingStatsHint.encode(
            tokenCount: 0,
            tokensPerSecond: 0.0,
            stopReason: "cancelled",
            engine: "solo_mtp",
            mtpFallbackReason: "engine_iterator_gate"
        )
        #expect(iteratorGated.contains("engine=solo_mtp"))
        #expect(iteratorGated.contains("mtp_off=engine_iterator_gate"))
        let decodedIteratorGated = StreamingStatsHint.decode(iteratorGated)
        #expect(decodedIteratorGated?.engine == "solo_mtp")
        #expect(decodedIteratorGated?.mtpFallbackReason == "engine_iterator_gate")
        #expect(decodedIteratorGated?.stopReason == "cancelled")

        let diffusion = StreamingStatsHint.encode(
            tokenCount: 96,
            tokensPerSecond: 74.0,
            engine: "solo_diffusion"
        )
        #expect(diffusion.contains("engine=solo_diffusion"))
        let decodedDiffusion = StreamingStatsHint.decode(diffusion)
        #expect(decodedDiffusion?.engine == "solo_diffusion")
        #expect(decodedDiffusion?.mtpFallbackReason == nil)
    }

    @Test func statsHint_omitsEngineFlagsWhenAbsent() {
        // nil/blank attribution keeps the compact wire byte-identical to
        // the pre-attribution encoder, so remote-provider hints and old
        // decoders see no new flag.
        let none = StreamingStatsHint.encode(tokenCount: 5, tokensPerSecond: 10.0)
        #expect(!none.contains("engine="))
        #expect(!none.contains("mtp_off="))
        #expect(StreamingStatsHint.decode(none)?.engine == nil)
        #expect(StreamingStatsHint.decode(none)?.mtpFallbackReason == nil)

        let blank = StreamingStatsHint.encode(
            tokenCount: 5,
            tokensPerSecond: 10.0,
            engine: "  ",
            mtpFallbackReason: ""
        )
        #expect(!blank.contains("engine="))
        #expect(!blank.contains("mtp_off="))
    }

    @Test func statsHint_legacyWire_hasNilEngineAttribution() {
        // Wire written by a pre-attribution encoder must decode with nil
        // engine fields (upgrade-straddle compat, same contract as the
        // prefill flag).
        let decoded = StreamingStatsHint.decode("\u{FFFE}stats:128;99.4321")
        #expect(decoded?.tokenCount == 128)
        #expect(decoded?.engine == nil)
        #expect(decoded?.mtpFallbackReason == nil)
    }

    @Test func statsHint_decode_recoversEngineAlongsideAllOtherFlags() {
        let payload =
            "\u{FFFE}stats:10;5.0;unclosed,stop=length,prefill=300.25,engine=solo_mtp"
        let decoded = StreamingStatsHint.decode(payload)
        #expect(decoded?.unclosedReasoning == true)
        #expect(decoded?.stopReason == "length")
        #expect(abs((decoded?.prefillTokensPerSecond ?? 0) - 300.25) < 0.01)
        #expect(decoded?.engine == "solo_mtp")
        #expect(decoded?.mtpFallbackReason == nil)
    }

    @Test func statsHint_decode_engineFlagsIgnoreUnknownNeighbors() {
        // Unknown-flag preservation: future flags in the comma list must
        // not confuse the engine decoders, and the engine flags must not
        // shadow unknown flags for older decoders (maxSplits keeps the
        // whole flag field intact).
        let payload = "\u{FFFE}stats:10;5.0;futureflag,engine=batched,mtp_off=cold_warmup,another"
        let decoded = StreamingStatsHint.decode(payload)
        #expect(decoded?.tokenCount == 10)
        #expect(decoded?.engine == "batched")
        #expect(decoded?.mtpFallbackReason == "cold_warmup")
        #expect(decoded?.unclosedReasoning == false)
    }

    // MARK: - StreamingToolHint round-trip pins
    //
    // Migrated verbatim from the OsaurusEvals `StreamingHint` suite
    // (deterministic pure-data pins with no model in the loop — they
    // belong in the unit lane, not the eval catalog). Each test keeps
    // the original case's payload so no coverage was lost in the move.

    private func expectToolNameRoundTrip(_ payload: String) {
        let encoded = StreamingToolHint.encode(payload)
        #expect(StreamingToolHint.isSentinel(encoded))
        #expect(StreamingToolHint.decode(encoded) == payload)
    }

    private func expectArgsRoundTrip(_ payload: String) {
        let encoded = StreamingToolHint.encodeArgs(payload)
        #expect(StreamingToolHint.isSentinel(encoded))
        #expect(StreamingToolHint.decodeArgs(encoded) == payload)
    }

    @Test func toolHint_encode_roundTripsToolName() {
        expectToolNameRoundTrip("search_memory")
    }

    @Test func toolHint_encode_roundTripsUnicodeToolName() {
        // Sentinel is U+FFFE; CJK + emoji payload proves encode/decode
        // operate on full Unicode scalars (no byte-offset truncation) and
        // that isSentinel keys off the leading sentinel scalar, not ASCII.
        expectToolNameRoundTrip("工具_search_🔧")
    }

    @Test func toolHint_encode_emptyNameStillSentinelAndRoundTripsToEmpty() {
        // An empty tool-name fragment must still produce a sentinel-prefixed
        // delta (so the client routes it as a tool marker, not visible text)
        // and decode back to the empty string rather than nil.
        expectToolNameRoundTrip("")
    }

    @Test func toolHint_encodeArgs_roundTripsQuotesAndNewlines() {
        expectArgsRoundTrip("{\"query\": \"line one\\nline two\", \"limit\": 5}")
    }

    @Test func toolHint_encodeArgs_roundTripsDeeplyNestedFragment() {
        // A streamed args fragment can carry nested objects/arrays with
        // embedded quotes. The hint layer must treat the fragment as opaque
        // text and reproduce it byte-for-byte on decode — no
        // re-serialization, no key reordering.
        expectArgsRoundTrip(
            "{\"filter\": {\"tags\": [\"a\", \"b\"], \"range\": {\"min\": 1, \"max\": 9}}, "
                + "\"note\": \"q=\\\"x\\\"\"}"
        )
    }

    @Test func toolHint_encodeArgs_preservesBackslashes() {
        // Backslash-heavy payloads (a Windows path, a regex) are where a
        // naive escape/unescape round-trip drops or doubles characters.
        expectArgsRoundTrip("{\"path\": \"C:\\\\Users\\\\ada\\\\notes.txt\", \"pattern\": \"\\\\d+\\\\.\\\\d+\"}")
    }

    @Test func toolHint_encodeArgs_roundTripsEmptyObject() {
        // A zero-argument tool call (e.g. capabilities_discover) streams its
        // args as '{}'. Must round-trip intact rather than collapsing to "".
        expectArgsRoundTrip("{}")
    }

    @Test func toolHint_encodeDone_preservesAllFourFields() {
        let encoded = StreamingToolHint.encodeDone(
            callId: "call_abc123",
            name: "search_memory",
            arguments: "{\"query\":\"alpha\"}",
            result: "{\"ok\":true,\"result\":{\"hits\":2}}"
        )
        #expect(StreamingToolHint.isSentinel(encoded))
        let decoded = StreamingToolHint.decodeDone(encoded)
        #expect(decoded?.callId == "call_abc123")
        #expect(decoded?.name == "search_memory")
        #expect(decoded?.arguments == "{\"query\":\"alpha\"}")
        #expect(decoded?.result == "{\"ok\":true,\"result\":{\"hits\":2}}")
    }

    @Test func toolHint_encodeDone_roundTripsErrorEnvelopeResult() {
        // When the tool FAILED, the `result` field is itself a JSON
        // error-envelope string; encodeDone/decodeDone must round-trip all
        // four fields without the embedded JSON corrupting the outer JSON.
        let errorEnvelope =
            "{\"ok\":false,\"kind\":\"not_found\","
            + "\"message\":\"File not found: notes/missing.txt.\",\"retryable\":false}"
        let encoded = StreamingToolHint.encodeDone(
            callId: "call_42",
            name: "file_read",
            arguments: "{\"path\": \"notes/missing.txt\"}",
            result: errorEnvelope
        )
        let decoded = StreamingToolHint.decodeDone(encoded)
        #expect(decoded?.callId == "call_42")
        #expect(decoded?.name == "file_read")
        #expect(decoded?.arguments == "{\"path\": \"notes/missing.txt\"}")
        #expect(decoded?.result == errorEnvelope)
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
