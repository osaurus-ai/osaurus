//
//  RelayTunnelStreamingTests.swift
//  OsaurusCoreTests
//
//  Unit coverage for the relay tunnel's host-side streaming transport and
//  in-flight request lifecycle. The direct-NIO Secure Channel E2E tests prove
//  `/agents/{address}/run` resolves and streams against the local server, but
//  the production remote path adds a leg the E2E never exercises: the host's
//  `RelayTunnelManager` proxies the loopback response back over a WebSocket as
//  `stream_start` / `stream_chunk`* / `stream_end` frames.
//
//  These tests drive that path through the injected `RelayFrameSink` seam (a
//  recording sink instead of a live WebSocket) so we can assert the three
//  properties the old fire-and-forget send lacked — ordering, fail-fast on a
//  send error, and end-of-stream byte preservation — plus the cancellation
//  registry that stops host generation when the tunnel tears down.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct RelayTunnelStreamingTests {

    // MARK: - Recording sink

    /// Captures every serialized frame the streaming/buffered helpers hand to
    /// the sink, and can simulate a transport failure on a chosen frame so the
    /// fail-fast path is observable.
    private actor FrameRecorder {
        struct Captured: Sendable {
            let type: String
            let raw: String
        }

        private(set) var captured: [Captured] = []
        private var chunkCount = 0
        private let shouldFail: @Sendable (_ type: String, _ chunkIndex: Int) -> Bool

        init(shouldFail: @escaping @Sendable (_ type: String, _ chunkIndex: Int) -> Bool = { _, _ in false }) {
            self.shouldFail = shouldFail
        }

        /// Matches `RelayFrameSink`: record the attempted frame, then report
        /// whether the transport accepted it.
        func sink(_ json: String) -> Bool {
            let type = Self.decodeString(json, key: "type") ?? "?"
            var chunkIndex = 0
            if type == "stream_chunk" {
                chunkCount += 1
                chunkIndex = chunkCount
            }
            captured.append(Captured(type: type, raw: json))
            return !shouldFail(type, chunkIndex)
        }

        var types: [String] { captured.map(\.type) }

        /// Concatenate the decoded payloads of every `stream_chunk`, so a test
        /// can prove no bytes were dropped end to end.
        func chunkPayload() -> String {
            captured.compactMap { item -> String? in
                guard item.type == "stream_chunk" else { return nil }
                return Self.decodeString(item.raw, key: "data")
            }
            .joined()
        }

        func responseBody() -> String? {
            captured.first(where: { $0.type == "response" })
                .flatMap { Self.decodeString($0.raw, key: "body") }
        }

        private static func decodeString(_ json: String, key: String) -> String? {
            guard let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj[key] as? String
        }
    }

    /// Build an `AsyncStream<UInt8>` that yields every byte then finishes —
    /// stands in for `URLSession.AsyncBytes` from the loopback response.
    private func byteStream(_ bytes: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for b in bytes { continuation.yield(b) }
            continuation.finish()
        }
    }

    private func sink(for recorder: FrameRecorder) -> RelayFrameSink {
        { json in await recorder.sink(json) }
    }

    // MARK: - Streaming order

    @Test func streaming_emitsStartChunksEndInOrder() async {
        let recorder = FrameRecorder()
        await RelayTunnelManager.relayStreamingResponse(
            id: "r1",
            status: 200,
            headers: ["content-type": "text/event-stream"],
            bytes: byteStream(Array("hello\nworld\n".utf8)),
            via: sink(for: recorder)
        )

        let types = await recorder.types
        #expect(types == ["stream_start", "stream_chunk", "stream_chunk", "stream_end"])
        // Newline-delimited flushing must reproduce the source byte-for-byte.
        #expect(await recorder.chunkPayload() == "hello\nworld\n")
    }

    // MARK: - End-of-stream byte preservation (Gap 4)

    @Test func streaming_flushesTrailingBytesWithoutNewline() async {
        let recorder = FrameRecorder()
        // No trailing newline and under the size threshold: the only flush is
        // the end-of-stream one. The bytes must not be silently dropped.
        await RelayTunnelManager.relayStreamingResponse(
            id: "r2",
            status: 200,
            headers: [:],
            bytes: byteStream(Array("partial-line-no-newline".utf8)),
            via: sink(for: recorder)
        )

        let types = await recorder.types
        #expect(types == ["stream_start", "stream_chunk", "stream_end"])
        #expect(await recorder.chunkPayload() == "partial-line-no-newline")
    }

    @Test func streaming_forwardsIncompleteUTF8TailAtEnd() async {
        let recorder = FrameRecorder()
        // "ok" followed by a lone 0xE2 (the first byte of a 3-byte code point).
        // The valid prefix flushes as one chunk; the incomplete tail must still
        // be forwarded (lossily) at end-of-stream rather than dropped.
        var bytes = Array("ok".utf8)
        bytes.append(0xE2)
        await RelayTunnelManager.relayStreamingResponse(
            id: "r3",
            status: 200,
            headers: [:],
            bytes: byteStream(bytes),
            via: sink(for: recorder)
        )

        let types = await recorder.types
        #expect(types == ["stream_start", "stream_chunk", "stream_chunk", "stream_end"])
        // The tail surfaces as the Unicode replacement character, never nothing.
        let payload = await recorder.chunkPayload()
        #expect(payload.hasPrefix("ok"))
        #expect(payload.unicodeScalars.contains("\u{FFFD}"))
    }

    // MARK: - Fail-fast on send error

    @Test func streaming_abortsAfterFailedChunkSend() async {
        // Fail the 2nd chunk send: the loop must stop and emit no further
        // frames — crucially no stream_end into a dead socket.
        let recorder = FrameRecorder(shouldFail: { type, chunkIndex in
            type == "stream_chunk" && chunkIndex == 2
        })
        await RelayTunnelManager.relayStreamingResponse(
            id: "r4",
            status: 200,
            headers: [:],
            bytes: byteStream(Array("aa\nbb\ncc\n".utf8)),
            via: sink(for: recorder)
        )

        let types = await recorder.types
        #expect(types == ["stream_start", "stream_chunk", "stream_chunk"])
        #expect(!types.contains("stream_end"))
    }

    @Test func streaming_abortsWhenStartFails() async {
        // A failed stream_start means the socket is already gone: read nothing,
        // emit nothing else.
        let recorder = FrameRecorder(shouldFail: { type, _ in type == "stream_start" })
        await RelayTunnelManager.relayStreamingResponse(
            id: "r5",
            status: 200,
            headers: [:],
            bytes: byteStream(Array("data\n".utf8)),
            via: sink(for: recorder)
        )

        let types = await recorder.types
        #expect(types == ["stream_start"])
    }

    // MARK: - Buffered path

    @Test func buffered_emitsSingleResponseFrame() async {
        let recorder = FrameRecorder()
        let body = #"{"ok":true}"#
        await RelayTunnelManager.relayBufferedResponse(
            id: "b1",
            status: 200,
            headers: ["content-type": "application/json"],
            bytes: byteStream(Array(body.utf8)),
            via: sink(for: recorder)
        )

        let types = await recorder.types
        #expect(types == ["response"])
        #expect(await recorder.responseBody() == body)
    }

    // MARK: - In-flight cancellation (Gap 2)

    @Test func cancelAllInFlightRequests_cancelsTrackedTasks() async {
        let mgr = RelayTunnelManager.shared
        mgr.cancelAllInFlightRequests()  // clean slate (no tunnel runs in tests)
        #expect(mgr.inFlightRequests.isEmpty)

        let task = Task.detached {
            // Cancellation-aware busy-wait, modelling the proxy byte loop.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        mgr.inFlightRequests["unit-req-1"] = RelayTunnelManager.InFlightRequest(
            agentUUID: nil,
            task: task
        )
        #expect(mgr.inFlightRequests.count == 1)

        mgr.cancelAllInFlightRequests()
        #expect(mgr.inFlightRequests.isEmpty)

        // The tracked task observes cancellation and finishes.
        await task.value
        #expect(task.isCancelled)
    }

    @Test func cancelInFlightRequest_cancelsSingleTrackedTask() async {
        // Mirrors the `cancel` frame handler path.
        let mgr = RelayTunnelManager.shared
        mgr.cancelAllInFlightRequests()

        let keep = Task.detached {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        let drop = Task.detached {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        mgr.inFlightRequests["keep"] = RelayTunnelManager.InFlightRequest(agentUUID: nil, task: keep)
        mgr.inFlightRequests["drop"] = RelayTunnelManager.InFlightRequest(agentUUID: nil, task: drop)

        mgr.cancelInFlightRequest(id: "drop")
        #expect(mgr.inFlightRequests["drop"] == nil)
        #expect(mgr.inFlightRequests["keep"] != nil)

        await drop.value
        #expect(drop.isCancelled)
        #expect(!keep.isCancelled)

        // Cleanup so the singleton's registry doesn't leak into other suites.
        mgr.cancelAllInFlightRequests()
        await keep.value
    }

    // MARK: - In-flight capacity cap (Gap: hostile-relay flood defense)

    @Test func inFlightCap_rejectsBeyondLimitWith503() async {
        let mgr = RelayTunnelManager.shared
        mgr.cancelAllInFlightRequests()

        // Under capacity: no rejection — the request proceeds normally.
        #expect(mgr.inFlightCapacityRejection(id: "probe") == nil)

        // Fill to exactly the cap with completed dummy tasks.
        let cap = RelayTunnelManager.maxConcurrentInFlightRequests
        for i in 0 ..< cap {
            mgr.inFlightRequests["fill-\(i)"] = RelayTunnelManager.InFlightRequest(
                agentUUID: nil,
                task: Task<Void, Never> {}
            )
        }
        #expect(mgr.inFlightRequests.count == cap)

        // At capacity: a new request is rejected with a 503 `response` frame
        // carrying the original id, so the relay can close the initiator
        // promptly instead of leaving it to hang.
        let rejection = mgr.inFlightCapacityRejection(id: "overflow")
        #expect(rejection?["type"] as? String == "response")
        #expect(rejection?["status"] as? Int == 503)
        #expect(rejection?["id"] as? String == "overflow")

        // Dropping one back under the cap re-opens capacity.
        mgr.inFlightRequests["fill-0"] = nil
        #expect(mgr.inFlightCapacityRejection(id: "probe") == nil)

        mgr.cancelAllInFlightRequests()
        #expect(mgr.inFlightRequests.isEmpty)
    }
}
