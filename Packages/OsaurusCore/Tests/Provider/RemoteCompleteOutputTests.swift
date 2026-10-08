import Foundation
import Testing
@testable import OsaurusCore

@Suite("Complete remote summaries preserve provider termination")
struct RemoteCompleteOutputTests {
    @Test(arguments: [RemoteProviderType.openaiLegacy, .osaurusRouter, .openAICodex, .gemini])
    func truncatedStreamWithoutUsageCannotBecomeSummary(provider: RemoteProviderType) async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        state.requireCompleteOutput = true
        let frames: [String]
        switch provider {
        case .openAICodex:
            frames = [
                #"{"type":"response.output_text.delta","sequence_number":1,"item_id":"m1","output_index":0,"content_index":0,"delta":"Partial summary"}"#,
                #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#,
            ]
        case .gemini:
            frames = [
                #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Partial summary"}]},"finishReason":"MAX_TOKENS"}]}"#,
            ]
        default:
            frames = [
                #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Partial summary"},"finish_reason":null}]}"#,
                #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
                "[DONE]",
            ]
        }
        var finished = false
        for frame in frames {
            finished = RemoteProviderService.processEventPayload(
                frame, state: &state, providerType: provider, tools: [], continuation: continuation)
            if finished { break }
        }
        if !finished {
            RemoteProviderService.dispatchFinal(
                state: state, tools: [], finishMarker: "stream-end", continuation: continuation)
        }
        #expect(state.providerUsage == nil)
        #expect(state.yieldedTextCount > 0, "Exercise an actual partial visible answer, not just an empty refusal")
        do {
            _ = try await RemoteProviderService.collectVisibleText(from: stream)
            Issue.record("Truncated visible text must not become a compaction summary")
        } catch RemoteProviderServiceError.outputTruncated {
            // Expected; the one-shot caller never receives a summary to apply.
        }
    }

    @Test(arguments: [true, false])
    func completedStreamAndInteractivePartialContract(required: Bool) async throws {
        for reason in ["stop", "length"] {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
            state.requireCompleteOutput = required
            state.lastFinishReason = reason
            continuation.yield("Visible reply")
            RemoteProviderService.dispatchFinal(
                state: state, tools: [], finishMarker: "[DONE]", continuation: continuation)
            if required && reason == "length" {
                do {
                    _ = try await RemoteProviderService.collectVisibleText(from: stream)
                    Issue.record("Required complete output must reject length")
                } catch RemoteProviderServiceError.outputTruncated {}
            } else {
                #expect(try await RemoteProviderService.collectVisibleText(from: stream) == "Visible reply")
            }
        }
    }

    @Test func abruptEOFDoesNotCommitPartialSummary() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        state.requireCompleteOutput = true
        let finished = RemoteProviderService.processEventPayload(
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Partial summary"},"finish_reason":null}]}"#,
            state: &state, providerType: .openaiLegacy, tools: [], continuation: continuation)
        #expect(!finished)
        #expect(state.yieldedTextCount > 0)
        #expect(state.lastFinishReason == nil)
        RemoteProviderService.dispatchFinal(
            state: state, tools: [], finishMarker: "stream-end", continuation: continuation)
        do {
            _ = try await RemoteProviderService.collectVisibleText(from: stream)
            Issue.record("Abrupt EOF must not return a partial summary")
        } catch RemoteProviderServiceError.streamingError {}
    }

    @Test func eofAndExplicitCompletionControls() async throws {
        // Interactive streams retain their existing EOF behavior. Required summaries
        // accept either an explicit provider finish reason or the SSE done marker.
        for (required, reason, marker) in [
            (false, Optional<String>.none, "stream-end"),
            (true, Optional("stop"), "stream-end"),
            (true, Optional<String>.none, "[DONE]"),
        ] {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
            state.requireCompleteOutput = required
            state.lastFinishReason = reason
            continuation.yield("Visible reply")
            RemoteProviderService.dispatchFinal(
                state: state, tools: [], finishMarker: marker, continuation: continuation)
            #expect(try await RemoteProviderService.collectVisibleText(from: stream) == "Visible reply")
        }
    }

    @Test func nonstreamProviderFinishMetadata() throws {
        let truncated = [
            #"{"choices":[{"message":{"content":"Partial"},"finish_reason":"length"}]}"#,
            #"{"content":[{"type":"text","text":"Partial"}],"stop_reason":"max_tokens"}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"Partial"}]},"finishReason":"MAX_TOKENS"}]}"#,
            #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"Partial"}]}]}"#,
        ]
        for json in truncated {
            let data = Data(json.utf8)
            #expect(throws: RemoteProviderServiceError.self) {
                try RemoteProviderService.validateCompleteOutput(data, required: true)
            }
            try RemoteProviderService.validateCompleteOutput(data, required: false)
        }
        for json in [#"{"choices":[{"finish_reason":"stop"}]}"#,
            #"{"candidates":[{"finishReason":"STOP"}]}"#, #"{"status":"completed"}"#]
        {
            try RemoteProviderService.validateCompleteOutput(Data(json.utf8), required: true)
        }
    }
}
