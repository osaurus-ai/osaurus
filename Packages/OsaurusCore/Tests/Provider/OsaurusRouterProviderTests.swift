import Foundation
import Testing

@testable import OsaurusCore

struct OsaurusRouterProviderTests {
    @Test func routerAndPeerOsaurusUseDifferentChatEndpoints() {
        #expect(RemoteProviderType.osaurus.chatEndpoint == "/run")
        #expect(RemoteProviderType.osaurusRouter.chatEndpoint == "/v1/chat/completions")
    }

    @Test func routerModelDiscovery_hidesStalePricedModels() throws {
        let data = Data(
            """
            {"data":[
              {"id":"venice/model-a","provider":"venice","context_length":131072,"capabilities":{"tools":true},"input_micro_per_mtok":"2000000","output_micro_per_mtok":"4000000","input_display":"$2.00/M","output_display":"$4.00/M","stale":true},
              {"id":"venice/model-b","provider":"venice","context_length":131072,"capabilities":{"tools":false},"input_micro_per_mtok":"1000000","output_micro_per_mtok":"3000000","input_display":"$1.00/M","output_display":"$3.00/M","stale":false}
            ]}
            """.utf8
        )

        let discovery = try RemoteProviderService.decodeOsaurusRouterModelsDiscovery(data: data)
        #expect(discovery.models == ["venice/model-b"])
        #expect(discovery.totalCount == 2)
        #expect(discovery.staleCount == 1)
    }

    @Test func routerSummaryFrame_isConsumedWithoutFinishingStream() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        _ = stream

        let shouldFinish = RemoteProviderService.processEventPayload(
            #"{"osaurus":{"cost_micro":"1234","status":"completed","token_source":"provider","input_tokens":11,"output_tokens":3}}"#,
            state: &state,
            providerType: .osaurusRouter,
            tools: [],
            continuation: continuation
        )

        #expect(shouldFinish == false)
    }

    @Test func routerMinimalOpenAIChunk_yieldsVisibleContent() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(#"{"choices":[{"delta":{"content":"hello"}}]}"#.utf8),
            providerType: .osaurusRouter,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .continue = outcome else {
            Issue.record("Expected stream parser to continue, got \(outcome)")
            return
        }
        #expect(yielded == ["hello"])
    }

    @Test func routerUsageOnlyChunk_isIgnoredWithoutParseWarning() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(#"{"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#.utf8),
            providerType: .osaurusRouter,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .continue = outcome else {
            Issue.record("Expected usage-only chunk to continue, got \(outcome)")
            return
        }
        #expect(yielded.isEmpty)
    }

    @Test func routerToolCallDeltas_accumulateAndFinishWithInvocation() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let firstOutcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(
                """
                {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}
                """.utf8
            ),
            providerType: .osaurusRouter,
            state: &state,
            yield: { yielded.append($0) }
        )
        guard case .continue = firstOutcome else {
            Issue.record("Expected first tool-call delta to continue, got \(firstOutcome)")
            return
        }

        let argsOutcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(
                """
                {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\\"city\\\":\\\"Irvine\\\"}"}}]}}]}
                """.utf8
            ),
            providerType: .osaurusRouter,
            state: &state,
            yield: { yielded.append($0) }
        )
        guard case .continue = argsOutcome else {
            Issue.record("Expected args delta to continue, got \(argsOutcome)")
            return
        }

        let finishOutcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#.utf8),
            providerType: .osaurusRouter,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .finishWithToolCall(let invocation) = finishOutcome else {
            Issue.record("Expected tool-call finish, got \(finishOutcome)")
            return
        }
        #expect(invocation.toolName == "get_weather")
        #expect(invocation.toolCallId == "call_1")
        #expect(invocation.jsonArguments == #"{"city":"Irvine"}"#)
        #expect(yielded.contains { StreamingToolHint.decode($0) == "get_weather" })
    }

    @Test func routerSummaryThenDone_finishesNormally() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        _ = stream

        let summaryShouldFinish = RemoteProviderService.processEventPayload(
            #"{"osaurus":{"cost_micro":"1234","status":"completed","token_source":"provider","input_tokens":11,"output_tokens":3}}"#,
            state: &state,
            providerType: .osaurusRouter,
            tools: [],
            continuation: continuation
        )
        let doneShouldFinish = RemoteProviderService.processEventPayload(
            "[DONE]",
            state: &state,
            providerType: .osaurusRouter,
            tools: [],
            continuation: continuation
        )

        #expect(summaryShouldFinish == false)
        #expect(doneShouldFinish == true)
    }
}
