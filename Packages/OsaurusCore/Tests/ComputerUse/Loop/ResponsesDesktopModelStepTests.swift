import Foundation
import Testing

@testable import OsaurusCore

@Suite("Desktop typed Responses model steps", .serialized, .timeLimit(.minutes(1)))
struct ResponsesDesktopModelStepTests: Sendable {
    private struct Script: Sendable {
        var events: [ResponsesGenerationEvent]
        var error: NSError? = nil
    }
    private actor Engine: ResponsesEngineProtocol {
        let scripts: [Script]
        private(set) var requests: [ResponsesInferenceRequest] = []
        init(_ scripts: [Script]) { self.scripts = scripts }
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            let index = requests.count
            requests.append(request)
            guard index < scripts.count else { throw NSError(domain: "unexpected-replay", code: 999) }
            let script = scripts[index]
            return AsyncThrowingStream { continuation in
                for event in script.events { continuation.yield(event) }
                if let error = script.error { continuation.finish(throwing: error) }
                // A successful logical completion deliberately has no EOF.
                // The desktop path must not wait for the producer's cache tail.
            }
        }
    }
    private let raw: JSONValue = .object([
        "type": .string("message"), "id": .string("msg_desktop"),
        "phase": .string("commentary"), "future": .object(["kept": .bool(true)]),
    ])
    private func call(_ name: String, id: String = "call_original") -> ResponsesFunctionCall {
        ResponsesFunctionCall(
            id: "fc_original", callID: id, name: name, arguments: "{\"fixture\":true}",
            geminiThoughtSignature: "original-signature"
        )
    }
    private func row(
        calls: [ResponsesFunctionCall], text: String = "Checking the original action.",
        status: ResponsesGenerationCompletion.Status = .completed,
        stop: String = "stop", unclosed: Bool = false, measured: Bool = true
    ) -> Script {
        var events: [ResponsesGenerationEvent] = [
            .reasoningDelta("Original model reasoning."), .outputTextDelta(text),
            .providerOutputItem(raw), .reasoningItem(.init(id: "rs_original", encryptedContent: "opaque")),
        ]
        if measured { events.insert(.inputTokenCount(70), at: 0) }
        events.append(.responseCompleted(.init(
            responseID: "resp_original", status: status, functionCalls: calls,
            tokenCount: measured ? 13 : nil, tokensPerSecond: measured ? 31.123456789 : nil,
            unclosedReasoning: unclosed, stopReason: stop, promptTokensPerSecond: nil, mtp: nil
        )))
        return Script(events: events)
    }
    private func feed() -> SubagentFeed {
        SubagentFeed(toolCallId: UUID().uuidString, kindId: "desktop-fixture", title: "No desktop IO")
    }

    @Test func computerUseKeepsCanonicalControlsAndExactHistory() async throws {
        let engine = Engine([row(calls: [call(AgentAction.toolName)]), row(calls: [call(AgentAction.toolName)])])
        let first = try await ComputerUseLoop.modelStep(
            engine: engine, modelId: "fixture-model", sessionId: "session", messages: [ChatMessage(role: "user", content: "inspect")],
            enableThinking: nil, reasoningEffort: nil
        )
        #expect(first.call?.id == "call_original")
        #expect(first.tokens == 83 && first.inputTokenCount == 70 && first.outputTokenCount == 13)
        #expect(first.tokensPerSecond == 31.123456789)
        let assistant = try #require(first.assistantMessage)
        #expect(assistant.reasoning_content == "Original model reasoning.")
        #expect(assistant.reasoning_item_id == "rs_original" && assistant.reasoning_encrypted == "opaque")
        #expect(assistant.responses_output_items == [raw])
        #expect(assistant.tool_calls?.first?.geminiThoughtSignature == "original-signature")
        _ = try await ComputerUseLoop.modelStep(
            engine: engine, modelId: "fixture-model", sessionId: "session",
            messages: [assistant, ChatMessage(role: "tool", content: "actual-result", tool_calls: nil, tool_call_id: "call_original")],
            enableThinking: nil, reasoningEffort: nil
        )
        let requests = await engine.requests
        #expect(requests.count == 2)
        #expect(requests[0].generation.temperature == nil && requests[0].generation.topP == nil)
        #expect(requests[0].generation.topK == nil && requests[0].generation.maxOutputTokens == nil)
        #expect(requests[0].context.samplingParametersAreImplicit && requests[0].context.isAgentRequest)
        #expect(requests[0].sessionID == "session")
        #expect(requests[1].input.first?.responses_output_items == [raw])
        #expect(requests[1].input.first?.reasoning_content == assistant.reasoning_content)
        #expect(requests[1].input.last?.tool_call_id == "call_original")
    }

    @Test func positionCeilingTravelsOnEveryRequest() async throws {
        let engine = Engine([row(calls: [call(AgentAction.toolName)]), row(calls: [call(AgentAction.toolName)])])
        _ = try await ComputerUseLoop.modelStep(
            engine: engine, modelId: "fixture", sessionId: "s", messages: [],
            enableThinking: nil, reasoningEffort: nil, positionLimit: 16_384
        )
        _ = try await ComputerUseLoop.modelStep(
            engine: engine, modelId: "fixture", sessionId: "s", messages: [],
            enableThinking: nil, reasoningEffort: nil
        )
        let requests = await engine.requests
        #expect(requests[0].context.admissionPositionLimit == 16_384)
        // An implicit output budget is fitted into the ceiling, not reserved whole.
        #expect(requests[0].generation.maxOutputTokens == nil)
        #expect(requests[1].context.admissionPositionLimit == nil)
    }

    @Test func unsupportedCallsAreNotSelectedOrRenamed() async {
        let expected = AgentAction.toolName
        for calls in [[call("wrong_tool")], [call(expected), call(expected, id: "second_call")], [call(expected, id: "")]] {
            let engine = Engine([row(calls: calls)])
            await #expect(throws: DesktopResponsesModelStep.InvalidResponse.self) {
                _ = try await ComputerUseLoop.modelStep(engine: engine, modelId: "fixture", sessionId: "s", messages: [], enableThinking: nil, reasoningEffort: nil)
            }
            #expect(await engine.requests.count == 1)
        }
    }

    @Test func incompleteLengthUnclosedAndCancelledDoNotBecomeActions() async {
        let expected = AgentAction.toolName
        let scripts = [
            row(calls: [call(expected)], status: .incomplete, stop: "length"),
            row(calls: [call(expected)], status: .completed, stop: "length"),
            row(calls: [call(expected)], unclosed: true),
            row(calls: [call(expected)], status: .cancelled),
        ]
        for script in scripts {
            let engine = Engine([script])
            await #expect(throws: DesktopResponsesModelStep.InvalidResponse.self) {
                _ = try await ComputerUseLoop.modelStep(engine: engine, modelId: "fixture", sessionId: "s", messages: [], enableThinking: nil, reasoningEffort: nil)
            }
        }
    }

    @Test func missingRequiredCallKeeps422() async throws {
        let computer = Engine([row(calls: [], text: "No action.")])
        do {
            _ = try await ComputerUseLoop.modelStep(engine: computer, modelId: "fixture", sessionId: "s", messages: [], enableThinking: nil, reasoningEffort: nil)
            Issue.record("Missing required call must throw")
        } catch {
            let error = error as NSError
            #expect(error.domain == "OsaurusToolChoice" && error.code == 422)
            let diagnostic = error.userInfo[NSUnderlyingErrorKey] as? DesktopResponsesModelStep.InvalidResponse
            #expect(diagnostic?.response.completion.responseID == "resp_original")
        }
    }

    @Test func retryIsOnlyTransientAndBeforeAnyOutput() async throws {
        let transient = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        let engine = Engine([Script(events: [], error: transient), row(calls: [call(AgentAction.toolName)])])
        let attempt = DesktopResponsesAttempt()
        let result = try await ComputerUseLoop.runModelStep({
            try await ComputerUseLoop.modelStep(engine: engine, modelId: "fixture", sessionId: "s", messages: [], enableThinking: nil, reasoningEffort: nil, attempt: attempt)
        }, timeout: 0, maxRetries: 2, feed: feed(), step: 1,
            shouldRetry: { attempt.permitsRetry($0) })
        #expect(result.call?.id == "call_original")
        #expect(await engine.requests.count == 2)

        for script in [
            Script(events: [.outputTextDelta("partial")], error: transient),
            Script(events: [.reasoningDelta("partial reasoning")], error: transient),
            Script(events: [], error: NSError(domain: "HTTP", code: 401)),
            Script(events: [], error: NSError(domain: "HTTP", code: 429)),
            Script(events: [], error: NSError(domain: "OsaurusToolChoice", code: 422)),
        ] {
            let failedEngine = Engine([script, row(calls: [call(AgentAction.toolName)])])
            let failedAttempt = DesktopResponsesAttempt()
            do {
                _ = try await ComputerUseLoop.runModelStep({
                    try await ComputerUseLoop.modelStep(engine: failedEngine, modelId: "fixture", sessionId: "s", messages: [], enableThinking: nil, reasoningEffort: nil, attempt: failedAttempt)
                }, timeout: 0, maxRetries: 2, feed: feed(), step: 1,
                    shouldRetry: { failedAttempt.permitsRetry($0) })
                Issue.record("A non-retryable model error must propagate")
            } catch {}
            #expect(await failedEngine.requests.count == 1)
        }
    }
}
