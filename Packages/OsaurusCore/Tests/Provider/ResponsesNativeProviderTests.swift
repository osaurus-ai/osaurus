import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite("Native Responses provider protocol", .serialized, .timeLimit(.minutes(2)))
struct ResponsesNativeProviderTests {
    private final class Capture: Sendable {
        let events = OSAllocatedUnfairLock(initialState: [ResponsesGenerationEvent]())
        func add(_ event: ResponsesGenerationEvent) { events.withLock { $0.append(event) } }
    }
    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }
    private func item() -> [String: Any] {
        ["type": "function_call", "id": "fc_native", "call_id": "call_native", "name": "lookup",
         "arguments": "{\"key\":\"a\"}", "status": "completed", "future": ["retained": true]]
    }
    private func terminal(status: String = "completed", usage: [String: Any]? = nil) throws -> String {
        var response: [String: Any] = ["id": "resp_actual", "status": status, "output": [item()]]
        if let usage { response["usage"] = usage }
        if status == "incomplete" { response["incomplete_details"] = ["reason": "max_output_tokens"] }
        return try json(["type": "response.\(status)", "sequence_number": 5, "response": response])
    }

    @Test func nativeLifecyclePrecedesProjectionsAndRetainsActualIDsSparseUsageAndItems() throws {
        let captured = Capture()
        let stream = RemoteResponsesNativeStream { captured.add($0) }
        #expect(try !stream.consume(json(["type": "response.created", "sequence_number": 0,
            "response": ["id": "resp_actual", "status": "in_progress"]])))
        #expect(try !stream.consume(json(["type": "response.output_item.done", "sequence_number": 4,
            "output_index": 2, "item": item()])))
        #expect(try stream.consume(terminal(usage: ["input_tokens": 93])))
        let events = captured.events.withLock { $0 }
        guard case .providerEvent(.object(let first)) = events.first else { Issue.record("native event must be first"); return }
        #expect(first["type"] == .string("response.created"))
        let items = events.compactMap { event -> JSONValue? in if case .providerOutputItem(let item) = event { return item }; return nil }
        #expect(items.count == 1, "done and terminal output cannot duplicate one Item")
        let completion = try #require(events.compactMap { event -> ResponsesGenerationCompletion? in
            if case .responseCompleted(let value) = event { return value }; return nil
        }.first)
        #expect(completion.responseID == "resp_actual")
        #expect(completion.functionCalls.first?.id == "fc_native")
        #expect(completion.functionCalls.first?.callID == "call_native")
        #expect(completion.inputTokenCount == 93)
        #expect(completion.tokenCount == nil && completion.tokensPerSecond == nil)
        #expect(events.firstIndex { if case .providerOutputItem = $0 { return true }; return false }!
            < events.firstIndex { if case .responseCompleted = $0 { return true }; return false }!)
    }

    @Test func incompleteCallsRemainNonExecutableAndUnmeasured() throws {
        let captured = Capture()
        let stream = RemoteResponsesNativeStream { captured.add($0) }
        #expect(try stream.consume(terminal(status: "incomplete")))
        let value = try #require(captured.events.withLock { $0 }.compactMap { event -> ResponsesGenerationCompletion? in
            if case .responseCompleted(let value) = event { return value }; return nil
        }.first)
        #expect(value.dispatchableFunctionCalls.isEmpty)
        #expect(value.stopReason == "length")
        #expect(value.tokenCount == nil && value.inputTokenCount == nil)
    }

    @Test(arguments: ["delta", "done", "terminal"])
    func actualRefusalIsVisibleExactlyOnceWithoutReplacingNativeItems(_ path: String) async throws {
        let captured = Capture()
        let stream = RemoteResponsesNativeStream { captured.add($0) }
        let refusal = "I cannot help with that request."
        let message: [String: Any] = ["type": "message", "id": "msg_refusal", "role": "assistant",
            "status": "completed", "content": [["type": "refusal", "refusal": refusal, "future": true]]]
        if path == "delta" {
            _ = try stream.consume(json(["type": "response.refusal.delta", "output_index": 0,
                "content_index": 0, "item_id": "msg_refusal", "delta": refusal]))
        }
        if path != "terminal" {
            _ = try stream.consume(json(["type": "response.refusal.done", "output_index": 0,
                "content_index": 0, "item_id": "msg_refusal", "refusal": refusal]))
            _ = try stream.consume(json(["type": "response.output_item.done", "output_index": 0, "item": message]))
        }
        _ = try stream.consume(json(["type": "response.completed", "response": ["id": "resp_refusal",
            "status": "completed", "output": [message]]]))
        let events = captured.events.withLock { $0 }
        let result = try await ResponsesGenerationResult.collect(AsyncThrowingStream { c in
            events.forEach { c.yield($0) }; c.finish()
        })
        #expect(result.text == refusal, "A real refusal must not appear empty to shared retry classification")
        #expect(result.completion.dispatchableFunctionCalls.isEmpty)
        #expect(result.providerOutputItems.count == 1)
        if case .object(let item) = result.providerOutputItems.first,
            case .array(let content) = item["content"], case .object(let part) = content.first {
            #expect(part["type"] == .string("refusal") && part["future"] == .bool(true))
        } else { Issue.record("Expected unchanged native refusal Item") }
        #expect(events.firstIndex { if case .providerEvent = $0 { return true }; return false }!
            < events.firstIndex { if case .outputTextDelta = $0 { return true }; return false }!)
    }

    @Test func textAndRefusalRailsRemainIndependent() throws {
        let captured = Capture()
        let stream = RemoteResponsesNativeStream { captured.add($0) }
        _ = try stream.consume(json(["type": "response.output_text.delta", "output_index": 0,
            "content_index": 0, "delta": "Actual text. "]))
        _ = try stream.consume(json(["type": "response.refusal.delta", "output_index": 0,
            "content_index": 0, "delta": "Actual refusal."]))
        let text = captured.events.withLock { $0 }.compactMap { event -> String? in
            if case .outputTextDelta(let value) = event { return value }; return nil
        }.joined()
        #expect(text == "Actual text. Actual refusal.")
    }

    @Test func unsupportedRouteClassifierNeverUsesModelAuthRateOrAmbiguousErrors() {
        let endpoint = URL(string: "https://example.test/v1/responses")!
        for (status, body) in [
            (404, "model_not_found"), (404, "Not Found"), (401, "Cannot POST /v1/responses"),
            (429, "unsupported_endpoint"), (503, "Cannot POST /v1/responses"),
            (400, #"{"error":{"code":"unsupported_endpoint","param":"model"}}"#),
        ] { #expect(!RemoteResponsesCapabilityFallback.isUnsupportedEndpoint(status: status, body: Data(body.utf8), endpoint: endpoint)) }
        #expect(RemoteResponsesCapabilityFallback.isUnsupportedEndpoint(status: 404,
            body: Data("Cannot POST /v1/responses".utf8), endpoint: endpoint))
    }

    @Test func nativeOptionsAndPreparedMediaMetadataReachTheActualBuiltBody() async throws {
        let service = RemoteProviderService(provider: provider(), models: ["fixture"], resolvedHeaders: [:])
        let tool = try JSONDecoder().decode(OpenResponsesTool.self, from: Data(#"{"type":"web_search","search_context_size":"low"}"#.utf8))
        let schema: JSONValue = .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
        let options = ResponsesProviderOptions(tools: [tool], toolChoice: .auto,
            reasoning: .init(effort: "low", summary: "auto", context: "all_turns"), store: false,
            include: ["reasoning.encrypted_content"], parallelToolCalls: false, metadata: ["fixture": "kept"],
            text: .init(format: .init(type: "json_schema", name: "reply", description: "fixture", schema: schema, strict: true)))
        var message = ChatMessage(role: "user", content: "prepared text",
            contentParts: [.imageUrl(url: "data:image/png;base64,cHJlcGFyZWQ=", detail: "low")])
        message.responses_output_items = [.object(["type": .string("message"), "role": .string("user"),
            "id": .string("msg_user"), "future": .string("retained"), "content": .string("STALE SECRET")])]
        let request = await service.buildChatRequest(messages: [message], parameters: .init(temperature: nil,
            maxTokens: 64, responsesProviderOptions: options), model: "fixture", stream: true, tools: nil, toolChoice: nil)
        let body = try await service.buildURLRequest(for: request).httpBody
        let data = try #require(body)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["tools"] as? [[String: Any]])?.first?["type"] as? String == "web_search")
        #expect(object["parallel_tool_calls"] as? Bool == false)
        #expect((object["reasoning"] as? [String: Any])?["context"] as? String == "all_turns")
        #expect((object["metadata"] as? [String: String])?["fixture"] == "kept")
        let input = try #require((object["input"] as? [[String: Any]])?.first)
        #expect(input["id"] as? String == "msg_user")
        #expect(input["future"] as? String == "retained")
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(encoded.contains("prepared text") && encoded.contains("cHJlcGFyZWQ="))
        #expect(!encoded.contains("STALE SECRET"))
        await service.invalidateSession()
    }

    private func provider() -> RemoteProvider {
        RemoteProvider(name: "wire-fixture", host: "responses-wire.test", providerProtocol: .https,
            port: nil, basePath: "/v1", authType: .none, providerType: .openResponses)
    }
    private func service() -> RemoteProviderService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesProviderURLProtocol.self]
        return RemoteProviderService(provider: provider(), models: ["fixture"], resolvedHeaders: [:],
            urlSession: URLSession(configuration: configuration))
    }
    private func sse(_ values: [String]) -> Data { Data(values.map { "data: \($0)\n\n" }.joined().utf8) }

    @Test func unsupportedResponsesEndpointFallsBackOnceBeforeOutputWithRealWireReceipts() async throws {
        let legacy = sse([#"{"id":"chat_actual","choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}"#, "[DONE]"])
        ResponsesProviderURLProtocol.state.withLock { $0 = .init(responses: [(404, Data("Cannot POST /v1/responses".utf8)), (200, legacy)]) }
        let service = service()
        let probe = WireTransportProbe()
        let result = try await WireTransportProbe.$current.withValue(probe) {
            try await ChatExecutionContext.$voiceCallPrivacy.withValue(.off) {
                let stream = try await service.streamResponses(messages: [.init(role: "user", content: "fixture")],
                    parameters: .init(temperature: nil, maxTokens: 64), stopSequences: [], tools: [],
                    toolChoice: nil, requestedModel: "wire-fixture/fixture")
                return try await ResponsesGenerationResult.collect(stream, endAt: .streamEnd)
            }
        }
        #expect(result.text == "OK")
        let attempts = ResponsesProviderURLProtocol.state.withLock { $0.requests }
        #expect(attempts.map { $0.url?.path } == ["/v1/responses", "/v1/chat/completions"])
        #expect(probe.attempts.map(\.statusCode) == [404, 200])
        #expect(probe.firstBuiltSnapshot().endpoint?.path == "/v1/responses")
        #expect(probe.acceptedRequestEndpointURL?.path == "/v1/chat/completions")
        #expect(probe.snapshot().request == attempts.last?.httpBody)
        await service.invalidateSession()
    }

    @Test(arguments: [401, 404, 429])
    func authModelAndRateErrorsHaveExactlyOneWireAttempt(_ status: Int) async throws {
        let body = Data(#"{"error":{"code":"model_not_found","message":"model missing"}}"#.utf8)
        ResponsesProviderURLProtocol.state.withLock { $0 = .init(responses: [(status, body)]) }
        let service = service()
        do {
            let stream = try await ChatExecutionContext.$voiceCallPrivacy.withValue(.off) {
                try await service.streamResponses(messages: [.init(role: "user", content: "fixture")],
                    parameters: .init(temperature: nil, maxTokens: 64), stopSequences: [], tools: [], toolChoice: nil,
                    requestedModel: "wire-fixture/fixture")
            }
            for try await _ in stream {}
            Issue.record("Expected provider error")
        } catch {}
        #expect(ResponsesProviderURLProtocol.state.withLock { $0.requests.count } == 1)
        await service.invalidateSession()
    }

    @Test func midstreamUnsupportedErrorCannotReplayAfterOutput() async throws {
        let body = sse([
            #"{"type":"response.created","response":{"id":"resp_wire","status":"in_progress"}}"#,
            #"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"partial"}"#,
            #"{"type":"error","error":{"code":"unsupported_endpoint","message":"Cannot POST /v1/responses"}}"#,
        ])
        ResponsesProviderURLProtocol.state.withLock { $0 = .init(responses: [(200, body)]) }
        let service = service()
        var text = ""
        do {
            let stream = try await ChatExecutionContext.$voiceCallPrivacy.withValue(.off) {
                try await service.streamResponses(messages: [.init(role: "user", content: "fixture")],
                    parameters: .init(temperature: nil, maxTokens: 64), stopSequences: [], tools: [], toolChoice: nil,
                    requestedModel: "wire-fixture/fixture")
            }
            for try await event in stream { if case .outputTextDelta(let value) = event { text += value } }
            Issue.record("Expected native stream error")
        } catch {}
        #expect(text == "partial")
        #expect(ResponsesProviderURLProtocol.state.withLock { $0.requests.count } == 1)
        await service.invalidateSession()
    }

    @Test func refusalOnlyResponseUsesOneWireRequestAndNonemptyPortableOutput() async throws {
        let refusal = "Actual provider refusal."
        let body = sse([
            try json(["type": "response.refusal.delta", "output_index": 0, "content_index": 0, "delta": refusal]),
            try json(["type": "response.completed", "response": ["id": "resp_refusal", "status": "completed",
                "output": [["type": "message", "id": "msg_refusal", "role": "assistant", "status": "completed",
                    "content": [["type": "refusal", "refusal": refusal]]]]]]),
        ])
        ResponsesProviderURLProtocol.state.withLock { $0 = .init(responses: [(200, body)]) }
        let service = service()
        let result = try await ChatExecutionContext.$voiceCallPrivacy.withValue(.off) {
            let stream = try await service.streamResponses(messages: [.init(role: "user", content: "fixture")],
                parameters: .init(temperature: nil, maxTokens: 64), stopSequences: [], tools: [], toolChoice: nil,
                requestedModel: "wire-fixture/fixture")
            return try await ResponsesGenerationResult.collect(stream, endAt: .streamEnd)
        }
        #expect(result.text == refusal)
        #expect(result.completion.responseID == "resp_refusal")
        #expect(ResponsesProviderURLProtocol.state.withLock { $0.requests.count } == 1)
        await service.invalidateSession()
    }
}

private final class ResponsesProviderURLProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var responses: [(Int, Data)]
        var requests: [URLRequest] = []
    }
    static let state = OSAllocatedUnfairLock(initialState: State(responses: []))
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "responses-wire.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.withLock { value -> (Int, Data)? in
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                captured.httpBody = body
            }
            value.requests.append(captured)
            return value.responses.isEmpty ? nil : value.responses.removeFirst()
        }
        guard let (status, data) = response, let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": status >= 400 ? "application/json" : "text/event-stream"])
        else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
