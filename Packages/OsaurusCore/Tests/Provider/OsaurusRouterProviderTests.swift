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

        // The catalog keeps full metadata for fresh models only, keyed by id.
        #expect(discovery.catalog.count == 1)
        #expect(discovery.catalog["venice/model-a"] == nil)
        let fresh = try #require(discovery.catalog["venice/model-b"])
        #expect(fresh.provider == "venice")
        #expect(fresh.inputDisplay == "$1.00/M")
        #expect(fresh.outputDisplay == "$3.00/M")
        #expect(fresh.contextLength == 131072)
    }

    @Test func routerModelPickerDescription_summarizesProviderPricingContext() throws {
        let data = Data(
            """
            {"data":[
              {"id":"venice/model-b","provider":"venice","context_length":131072,"capabilities":{"tools":true,"vision":true},"input_micro_per_mtok":"1000000","output_micro_per_mtok":"3000000","input_display":"$1.00/M","output_display":"$3.00/M","stale":false}
            ]}
            """.utf8
        )
        let discovery = try RemoteProviderService.decodeOsaurusRouterModelsDiscovery(data: data)
        let model = try #require(discovery.catalog["venice/model-b"])

        #expect(model.pickerDescription == "venice · $1.00/M in · $3.00/M out · 131K ctx")
        #expect(model.supportsVision == true)

        // The factory mirrors `fromRemoteModel` for the display name (last path
        // component of the prefixed id) and surfaces the summary as `description`.
        let providerId = UUID()
        let item = ModelPickerItem.fromOsaurusRouterModel(
            prefixedId: "osaurus/venice/model-b",
            providerName: "Osaurus",
            providerId: providerId,
            metadata: model
        )
        #expect(item.id == "osaurus/venice/model-b")
        #expect(item.displayName == "model-b")
        #expect(item.description == "venice · $1.00/M in · $3.00/M out · 131K ctx")
        #expect(item.isVLM == true)
        guard case .remote(let name, let pid) = item.source else {
            Issue.record("Expected a remote source, got \(item.source)")
            return
        }
        #expect(name == "Osaurus")
        #expect(pid == providerId)
    }

    @Test func routerModelContextLength_formatsCompactly() {
        #expect(OsaurusRouterModel.formatContextLength(131072) == "131K")
        #expect(OsaurusRouterModel.formatContextLength(8000) == "8K")
        #expect(OsaurusRouterModel.formatContextLength(1_000_000) == "1M")
        #expect(OsaurusRouterModel.formatContextLength(512) == "512")
        #expect(OsaurusRouterModel.formatContextLength(0) == nil)
    }

    @Test func routerModelPickerDescription_omitsMissingPieces() throws {
        // A model with no provider, blank pricing, and zero context should not
        // emit empty separators or a dangling "ctx".
        let data = Data(
            """
            {"data":[
              {"id":"bare/model","provider":"","context_length":0,"capabilities":null,"input_micro_per_mtok":"0","output_micro_per_mtok":"0","input_display":"","output_display":"","stale":false}
            ]}
            """.utf8
        )
        let discovery = try RemoteProviderService.decodeOsaurusRouterModelsDiscovery(data: data)
        let model = try #require(discovery.catalog["bare/model"])
        #expect(model.pickerDescription == nil)
        #expect(model.supportsVision == false)
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

    @Test func routerErrorEvent_finishesWithErrorInsteadOfEmptySuccess() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(#"{"error":{"code":"PROVIDER_ERROR","message":"provider failed upstream"}}"#.utf8),
            providerType: .osaurusRouter,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .finishWithError(let error) = outcome else {
            Issue.record("Expected router error event to finish with error, got \(outcome)")
            return
        }
        #expect(error.localizedDescription.contains("provider failed upstream"))
        #expect(yielded.isEmpty)
    }

    @Test func routerFullChatCompletionBody_yieldsVisibleContentAndFinishes() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(
                """
                {"id":"chatcmpl_1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"hello from full body"},"finish_reason":"stop"}]}
                """.utf8
            ),
            providerType: .osaurusRouter,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .finishNormal = outcome else {
            Issue.record("Expected full router body to finish normally, got \(outcome)")
            return
        }
        #expect(yielded == ["hello from full body"])
    }

    @Test func routerOneShotChatCompletion_preservesOpenAICompatibleToolCalls() throws {
        let (content, toolCalls) = try RemoteProviderService.parseResponse(
            Data(
                """
                {
                  "id":"chatcmpl_1",
                  "object":"chat.completion",
                  "created":0,
                  "model":"venice/minimax-m3",
                  "choices":[{
                    "index":0,
                    "message":{
                      "role":"assistant",
                      "content":null,
                      "tool_calls":[{
                        "id":"call_1",
                        "type":"function",
                        "function":{"name":"sandbox_write_file","arguments":"{\\\"path\\\":\\\"tetris.html\\\",\\\"content\\\":\\\"<html></html>\\\"}"}
                      }]
                    },
                    "finish_reason":"tool_calls"
                  }],
                  "usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}
                }
                """.utf8
            ),
            providerType: .osaurusRouter
        )

        #expect(content == nil)
        let call = try #require(toolCalls?.first)
        #expect(call.id == "call_1")
        #expect(call.function.name == "sandbox_write_file")
        #expect(call.function.arguments == #"{"path":"tetris.html","content":"<html></html>"}"#)
    }

    /// The router is streaming-only, so `generateOneShot` (distillation, greetings,
    /// preflight) drains `streamDeltas` via `collectVisibleText`. The drain must
    /// return only model text and drop every `\u{FFFE}` hint sentinel
    /// (reasoning/billing/tool/prefill/stats) so they never pollute the result —
    /// e.g. the distill JSON the memory pipeline parses.
    @Test func routerOneShotStream_collectsVisibleTextAndDropsSentinels() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        continuation.yield(StreamingReasoningHint.encode("thinking about the digest"))
        continuation.yield(#"{"episode":"#)
        continuation.yield(
            StreamingBillingHint.encode(
                RouterBillingSummary(
                    costMicro: "1234",
                    status: "completed",
                    tokenSource: "provider",
                    inputTokens: 11,
                    outputTokens: 3
                )
            )
        )
        continuation.yield(#"{"summary":"hi"}}"#)
        continuation.yield(StreamingToolHint.encode("search_memory"))
        continuation.finish()

        let result = try await RemoteProviderService.collectVisibleText(from: stream)
        #expect(result == #"{"episode":{"summary":"hi"}}"#)
    }

    /// A stream that carries only sentinels (a reasoning model that never emits
    /// visible content) collects to empty rather than leaking sentinel text.
    @Test func routerOneShotStream_sentinelOnlyCollectsEmpty() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield(StreamingReasoningHint.encode("only thinking, no answer"))
        continuation.yield(StreamingToolHint.encode("noop"))
        continuation.finish()

        let result = try await RemoteProviderService.collectVisibleText(from: stream)
        #expect(result.isEmpty)
    }

    @Test func routerFullChatCompletionBodyWithToolCall_finishesWithInvocation() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(
                """
                {
                  "id":"chatcmpl_1",
                  "object":"chat.completion",
                  "choices":[{
                    "index":0,
                    "message":{
                      "role":"assistant",
                      "content":null,
                      "tool_calls":[{
                        "index":0,
                        "id":"call_1",
                        "type":"function",
                        "function":{"name":"sandbox_write_file","arguments":"{\\\"path\\\":\\\"tetris.html\\\",\\\"content\\\":\\\"<html></html>\\\"}"}
                      }]
                    },
                    "finish_reason":"tool_calls"
                  }]
                }
                """.utf8
            ),
            providerType: .osaurusRouter,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .finishWithToolCall(let invocation) = outcome else {
            Issue.record("Expected full router body tool call, got \(outcome)")
            return
        }
        #expect(invocation.toolName == "sandbox_write_file")
        #expect(invocation.toolCallId == "call_1")
        #expect(invocation.jsonArguments == #"{"path":"tetris.html","content":"<html></html>"}"#)
        #expect(yielded.contains { StreamingToolHint.decode($0) == "sandbox_write_file" })
    }

    @Test func routerRawJSONLine_isTreatedAsEventPayload() {
        var eventData = ""

        RemoteProviderService.processSSELine(
            Data(#"{"choices":[{"message":{"role":"assistant","content":"raw"}}]}"#.utf8),
            providerType: .osaurusRouter,
            into: &eventData
        )

        #expect(eventData == #"{"choices":[{"message":{"role":"assistant","content":"raw"}}]}"#)
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

    @Test func routerSummaryFrame_yieldsBillingHintOnStream() async throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        state.routerRequestId = "run-abc:1"
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let shouldFinish = RemoteProviderService.processEventPayload(
            #"{"osaurus":{"cost_micro":"1234","status":"completed","token_source":"provider","input_tokens":11,"output_tokens":3}}"#,
            state: &state,
            providerType: .osaurusRouter,
            tools: [],
            continuation: continuation
        )
        continuation.finish()

        // The summary is consumed (doesn't finish the stream) AND surfaced as a
        // billing hint so the chat layer can record the charge + ledger row.
        #expect(shouldFinish == false)

        var decodedBilling: RouterBillingSummary?
        for try await delta in stream {
            if let billing = StreamingBillingHint.decode(delta) {
                decodedBilling = billing
            }
        }
        let billing = try #require(decodedBilling, "summary frame must yield a billing hint")
        #expect(billing.costMicro == "1234")
        #expect(billing.status == "completed")
        #expect(billing.tokenSource == "provider")
        #expect(billing.inputTokens == 11)
        #expect(billing.outputTokens == 3)
        #expect(billing.requestId == "run-abc:1")
    }

    @Test func routerSummaryFrame_prefersServerRequestIdOverLocalFallback() async throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        state.routerRequestId = "run-abc:1"
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let shouldFinish = RemoteProviderService.processEventPayload(
            #"{"osaurus":{"request_id":"router-request-9","cost_micro":"1234","status":"completed","token_source":"provider","input_tokens":11,"output_tokens":3}}"#,
            state: &state,
            providerType: .osaurusRouter,
            tools: [],
            continuation: continuation
        )
        continuation.finish()

        #expect(shouldFinish == false)
        var decodedBilling: RouterBillingSummary?
        for try await delta in stream {
            decodedBilling = StreamingBillingHint.decode(delta) ?? decodedBilling
        }
        #expect(decodedBilling?.requestId == "router-request-9")
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

    @Test func routerDiagnostics_classifiesSummaryOnlyDone() {
        let diagnostics = routerDiagnosticsAfterProcessing(
            [
                #"{"osaurus":{"cost_micro":"1234","status":"completed","token_source":"provider","input_tokens":11,"output_tokens":3}}"#,
                "[DONE]",
            ]
        )

        #expect(diagnostics.emptyClassification == "summary-only")
        #expect(diagnostics.summaryCount == 1)
        #expect(diagnostics.billingHintDeltas == 1)
        #expect(diagnostics.doneMarkerCount == 1)
        #expect(diagnostics.shouldLogEmptyTerminal)
    }

    @Test func routerDiagnostics_classifiesUsageOnlyDone() {
        let diagnostics = routerDiagnosticsAfterProcessing(
            [
                #"{"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#,
                "[DONE]",
            ]
        )

        #expect(diagnostics.emptyClassification == "usage-only")
        #expect(diagnostics.usageOnlyCount == 1)
        #expect(diagnostics.doneMarkerCount == 1)
        #expect(diagnostics.modelOutputCount == 0)
        #expect(diagnostics.shouldLogEmptyTerminal)
    }

    @Test func routerDiagnostics_classifiesRawEmptyStream() {
        var state = routerDiagnosticsState()
        state.routerDiagnostics?.recordTerminal(
            marker: "stream-end",
            yieldedTextCount: state.yieldedTextCount,
            yieldedTextBytes: state.yieldedTextBytes,
            pendingToolSlots: state.accumulatedToolCalls.count,
            pendingEventBytes: 0
        )

        let diagnostics = state.routerDiagnostics!
        #expect(diagnostics.emptyClassification == "raw-empty")
        #expect(diagnostics.chunkCount == 0)
        #expect(diagnostics.eventCount == 0)
        #expect(diagnostics.shouldLogEmptyTerminal)
    }

    @Test func routerDiagnostics_classifiesContentEventAsNonEmpty() {
        let diagnostics = routerDiagnosticsAfterProcessing(
            [
                #"{"choices":[{"delta":{"content":"hello"}}]}"#,
                "[DONE]",
            ]
        )

        #expect(diagnostics.emptyClassification == "non-empty")
        #expect(diagnostics.visibleTextDeltas == 1)
        #expect(diagnostics.visibleTextBytes == 5)
        #expect(diagnostics.shouldLogEmptyTerminal == false)
    }

    @Test func routerDiagnostics_classifiesFullBodyToolCallAsNonEmpty() {
        let diagnostics = routerDiagnosticsAfterProcessing(
            [
                """
                {
                  "id":"chatcmpl_1",
                  "object":"chat.completion",
                  "choices":[{
                    "index":0,
                    "message":{
                      "role":"assistant",
                      "content":null,
                      "tool_calls":[{
                        "index":0,
                        "id":"call_1",
                        "type":"function",
                        "function":{"name":"sandbox_write_file","arguments":"{\\\"path\\\":\\\"tetris.html\\\"}"}
                      }]
                    },
                    "finish_reason":"tool_calls"
                  }]
                }
                """
            ]
        )

        #expect(diagnostics.emptyClassification == "non-empty")
        #expect(diagnostics.toolCallFinishes == 1)
        #expect(diagnostics.toolHintDeltas > 0)
        #expect(diagnostics.shouldLogEmptyTerminal == false)
    }

    @Test func routerDiagnostics_classifiesUnrecognizedEvent() {
        let diagnostics = routerDiagnosticsAfterProcessing(
            [
                #"{"unexpected":true}"#,
                "[DONE]",
            ]
        )

        #expect(diagnostics.emptyClassification == "unrecognized-events")
        #expect(diagnostics.unrecognizedEventCount == 1)
        #expect(diagnostics.lastEventSummary == "done-marker")
        #expect(diagnostics.recentEventSummaries.contains { $0.hasPrefix("object keys=") })
        #expect(diagnostics.shouldLogEmptyTerminal)
    }

    private func routerDiagnosticsState() -> RemoteProviderService.StreamingState {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        state.routerDiagnostics = RemoteProviderService.RouterStreamDiagnostics(
            model: "osaurus/minimax-m3",
            messageRoles: ["system", "user"],
            toolNames: ["sandbox_write_file"],
            toolChoice: "auto",
            idempotencyKeySuffix: "attempt-1",
            requestBodyBytes: 512
        )
        return state
    }

    private func routerDiagnosticsAfterProcessing(
        _ payloads: [String]
    ) -> RemoteProviderService.RouterStreamDiagnostics {
        var state = routerDiagnosticsState()
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        _ = stream

        for payload in payloads {
            let shouldFinish = RemoteProviderService.processEventPayload(
                payload,
                state: &state,
                providerType: .osaurusRouter,
                tools: [],
                continuation: continuation
            )
            if shouldFinish { break }
        }
        continuation.finish()
        return state.routerDiagnostics!
    }
}
