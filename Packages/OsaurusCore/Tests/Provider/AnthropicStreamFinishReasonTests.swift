//
//  AnthropicStreamFinishReasonTests.swift
//  osaurusTests
//
//  Pins the Anthropic streaming path's finish-reason normalization and
//  usage capture. Anthropic speaks its own stop vocabulary (`end_turn`,
//  `max_tokens`, `tool_use`) but every downstream consumer — the HTTP
//  chat writer, `InferenceLog.FinishReason`, the Anthropic-compat writer
//  that maps back `length` → `max_tokens` — expects OpenAI vocabulary.
//  Before the mapping, a truncated Anthropic turn surfaced
//  `finish_reason: "stop"` and never emitted a stats hint (usage arrived
//  on `message_start`/`message_delta` but was never captured).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Anthropic stream finish-reason normalization + usage capture")
struct AnthropicStreamFinishReasonTests {

    private static func handle(
        _ json: String,
        state: inout RemoteProviderService.StreamingState
    ) {
        let (_, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        _ = RemoteProviderService.processEventPayload(
            json,
            state: &state,
            providerType: .anthropic,
            tools: [],
            continuation: continuation
        )
        continuation.finish()
    }

    @Test func maxTokensStopReason_normalizesToLength() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        Self.handle(
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":16}}"#,
            state: &state
        )
        #expect(state.lastFinishReason == "length")
    }

    @Test func endTurnStopReason_normalizesToStop() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        Self.handle(
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}"#,
            state: &state
        )
        #expect(state.lastFinishReason == "stop")
    }

    @Test func stopSequenceStopReason_normalizesToStop() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        Self.handle(
            #"{"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":"END"},"usage":{"output_tokens":4}}"#,
            state: &state
        )
        #expect(state.lastFinishReason == "stop")
    }

    @Test func toolUseStopReason_normalizesToToolCalls() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        Self.handle(
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":22}}"#,
            state: &state
        )
        #expect(state.lastFinishReason == "tool_calls")
    }

    @Test func usage_capturedFromMessageStartAndDelta() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        Self.handle(
            #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":41,"output_tokens":0}}}"#,
            state: &state
        )
        #expect(state.providerUsage?.prompt_tokens == 41)

        Self.handle(
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":16}}"#,
            state: &state
        )
        #expect(state.providerUsage?.prompt_tokens == 41)
        #expect(state.providerUsage?.completion_tokens == 16)
        #expect(state.providerUsage?.total_tokens == 57)
    }

    @Test func dispatchFinal_afterTruncatedTurn_emitsLengthStatsHint() async {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        Self.handle(
            #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":41,"output_tokens":0}}}"#,
            state: &state
        )
        Self.handle(
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":16}}"#,
            state: &state
        )

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        RemoteProviderService.dispatchFinal(
            state: state,
            tools: [],
            finishMarker: "anthropic message_stop",
            continuation: continuation
        )
        var deltas: [String] = []
        do {
            for try await delta in stream { deltas.append(delta) }
        } catch {}

        let stats = deltas.compactMap { StreamingStatsHint.decode($0) }
        #expect(stats.count == 1)
        #expect(stats.first?.tokenCount == 16)
        #expect(stats.first?.stopReason == "length")
    }

    @Test func refusalStopReason_stillFinishesWithError() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let finished = RemoteProviderService.processEventPayload(
            #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null,"stop_details":{"explanation":"policy"}},"usage":{"output_tokens":0}}"#,
            state: &state,
            providerType: .anthropic,
            tools: [],
            continuation: continuation
        )
        #expect(finished == true)
        continuation.finish()
        _ = stream
    }

    @Test(arguments: [7_996, 9_000, 16_000])
    func largeInputJSONDelta_preservesAllToolArguments(contentBytes: Int) throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []
        let arguments = #"{"path":"probe.txt","content":""#
            + String(repeating: "x", count: contentBytes)
            + #""}"#

        let start =
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_large","name":"file_write","input":{}}}"#
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(start.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { yielded.append($0) }
        )

        let deltaObject: [String: Any] = [
            "type": "content_block_delta",
            "index": 0,
            "delta": [
                "type": "input_json_delta",
                "partial_json": arguments,
            ],
        ]
        let deltaData = try JSONSerialization.data(withJSONObject: deltaObject)
        let delta = RemoteProviderService.handleStreamEvent(
            jsonData: deltaData,
            providerType: .anthropic,
            state: &state,
            yield: { yielded.append($0) }
        )
        guard case .continue = delta else {
            Issue.record("Expected large Anthropic delta to continue, got \(delta)")
            return
        }

        let finishReason =
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":100}}"#
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(finishReason.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { yielded.append($0) }
        )
        let stop = RemoteProviderService.handleStreamEvent(
            jsonData: Data(#"{"type":"message_stop"}"#.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .finishWithToolCall(let invocations) = stop,
            let invocation = invocations.first
        else {
            Issue.record("Expected complete Anthropic tool call, got \(stop)")
            return
        }
        #expect(invocation.jsonArguments == arguments)
        #expect(yielded.compactMap { StreamingToolHint.decodeArgs($0) }.joined() == arguments)
    }

    @Test func maxTokensWithPendingToolCallIsTruncationError() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let start =
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"file_write","input":{}}}"#
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(start.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )
        let limit =
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":4096}}"#
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(limit.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )

        let stop = RemoteProviderService.handleStreamEvent(
            jsonData: Data(#"{"type":"message_stop"}"#.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )

        guard case .finishWithError(let error) = stop else {
            Issue.record("Expected max_tokens tool call to fail, got \(stop)")
            return
        }
        #expect(error.localizedDescription.contains("output token limit"))
        #expect(error.localizedDescription.contains("received 0 bytes"))
    }

    @Test func malformedInputJSONDeltaIsNotSilentlyDropped() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let start =
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"file_write","input":{}}}"#
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(start.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )
        let malformed =
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":123}}"#
        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(malformed.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )

        guard case .finishWithError(let error) = outcome else {
            Issue.record("Expected malformed tool delta to fail, got \(outcome)")
            return
        }
        #expect(error.localizedDescription.contains("invalid streaming event"))
        #expect(error.localizedDescription.contains("while receiving tool arguments"))
    }
}
