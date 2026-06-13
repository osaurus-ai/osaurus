import Foundation
import Testing

@testable import OsaurusCore

struct OsaurusRouterProviderTests {
    @Test func routerAndPeerOsaurusUseDifferentChatEndpoints() {
        #expect(RemoteProviderType.osaurus.chatEndpoint == "/run")
        #expect(RemoteProviderType.osaurusRouter.chatEndpoint == "/v1/chat/completions")
    }

    @Test func routerModelDiscovery_keepsStalePricedModelsVisible() throws {
        let data = Data(
            """
            {"data":[
              {"id":"venice/model-a","provider":"venice","context_length":131072,"capabilities":{"tools":true},"input_micro_per_mtok":"2000000","output_micro_per_mtok":"4000000","input_display":"$2.00/M","output_display":"$4.00/M","stale":true},
              {"id":"venice/model-b","provider":"venice","context_length":131072,"capabilities":{"tools":false},"input_micro_per_mtok":"1000000","output_micro_per_mtok":"3000000","input_display":"$1.00/M","output_display":"$3.00/M","stale":false}
            ]}
            """.utf8
        )

        let models = try RemoteProviderService.decodeOsaurusRouterModelsResponse(data: data)
        #expect(models == ["venice/model-a", "venice/model-b"])
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
}
