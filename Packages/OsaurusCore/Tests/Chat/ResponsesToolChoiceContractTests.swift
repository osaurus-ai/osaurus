import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite("Canonical whole-response tool choice", .serialized, .timeLimit(.minutes(1)))
struct ResponsesToolChoiceContractTests {
    private final class Capture: Sendable {
        let calls = OSAllocatedUnfairLock(initialState: 0)
    }
    private struct Service: ResponsesGenerationService {
        let events: [ResponsesGenerationEvent]
        let capture: Capture
        var id: String { "choice-fixture" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?) async throws -> String {
            throw NSError(domain: "unexpected-legacy", code: 1)
        }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error> {
            throw NSError(domain: "unexpected-legacy", code: 2)
        }
        func streamResponses(messages: [ChatMessage], parameters: GenerationParameters, stopSequences: [String], tools: [Tool], toolChoice: ToolChoiceOption?, requestedModel: String?) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            capture.calls.withLock { $0 += 1 }
            return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
        }
    }
    private func tool(_ name: String) -> Tool {
        Tool(type: "function", function: .init(name: name, description: nil, parameters: .object(["type": .string("object")])))
    }
    private func call(_ name: String, id: String) -> ResponsesFunctionCall {
        .init(id: "fc_" + id, callID: id, name: name, arguments: #"{"count":"7"}"#)
    }
    private func completion(_ calls: [ResponsesFunctionCall] = [], status: ResponsesGenerationCompletion.Status = .completed) -> ResponsesGenerationEvent {
        .responseCompleted(.init(responseID: "resp_choice", status: status, functionCalls: calls,
            tokenCount: 7, tokensPerSecond: 41, unclosedReasoning: false,
            stopReason: status == .incomplete ? "length" : "stop", promptTokensPerSecond: nil, mtp: nil))
    }
    private func request(_ choice: ToolChoiceOption?) -> ResponsesInferenceRequest {
        var value = ResponsesInferenceRequest(model: "choice-fixture", input: [.init(role: "user", content: "original user text")])
        value.tools = [tool("target"), tool("other")]
        value.toolChoice = choice
        return value
    }
    private func engine(_ events: [ResponsesGenerationEvent], _ capture: Capture) -> ChatEngine {
        ChatEngine(services: [Service(events: events, capture: capture)], installedModelsProvider: { [] }, remoteServicesProvider: { [] })
    }

    @Test(arguments: [false, true])
    func requiredAndNamedPlainTextCannotBecomeSuccessfulCompletion(_ named: Bool) async throws {
        let capture = Capture()
        let choice: ToolChoiceOption = named ? .function(.init(type: "function", function: .init(name: "target"))) : .required
        let engine = engine([.outputTextDelta("actual diagnostic text"), completion()], capture)
        do {
            _ = try await engine.completeResponse(request: request(choice), endAt: .streamEnd)
            Issue.record("Missing required call became success")
        } catch {
            #expect((error as NSError).domain == "OsaurusToolChoice" && (error as NSError).code == 422)
        }
        #expect(capture.calls.withLock { $0 } == 1)
    }

    @Test func namedChoiceRejectsWrongSiblingBeforeWholeBatchDispatch() async throws {
        let capture = Capture()
        let events: [ResponsesGenerationEvent] = [completion([call("target", id: "first"), call("other", id: "second")])]
        let choice = ToolChoiceOption.function(.init(type: "function", function: .init(name: "target")))
        do {
            _ = try await engine(events, capture).completeResponse(request: request(choice))
            Issue.record("Wrong sibling was accepted")
        } catch { #expect((error as NSError).code == 422) }
        #expect(capture.calls.withLock { $0 } == 1)
    }

    @Test func namedBatchKeepsAllActualIDsAndArguments() async throws {
        let capture = Capture()
        let choice = ToolChoiceOption.function(.init(type: "function", function: .init(name: "target")))
        let result = try await engine([completion([call("target", id: "first"), call("target", id: "second")])], capture)
            .completeResponse(request: request(choice))
        #expect(result.completion.functionCalls.map(\.callID) == ["first", "second"])
        #expect(result.completion.functionCalls.map(\.arguments) == [#"{"count":"7"}"#, #"{"count":"7"}"#])
    }

    @Test func noSchemaFailsBeforeAnyServiceRequest() async throws {
        let capture = Capture()
        var request = request(.required)
        request.tools = nil
        do {
            _ = try await engine([completion()], capture).completeResponse(request: request)
            Issue.record("Missing schema started inference")
        } catch { #expect((error as NSError).code == 422) }
        #expect(capture.calls.withLock { $0 } == 0)
    }

    @Test func responsesNativeNoneDoesNotCollapseToUnspecified() async throws {
        let capture = Capture()
        var request = request(.auto)
        request.providerOptions = .init(toolChoice: OpenResponsesToolChoice.none)
        do {
            _ = try await engine([completion([call("target", id: "first")])], capture).completeResponse(request: request)
            Issue.record("tool_choice none accepted a call")
        } catch { #expect((error as NSError).code == 422) }
        #expect(capture.calls.withLock { $0 } == 1)
    }

    @Test(arguments: [ResponsesGenerationCompletion.Status.incomplete, .cancelled])
    func incompleteAndCancellationKeepTheirActualStatus(_ status: ResponsesGenerationCompletion.Status) async throws {
        let capture = Capture()
        let result = try await engine([completion(status: status)], capture).completeResponse(request: request(.required))
        #expect(result.completion.status == status)
    }

    @Test func rawSuccessTerminalCannotEscapeBeforeChoiceValidation() async throws {
        let raw: JSONValue = .object(["type": .string("response.completed"), "sequence_number": .number(3),
            "response": .object(["id": .string("resp_choice"), "status": .string("completed")])])
        let upstream = AsyncThrowingStream<ResponsesGenerationEvent, Error> { c in
            c.yield(.providerEvent(raw)); c.yield(completion()); c.finish()
        }
        var nativeSuccesses = 0, portableSuccesses = 0
        do {
            for try await event in ResponsesToolChoiceContract.enforce(upstream, request: request(.required)) {
                if case .providerEvent = event { nativeSuccesses += 1 }
                if case .responseCompleted = event { portableSuccesses += 1 }
            }
            Issue.record("Invalid native completed terminal escaped")
        } catch { #expect((error as NSError).code == 422) }
        #expect(nativeSuccesses == 0 && portableSuccesses == 0)
    }

    @Test func requiredHostedCallIsNotMistakenForMissingFunction() async throws {
        var request = request(.required)
        request.tools = nil
        let declaration = try JSONDecoder().decode(OpenResponsesTool.self, from: Data(#"{"type":"web_search"}"#.utf8))
        request.providerOptions = .init(tools: [declaration], toolChoice: .required)
        try ResponsesToolChoiceContract.preflight(request)
        let raw: JSONValue = .object(["type": .string("web_search_call"), "id": .string("ws_actual"), "status": .string("completed")])
        let upstream = AsyncThrowingStream<ResponsesGenerationEvent, Error> { c in
            c.yield(.providerOutputItem(raw)); c.yield(completion()); c.finish()
        }
        let result = try await ResponsesGenerationResult.collect(ResponsesToolChoiceContract.enforce(upstream, request: request))
        #expect(result.providerOutputItems == [raw])
        #expect(result.completion.functionCalls.isEmpty)
    }

    @Test func requestedMCPApprovalRemainsPendingConsentRatherThanMissingCall() async throws {
        var request = request(.required)
        request.tools = nil
        let declaration = try JSONDecoder().decode(OpenResponsesTool.self,
            from: Data(#"{"type":"mcp","server_label":"fixture","server_url":"https://example.invalid/mcp"}"#.utf8))
        request.providerOptions = .init(tools: [declaration], toolChoice: .required)
        let approval: JSONValue = .object(["type": .string("mcp_approval_request"), "id": .string("approval_actual"),
            "name": .string("read"), "arguments": .string("{}"), "server_label": .string("fixture")])
        let upstream = AsyncThrowingStream<ResponsesGenerationEvent, Error> { c in
            c.yield(.providerOutputItem(approval)); c.yield(completion()); c.finish()
        }
        let result = try await ResponsesGenerationResult.collect(ResponsesToolChoiceContract.enforce(upstream, request: request))
        #expect(result.providerOutputItems == [approval])
        #expect(result.completion.functionCalls.isEmpty)
    }

    @Test func validNativeSuccessRetainsItsOriginalOrderAndIdentity() async throws {
        let raw: JSONValue = .object(["type": .string("response.completed"), "sequence_number": .number(3),
            "response": .object(["id": .string("resp_choice"), "status": .string("completed")])])
        let upstream = AsyncThrowingStream<ResponsesGenerationEvent, Error> { c in
            c.yield(.providerEvent(raw)); c.yield(completion([call("target", id: "first")])); c.yield(.drained); c.finish()
        }
        var observed: [String] = []
        for try await event in ResponsesToolChoiceContract.enforce(upstream, request: request(.required)) {
            switch event {
            case .providerEvent(let value): #expect(value == raw); observed.append("native")
            case .responseCompleted: observed.append("completion")
            case .drained: observed.append("drained")
            default: break
            }
        }
        #expect(observed == ["native", "completion", "drained"])
    }

}
