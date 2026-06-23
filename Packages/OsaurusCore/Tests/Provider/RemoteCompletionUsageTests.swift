//
//  RemoteCompletionUsageTests.swift
//  osaurusTests
//
//  Pins the remote completion-token telemetry path: OpenAI Chat-Completions
//  upstreams (xAI/Grok via `.openaiLegacy`, Azure) are asked for a final
//  `usage` chunk (`stream_options.include_usage`); the streaming parser
//  captures it and `dispatchFinal` surfaces it as a `StreamingStatsHint`, the
//  same in-band signal the local vmlx runtime emits. Before this, remote runs
//  reported 0 completion tokens because the usage chunk was decoded but never
//  acted on. Covers: usage capture, the scoped tool-dispatch deferral that lets
//  the trailing usage chunk land on tool-call turns too, the hint emission, and
//  the end-to-end `.openaiLegacy` wiring.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote completion-token usage telemetry")
struct RemoteCompletionUsageTests {

    // Strict-mode chunk envelope; `ChatCompletionChunk` requires id/created/model.
    private static let env = #""id":"c","object":"chat.completion.chunk","created":0,"model":"m""#

    private static func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Usage capture

    @Test func strictUsageChunk_capturedIntoProviderUsage() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let outcome = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Self.data(
                #"{\#(Self.env),"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":48,"total_tokens":168}}"#
            ),
            options: .strict,
            state: &state,
            yield: { _ in }
        )

        guard case .continue = outcome else {
            Issue.record("usage-only chunk should continue, got \(outcome)")
            return
        }
        #expect(state.providerUsage?.completion_tokens == 48)
        #expect(state.providerUsage?.prompt_tokens == 120)
    }

    @Test func perChunkNullUsage_doesNotClobberCapturedTotals() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        // Real total arrives, then a normal content chunk with usage:null — the
        // captured value must survive (OpenAI sends null on non-final chunks).
        state.captureProviderUsage(Usage(prompt_tokens: 10, completion_tokens: 7, total_tokens: 17))
        _ = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Self.data(
                #"{\#(Self.env),"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"#
            ),
            options: .strict,
            state: &state,
            yield: { _ in }
        )
        #expect(state.providerUsage?.completion_tokens == 7)
    }

    // MARK: - Scoped tool-dispatch deferral

    @Test func deferEnabled_toolCallFinishIsHeldForTrailingUsage() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var options = OpenAICompatibleStreamParser.Options.strict
        options.deferToolCallDispatchUntilUsage = true

        _ = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Self.data(
                #"{\#(Self.env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"file_read","arguments":"{}"}}]},"finish_reason":null}]}"#
            ),
            options: options,
            state: &state,
            yield: { _ in }
        )

        let finish = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Self.data(
                #"{\#(Self.env),"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#
            ),
            options: options,
            state: &state,
            yield: { _ in }
        )

        // Deferred: not dispatched yet, but the call is preserved for dispatchFinal.
        guard case .continue = finish else {
            Issue.record("deferred tool-call finish should continue, got \(finish)")
            return
        }
        #expect(state.accumulatedToolCalls[0]?.name == "file_read")
    }

    @Test func deferDisabled_toolCallFinishDispatchesImmediately() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)

        _ = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Self.data(
                #"{\#(Self.env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"file_read","arguments":"{}"}}]},"finish_reason":null}]}"#
            ),
            options: .strict,
            state: &state,
            yield: { _ in }
        )

        let finish = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Self.data(
                #"{\#(Self.env),"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#
            ),
            options: .strict,
            state: &state,
            yield: { _ in }
        )

        guard case .finishWithToolCall(let inv) = finish else {
            Issue.record("non-deferred tool-call finish should dispatch, got \(finish)")
            return
        }
        #expect(inv.toolName == "file_read")
    }

    // MARK: - dispatchFinal stats-hint emission

    @Test func dispatchFinal_textTurn_emitsStatsHintFromUsage() async {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        state.captureProviderUsage(Usage(prompt_tokens: 100, completion_tokens: 42, total_tokens: 142))
        state.lastFinishReason = "stop"

        let (deltas, thrown) = await Self.drainDispatchFinal(state: state)

        #expect(thrown == nil)
        let stats = deltas.compactMap { StreamingStatsHint.decode($0) }
        #expect(stats.count == 1)
        #expect(stats.first?.tokenCount == 42)
        #expect(stats.first?.stopReason == "stop")
        #expect(stats.first?.tokensPerSecond == 0)  // xAI omits tps; eval skips 0 for averaging
    }

    @Test func dispatchFinal_usesProviderTokensPerSecond_whenPresent() async {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        state.captureProviderUsage(
            Usage(prompt_tokens: 100, completion_tokens: 42, total_tokens: 142, tokens_per_second: 73.5)
        )
        state.lastFinishReason = "stop"

        let (deltas, _) = await Self.drainDispatchFinal(state: state)
        let stats = deltas.compactMap { StreamingStatsHint.decode($0) }
        #expect(stats.first?.tokensPerSecond == 73.5)
    }

    @Test func dispatchFinal_deferredToolTurn_emitsHintThenThrowsInvocation() async {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        state.accumulatedToolCalls[0] = (
            id: "call_1", name: "file_read", args: #"{"path":"a.txt"}"#, thoughtSignature: nil
        )
        state.lastFinishReason = "tool_calls"
        state.captureProviderUsage(Usage(prompt_tokens: 100, completion_tokens: 30, total_tokens: 130))

        let (deltas, thrown) = await Self.drainDispatchFinal(state: state)

        // The stats hint is delivered to the consumer BEFORE the finish-by-throw,
        // so a tool-call turn still reports its decode token count (matching local).
        let stats = deltas.compactMap { StreamingStatsHint.decode($0) }
        #expect(stats.first?.tokenCount == 30)
        #expect((thrown as? ServiceToolInvocation)?.toolName == "file_read")
    }

    @Test func dispatchFinal_noUsage_emitsNoStatsHint() async {
        let state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let (deltas, _) = await Self.drainDispatchFinal(state: state)
        #expect(deltas.allSatisfy { StreamingStatsHint.decode($0) == nil })
    }

    // MARK: - End-to-end wiring (.openaiLegacy → defer → usage → dispatch)

    @Test func endToEnd_openaiLegacy_deferredToolTurn_surfacesUsageThenDispatches() async {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)

        let toolDelta = RemoteProviderService.processEventPayload(
            #"{\#(Self.env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"file_read","arguments":"{}"}}]},"finish_reason":null}]}"#,
            state: &state,
            providerType: .openaiLegacy,
            tools: [],
            continuation: continuation
        )
        #expect(toolDelta == false)

        // For `.openaiLegacy` the tool-call finish is deferred (returns false),
        // so the trailing usage chunk is consumed before the call dispatches.
        let toolFinish = RemoteProviderService.processEventPayload(
            #"{\#(Self.env),"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            state: &state,
            providerType: .openaiLegacy,
            tools: [],
            continuation: continuation
        )
        #expect(toolFinish == false)

        let usage = RemoteProviderService.processEventPayload(
            #"{\#(Self.env),"choices":[],"usage":{"prompt_tokens":80,"completion_tokens":21,"total_tokens":101}}"#,
            state: &state,
            providerType: .openaiLegacy,
            tools: [],
            continuation: continuation
        )
        #expect(usage == false)

        let done = RemoteProviderService.processEventPayload(
            "[DONE]",
            state: &state,
            providerType: .openaiLegacy,
            tools: [],
            continuation: continuation
        )
        #expect(done == true)

        var deltas: [String] = []
        var thrown: Error?
        do {
            for try await delta in stream { deltas.append(delta) }
        } catch {
            thrown = error
        }

        let stats = deltas.compactMap { StreamingStatsHint.decode($0) }
        #expect(stats.first?.tokenCount == 21)
        #expect(stats.first?.stopReason == "tool_calls")
        #expect((thrown as? ServiceToolInvocation)?.toolName == "file_read")
    }

    // MARK: - Helpers

    private static func drainDispatchFinal(
        state: RemoteProviderService.StreamingState
    ) async -> (deltas: [String], thrown: Error?) {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        RemoteProviderService.dispatchFinal(
            state: state,
            tools: [],
            finishMarker: "[DONE]",
            continuation: continuation
        )
        var deltas: [String] = []
        var thrown: Error?
        do {
            for try await delta in stream { deltas.append(delta) }
        } catch {
            thrown = error
        }
        return (deltas, thrown)
    }
}
