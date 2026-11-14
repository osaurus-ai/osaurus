//
//  WorkspaceBillingRelayStreamTests.swift
//  osaurusTests
//
//  A teammate's spend chip ticks in real time because the sharer's Osaurus
//  relays the Router's `{"osaurus": {...}}` summary verbatim on the
//  `/agents/{id}/run` SSE. The client must therefore decode that frame on
//  an `.osaurus` (peer) provider too — not only on `.osaurusRouter` — and
//  surface it as a `StreamingBillingHint` sentinel without ending the
//  stream. Also pins the host-side relay chunk shape.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workspace billing relay over the agent-run stream")
struct WorkspaceBillingRelayStreamTests {

    private static let summaryFrame =
        #"{"osaurus":{"request_id":"req-77","cost_micro":"4200","status":"completed","token_source":"provider","input_tokens":120,"output_tokens":18,"billed_to":"workspace:ws-acme"}}"#

    private func collect(
        providerType: RemoteProviderType,
        frame: String
    ) async -> (finished: Bool, yielded: [String]) {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let finished = RemoteProviderService.processEventPayload(
            frame,
            state: &state,
            providerType: providerType,
            tools: [],
            continuation: continuation
        )
        continuation.finish()
        var yielded: [String] = []
        do {
            for try await chunk in stream { yielded.append(chunk) }
        } catch {}
        return (finished, yielded)
    }

    @Test func osaurusPeer_relayedSummary_yieldsBillingHintWithoutFinishing() async throws {
        let (finished, yielded) = await collect(providerType: .osaurus, frame: Self.summaryFrame)

        #expect(finished == false, "a billing frame never ends the run")
        #expect(yielded.count == 1)
        let hint = try #require(yielded.first)
        #expect(hint.hasPrefix("\u{FFFE}"), "sentinel keeps it out of visible output + token counting")
        let summary = try #require(StreamingBillingHint.decode(hint))
        #expect(summary.requestId == "req-77")
        #expect(summary.costMicro == "4200")
        #expect(summary.status == "completed")
        #expect(summary.inputTokens == 120)
        #expect(summary.outputTokens == 18)
        #expect(
            summary.billedTo == "workspace:ws-acme",
            "workspace-pool attribution drives the 'Workspace pool' chip label"
        )
    }

    @Test func router_summaryStillDecodesIdentically() async throws {
        let (finished, yielded) = await collect(providerType: .osaurusRouter, frame: Self.summaryFrame)
        #expect(finished == false)
        let summary = try #require(yielded.first.flatMap(StreamingBillingHint.decode))
        #expect(summary.costMicro == "4200")
    }

    @Test func nonOsaurusProviders_ignoreTheFrame() async {
        // An OpenAI-compatible host has no such frame; it must not be turned
        // into a billing hint (and an unknown chunk shape is simply skipped).
        let (finished, yielded) = await collect(providerType: .openaiLegacy, frame: Self.summaryFrame)
        #expect(finished == false)
        #expect(yielded.allSatisfy { StreamingBillingHint.decode($0) == nil })
    }

    @Test func osaurusPeer_ordinaryContentChunk_isNotMistakenForBilling() async {
        let (finished, yielded) = await collect(
            providerType: .osaurus,
            frame: #"{"choices":[{"delta":{"content":"hello from the osaurus host"}}]}"#
        )
        #expect(finished == false)
        #expect(yielded == ["hello from the osaurus host"])
    }

    @Test func hostRelayChunk_matchesRouterWireShape() throws {
        // The host wraps the summary exactly as the Router emits it so the
        // client's decoder is shared; `billed_to` is preserved.
        let chunk = SSEResponseWriter.RouterSummaryRelayChunk(
            osaurus: .init(
                request_id: "req-77",
                cost_micro: "4200",
                status: "completed",
                token_source: "provider",
                input_tokens: 120,
                output_tokens: 18,
                billed_to: "workspace:ws-acme"
            )
        )
        let data = try JSONEncoder().encode(chunk)
        let roundTrip = try JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: data)
        #expect(roundTrip.osaurus.costMicro == "4200")
        #expect(roundTrip.osaurus.billedTo == "workspace:ws-acme")
        #expect(roundTrip.osaurus.billedWorkspaceId == "ws-acme")
        #expect(roundTrip.osaurus.requestId == "req-77")
    }
}
