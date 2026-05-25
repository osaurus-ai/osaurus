//
//  WireTransportProbeTests.swift
//  osaurusTests
//
//  Unit tests for `WireTransportProbe` — the lock-protected sink
//  the chat layer reads to verify what actually hit the network.
//  Validates:
//    • recordRequestBody is idempotent (a retried URLRequest
//      shouldn't stomp the first snapshot)
//    • appendResponseChunk accumulates in order and respects the
//      1 MiB hard cap (with the `truncated` flag set on overflow)
//    • replaceResponseBody truncates the same way as appendChunk
//    • Snapshots are stable copies (mutating the probe after a
//      snapshot doesn't mutate the snapshot)
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("WireTransportProbe")
struct WireTransportProbeTests {

    @Test func emptyProbe_snapshotsCleanly() {
        let probe = WireTransportProbe()
        let snap = probe.snapshot()
        #expect(snap.request == nil)
        #expect(snap.response.isEmpty)
        #expect(snap.truncated == false)
    }

    @Test func recordRequestBody_isIdempotent() {
        let probe = WireTransportProbe()
        probe.recordRequestBody("first".data(using: .utf8)!)
        probe.recordRequestBody("second".data(using: .utf8)!)
        let snap = probe.snapshot()
        // First write wins — guards against a URLRequest retry
        // overwriting the original (we always want the verbatim
        // body the cloud first saw).
        #expect(snap.request == "first".data(using: .utf8))
    }

    @Test func appendResponseChunk_accumulatesInOrder() {
        let probe = WireTransportProbe()
        probe.appendResponseChunk("hello".data(using: .utf8)!)
        probe.appendResponseChunk(" ".data(using: .utf8)!)
        probe.appendResponseChunk("world".data(using: .utf8)!)
        let snap = probe.snapshot()
        #expect(String(data: snap.response, encoding: .utf8) == "hello world")
        #expect(snap.truncated == false)
    }

    @Test func appendResponseChunk_truncatesAtMaxBytes() {
        let probe = WireTransportProbe()
        // Fill exactly to the cap, then attempt to write one
        // more chunk. The extra bytes must be dropped and the
        // truncated flag flipped on.
        let cap = WireTransportProbe.maxResponseBytes
        probe.appendResponseChunk(Data(repeating: 0x41, count: cap))
        #expect(probe.snapshot().truncated == false)
        probe.appendResponseChunk(Data(repeating: 0x42, count: 16))
        let snap = probe.snapshot()
        #expect(snap.response.count == cap)
        #expect(snap.truncated == true)
        // Trailing bytes must be the 0x41 fill — the 0x42
        // attempted append went past the cap so none of it
        // should have landed.
        #expect(snap.response.last == 0x41)
    }

    @Test func appendResponseChunk_partialOverflowSpillsToCap() {
        let probe = WireTransportProbe()
        let cap = WireTransportProbe.maxResponseBytes
        // Fill to one byte short of the cap, then push a chunk
        // larger than the remaining space. The probe must take
        // only the head bytes that fit.
        probe.appendResponseChunk(Data(repeating: 0x41, count: cap - 1))
        probe.appendResponseChunk(Data(repeating: 0x42, count: 100))
        let snap = probe.snapshot()
        #expect(snap.response.count == cap)
        #expect(snap.truncated == true)
        // Last byte should be 0x42 — exactly one B-byte landed.
        #expect(snap.response.last == 0x42)
    }

    @Test func replaceResponseBody_truncatesOversizedPayload() {
        let probe = WireTransportProbe()
        let cap = WireTransportProbe.maxResponseBytes
        probe.replaceResponseBody(Data(repeating: 0x43, count: cap + 100))
        let snap = probe.snapshot()
        #expect(snap.response.count == cap)
        #expect(snap.truncated == true)
    }

    @Test func snapshot_isStableAfterMutation() {
        let probe = WireTransportProbe()
        probe.recordRequestBody("orig".data(using: .utf8)!)
        probe.appendResponseChunk("first".data(using: .utf8)!)
        let firstSnap = probe.snapshot()

        // Mutate the probe AFTER snapshot. The first snap must
        // not see the new data — `snapshot()` returns a copy.
        probe.appendResponseChunk("second".data(using: .utf8)!)

        #expect(String(data: firstSnap.response, encoding: .utf8) == "first")
        #expect(firstSnap.request == "orig".data(using: .utf8))

        let secondSnap = probe.snapshot()
        #expect(String(data: secondSnap.response, encoding: .utf8) == "firstsecond")
    }

    @Test func appendResponseChunk_ignoresEmpty() {
        let probe = WireTransportProbe()
        probe.appendResponseChunk(Data())
        probe.appendResponseChunk("ok".data(using: .utf8)!)
        let snap = probe.snapshot()
        #expect(String(data: snap.response, encoding: .utf8) == "ok")
        #expect(snap.truncated == false)
    }
}
