import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent evaluation typed Responses", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ResponsesAgentEvaluationStepTests {
    private actor Engine: ResponsesEngineProtocol {
        let scripts: [[ResponsesGenerationEvent]]
        let close: Bool
        let error: NSError?
        private(set) var requests: [ResponsesInferenceRequest] = []
        init(_ events: [ResponsesGenerationEvent], close: Bool = false, error: NSError? = nil) {
            self.scripts = [events]; self.close = close; self.error = error
        }
        init(scripts: [[ResponsesGenerationEvent]], close: Bool = false) {
            self.scripts = scripts; self.close = close; self.error = nil
        }
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            let index = requests.count
            requests.append(request)
            let events = scripts[min(index, scripts.count - 1)], close = self.close, error = self.error
            return AsyncThrowingStream { continuation in
                events.forEach { continuation.yield($0) }
                if let error { continuation.finish(throwing: error) }
                else if close { continuation.finish() }
            }
        }
    }
    private let item: JSONValue = .object([
        "type": .string("message"), "id": .string("msg_eval"), "phase": .string("commentary"),
        "future_field": .object(["kept": .bool(true)]),
    ])
    private func call(_ id: String) -> ResponsesFunctionCall {
        ResponsesFunctionCall(id: "fc_" + id, callID: id, name: "fixture", arguments: "{\"id\":\"\(id)\"}", geminiThoughtSignature: "sig_" + id)
    }
    private func row(
        calls: [ResponsesFunctionCall] = [], status: ResponsesGenerationCompletion.Status = .completed,
        stop: String = "stop", unclosed: Bool = false, measured: Bool = true,
        prefill: Double? = 900.123456789
    ) -> [ResponsesGenerationEvent] {
        var events: [ResponsesGenerationEvent] = [
            .outputTextDelta("Original answer."), .reasoningDelta("Original reasoning."),
            .providerOutputItem(item), .reasoningItem(.init(id: "rs_eval", encryptedContent: "opaque")),
        ]
        if measured { events.insert(.inputTokenCount(90), at: 0) }
        events.append(.responseCompleted(.init(
            responseID: "resp_eval", status: status, functionCalls: calls,
            tokenCount: measured ? 17 : nil, tokensPerSecond: measured ? 41.987654321 : nil,
            unclosedReasoning: unclosed, stopReason: stop,
            promptTokensPerSecond: measured ? prefill : nil, mtp: nil
        )))
        return events
    }
    private func collect(_ events: [ResponsesGenerationEvent]) async throws -> ResponsesGenerationResult {
        try await ResponsesEvaluationStep.collect(engine: Engine(events), request: ResponsesInferenceRequest(model: "fixture", input: []))
    }

    @Test func wholeBatchAndNativeReasoningAreRetainedAtLogicalCompletion() async throws {
        let response = try await collect(row(calls: [call("first"), call("second")]))
        let classification = try ResponsesEvaluationStep.classify(response, toolsWereOffered: true)
        guard case .toolCalls(let calls) = classification else {
            Issue.record("Whole completed batch must be dispatchable"); return
        }
        #expect(calls.map(\.toolCallId) == ["first", "second"])
        #expect(calls.map(\.geminiThoughtSignature) == ["sig_first", "sig_second"])
        let assistant = try response.completedAssistantInput()
        #expect(assistant.responses_output_items == [item])
        #expect(assistant.reasoning_content == "Original reasoning.")
        #expect(assistant.reasoning_item_id == "rs_eval" && assistant.reasoning_encrypted == "opaque")
        #expect(assistant.tool_calls?.map(\.id) == ["first", "second"])
        #expect(response.inputTokenCount == 90 && response.completion.tokenCount == 17)
        #expect(response.completion.tokensPerSecond == 41.987654321)
        #expect(response.completion.promptTokensPerSecond == 900.123456789)
    }

    @Test func incompleteUnclosedAndDuplicateIDsCannotDispatch() async throws {
        let length = try await collect(row(calls: [call("first")], status: .incomplete, stop: "length"))
        if case .lengthExhausted = try ResponsesEvaluationStep.classify(length, toolsWereOffered: true) {} else {
            Issue.record("Length must remain incomplete")
        }
        let unclosed = try await collect(row(calls: [call("first")], unclosed: true))
        if case .incompleteReasoning = try ResponsesEvaluationStep.classify(unclosed, toolsWereOffered: true) {} else {
            Issue.record("Unclosed reasoning must not dispatch")
        }
        for events in [
            row(status: .cancelled), row(status: .incomplete, stop: "other"),
            row(calls: [call("duplicate"), call("duplicate")]), row(calls: [call("")]),
        ] {
            let response = try await collect(events)
            #expect(throws: ResponsesEvaluationStep.Failure.self) {
                _ = try ResponsesEvaluationStep.classify(response, toolsWereOffered: true)
            }
        }
    }

    @Test func sparseUsageAndNaturallyCompletedWrapupStayDistinct() async throws {
        let response = try await collect(row(measured: false))
        #expect(response.inputTokenCount == nil && response.completion.tokenCount == nil)
        #expect(response.completion.tokensPerSecond == nil && response.completion.promptTokensPerSecond == nil)
        try ResponsesEvaluationStep.requireNaturalFinal(response)
        for events in [row(status: .incomplete, stop: "length"), row(status: .cancelled), row(calls: [call("tool")]), row(unclosed: true)] {
            let partial = try await collect(events)
            #expect(throws: ResponsesEvaluationStep.Failure.self) {
                try ResponsesEvaluationStep.requireNaturalFinal(partial)
            }
        }
    }

    @Test func cacheShapeFixtureIsExplicitAndDoesNotReplayContradictoryOpaqueItems() async throws {
        let response = try await collect(row(calls: [call("original_model_call")]))
        let fixture = CacheProofEvaluator.scriptedDiagnosticAssistant(response, calls: [ToolCall(
            id: "call_eval_probe_1", type: "function", function: ToolCallFunction(name: "eval_probe", arguments: "{\"step\":1}")
        )])
        #expect(fixture.tool_calls?.first?.id == "call_eval_probe_1")
        #expect(fixture.reasoning_content == "Original reasoning.")
        #expect(fixture.responses_output_items == nil)
        #expect(fixture.reasoning_item_id == nil && fixture.reasoning_encrypted == nil)
        #expect(response.completion.functionCalls.first?.callID == "original_model_call")
        #expect(response.providerOutputItems == [item])
    }

    @Test func missingCompletionAndFailedStreamEndRemainErrors() async throws {
        let empty = Engine([], close: true)
        do {
            _ = try await ResponsesEvaluationStep.collect(engine: empty, request: ResponsesInferenceRequest(model: "fixture", input: []))
            Issue.record("EOF without a terminal event must throw")
        } catch {}
        let cleanup = Engine(row(), error: NSError(domain: "fixture-cleanup", code: 7))
        do {
            _ = try await ResponsesEvaluationStep.collect(engine: cleanup, request: ResponsesInferenceRequest(model: "fixture", input: []), endAt: .streamEnd)
            Issue.record("Stream-end observation must surface cleanup failure")
        } catch {
            #expect((error as NSError).domain == "fixture-cleanup")
        }
    }

    @Test(arguments: [false, true])
    func actualAgentLoopAndCapabilityDriversUseBundleDefaultsAndSparseUsage(_ streaming: Bool) async throws {
        let agentEngine = Engine(row(measured: false))
        let transcript = await AgentLoopEvaluator.runConversation(
            task: "Fixture response with no tool execution", workspace: URL(fileURLWithPath: "/tmp"),
            agentId: UUID(), maxIterations: 1, model: "fixture-model", contextWindowOverride: 16384,
            streaming: streaming, useHostFolder: false, engine: agentEngine
        )
        #expect(transcript.error == nil && transcript.finalText == "Original answer.")
        #expect(transcript.completionTokens == nil && transcript.decodeTokensPerSecond == nil)
        let request = try #require(await agentEngine.requests.first)
        #expect(request.generation.temperature == nil && request.generation.maxOutputTokens == nil)
        #expect(request.generation.topP == nil && request.generation.topK == nil)
        #expect(request.context.samplingParametersAreImplicit)

        let claimsEngine = Engine(row(measured: false))
        let claims = await CapabilityClaimsEvaluator.runConversation(
            query: "Fixture response with no tool execution", agentId: UUID(), maxIterations: 1,
            model: "fixture-model", engine: claimsEngine
        )
        #expect(claims.error == nil && claims.finalText == "Original answer.")
        #expect(claims.completionTokens == nil && claims.decodeTokensPerSecond == nil)
        let claimsRequest = try #require(await claimsEngine.requests.first)
        #expect(claimsRequest.generation.maxOutputTokens == nil && claimsRequest.generation.temperature == nil)
    }

    @Test func cacheDriverPreservesNativeHistoryAndExplicitDiagnosticBudget() async throws {
        let engine = Engine(row(), close: true)
        let result = await CacheProofEvaluator.runConversation(
            queries: ["first", "second"], model: "fixture-model", maxTokens: 128, engine: engine
        )
        let requests = await engine.requests
        #expect(requests.count == 2)
        #expect(requests[0].generation.maxOutputTokens == 128)
        #expect(requests[0].generation.temperature == nil && requests[0].generation.topP == nil)
        let assistant = try #require(requests[1].input.first { $0.role == "assistant" })
        #expect(assistant.responses_output_items == [item])
        #expect(assistant.reasoning_content == "Original reasoning.")
        #expect(assistant.reasoning_item_id == "rs_eval" && assistant.reasoning_encrypted == "opaque")
        // No real MLX model is loaded. A missing-runtime skip is expected and
        // cannot turn these request/history assertions into cache-hit proof.
        #expect(result.visibleTurns.count == 2)
        #expect(result.turnMetrics?.count == 2)
        #expect(result.turnMetrics?.last?.modelResponseID == "resp_eval")
        #expect(result.turnMetrics?.last?.scriptedToolDiagnostic == false)
        #expect(result.turnMetrics?.last?.producerDrainStatus == "not_observed")
    }

    @Test func partialTerminalRowsDoNotReplayOrBecomeSuccessfulDriverAnswers() async {
        let engine = Engine(row(status: .cancelled))
        let result = await AgentLoopEvaluator.runConversation(
            task: "fixture", workspace: URL(fileURLWithPath: "/tmp"), agentId: UUID(),
            maxIterations: 1, model: "fixture-model", contextWindowOverride: 16384,
            useHostFolder: false, engine: engine
        )
        #expect(result.error != nil && result.exit == "errored")
        #expect(await engine.requests.count == 1)
        let claimsEngine = Engine(row(status: .incomplete, stop: "length"))
        let claims = await CapabilityClaimsEvaluator.runConversation(
            query: "fixture", agentId: UUID(), maxIterations: 1, model: "fixture-model", engine: claimsEngine
        )
        #expect(claims.error != nil)
        #expect(await claimsEngine.requests.count == 1)
    }

    @Test func laterCachedPrefillCannotFillMissingColdStepMeasurement() async throws {
        let engine = Engine(scripts: [row(calls: [call("fixture_call")], prefill: nil), row()])
        let result = await AgentLoopEvaluator.runConversation(
            task: "fixture", workspace: URL(fileURLWithPath: "/tmp"), agentId: UUID(),
            maxIterations: 2, model: "fixture-model", contextWindowOverride: 16384,
            useHostFolder: false, engine: engine
        )
        #expect(await engine.requests.count == 2)
        #expect(result.prefillTokensPerSecond == nil)
        let second = try #require((await engine.requests).last)
        let assistant = try #require(second.input.first { $0.role == "assistant" })
        #expect(assistant.responses_output_items == [item])
        #expect(assistant.tool_calls?.map(\.id) == ["fixture_call"])
        #expect(assistant.reasoning_content == "Original reasoning.")
    }


    @Test func cappedAndFailedCacheRowsKeepEvidenceAndCannotSkipHideTheError() async {
        for script in [row(status: .incomplete, stop: "length"), [.outputTextDelta("partial without terminal")]] {
            let engine = Engine(script, close: true)
            let result = await CacheProofEvaluator.runConversation(
                queries: ["first", "must not run"], model: "fixture-model", maxTokens: 128, engine: engine
            )
            #expect(await engine.requests.count == 1)
            #expect(result.error != nil && result.skipReason == nil)
            #expect(result.visibleTurns.count == 1 && result.turnMetrics?.count == 1)
        }
    }

}
