import Foundation
import Testing

@testable import OsaurusCore

@Suite("HTTP canonical Responses contracts", .serialized, .timeLimit(.minutes(2)))
struct HTTPResponsesNativeTests {
    private actor Engine: ChatEngineProtocol {
        let rows: [[ResponsesGenerationEvent]]
        private(set) var requests: [ResponsesInferenceRequest] = []
        init(_ rows: [[ResponsesGenerationEvent]]) { self.rows = rows }
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            let index = requests.count
            requests.append(request)
            guard index < rows.count else { throw NSError(domain: "unexpected-replay", code: 999) }
            return AsyncThrowingStream { continuation in
                for event in rows[index] { continuation.yield(event) }
                // Remains open after logical completion. The native producer
                // owns its tail and the HTTP body must not wait for EOF.
            }
        }
        func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
            throw NSError(domain: "unexpected-legacy-stream", code: 998)
        }
        func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
            throw NSError(domain: "unexpected-legacy-completion", code: 997)
        }
    }

    private func terminal(_ status: ResponsesGenerationCompletion.Status = .completed,
                          calls: [ResponsesFunctionCall] = [], measured: Bool = true) -> ResponsesGenerationEvent {
        .responseCompleted(.init(responseID: "resp_engine", status: status, functionCalls: calls,
            tokenCount: measured ? 17 : nil, tokensPerSecond: measured ? 40.123456789 : nil,
            unclosedReasoning: false, stopReason: status == .incomplete ? "length" : "stop",
            promptTokensPerSecond: nil, mtp: nil, inputTokenCount: measured ? 113 : nil))
    }

    @Test func inputProjectionKeepsOneAssistantBatchReasoningOpaqueItemsAndMedia() throws {
        let payload = #"""
        {"model":"fixture","temperature":1,"top_p":0.95,"max_output_tokens":65536,
         "prompt_cache_key":"  fixture-session  ","store":false,"include":["reasoning.encrypted_content"],
         "parallel_tool_calls":false,"reasoning":{"summary":"auto","context":"all_turns"},
         "tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}},
                  {"type":"custom","name":"future_tool","future":{"retained":true}}],
         "input":[
          {"role":"user","content":[{"type":"input_text","text":"read"},{"type":"input_image","image_url":"data:image/png;base64,AA=="}],"future_user":"retained"},
          {"type":"reasoning","id":"rs_original","summary":[{"type":"summary_text","text":"full prior reasoning"}],"encrypted_content":"opaque","future_reasoning":7},
          {"type":"message","id":"msg_original","phase":"commentary","role":"assistant","content":[{"type":"output_text","text":"Checking."}],"future_message":{"keep":true}},
          {"type":"function_call","id":"fc_1","call_id":"call_1","name":"lookup","arguments":"{\"slot\":1}","future_call":true},
          {"type":"function_call","id":"fc_2","call_id":"call_2","name":"lookup","arguments":"{\"slot\":2}"},
          {"type":"function_call_output","call_id":"call_1","output":"one","future_result":true},
          {"type":"function_call_output","call_id":"call_2","output":"two"}
         ]}
        """#
        let api = try JSONDecoder().decode(OpenResponsesRequest.self, from: Data(payload.utf8))
        let request = try api.toResponsesInferenceRequest()
        #expect(request.sessionID == "fixture-session")
        #expect(request.generation.temperature == 1)
        #expect(request.generation.topP == 0.95)
        #expect(request.generation.maxOutputTokens == 65536)
        #expect(request.generation.topK == nil)
        #expect(request.providerOptions?.tools?.count == 2)
        #expect(request.providerOptions?.parallelToolCalls == false)
        #expect(request.providerOptions?.reasoning?.context == "all_turns")
        #expect(request.input.count == 4)
        #expect(request.input[0].imageUrls == ["data:image/png;base64,AA=="])
        let assistant = request.input[1]
        #expect(assistant.role == "assistant")
        #expect(assistant.content == "Checking.")
        #expect(assistant.reasoning_content == "full prior reasoning")
        #expect(assistant.reasoning_item_id == "rs_original" && assistant.reasoning_encrypted == "opaque")
        #expect(assistant.tool_calls?.map(\.id) == ["call_1", "call_2"])
        #expect(assistant.responses_output_items?.count == 4)
        let encoded = try JSONEncoder.osaurusCanonical().encode(assistant.responses_output_items)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("future_message") && text.contains("future_reasoning") && text.contains("future_call"))
        #expect(text.contains("\"phase\":\"commentary\""))
        #expect(request.input.suffix(2).map(\.tool_call_id) == ["call_1", "call_2"])
        #expect(request.input[2].responses_output_items != nil)
    }

    @Test func namedToolChoiceIsNeverSilentlyChangedToAuto() throws {
        let request = try JSONDecoder().decode(OpenResponsesRequest.self, from: Data(#"{"model":"fixture","input":"go","tools":[{"type":"function","name":"offered"}],"tool_choice":{"type":"function","name":"different"}}"#.utf8))
        let native = try request.toResponsesInferenceRequest()
        guard case .function(let choice) = native.toolChoice else { Issue.record("Named choice was weakened"); return }
        #expect(choice.function.name == "different")
    }

    @Test func easyMessageNormalizationPreservesNativeFields() throws {
        let original = Data(#"{"model":"fixture","input":[{"role":"assistant","id":"msg_original","phase":"commentary","content":[{"type":"output_text","text":"Checking."}],"future":{"nested":[1,"retain"]}}]}"#.utf8)
        let request = try JSONDecoder().decode(OpenResponsesRequest.self, from: original)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.osaurusCanonical().encode(request)) as? [String: Any])
        let item = try #require((object["input"] as? [[String: Any]])?.first)
        #expect(item["type"] as? String == "message")
        #expect(item["id"] as? String == "msg_original" && item["phase"] as? String == "commentary")
        let before = try #require((JSONSerialization.jsonObject(with: original) as? [String: Any])?["input"] as? [[String: Any]])
        var normalized = before[0]
        normalized["type"] = "message"
        #expect(NSDictionary(dictionary: item).isEqual(to: normalized))
    }

    @Test func nativeOutputProjectionRetainsRawFieldsAndUnknownItemKinds() throws {
        let raw: [JSONValue] = [
            .object(["type": .string("message"), "id": .string("msg_native"), "phase": .string("final_answer"),
                "status": .string("completed"), "role": .string("assistant"),
                "content": .array([.object(["type": .string("output_text"), "text": .string("answer")])]),
                "future": .bool(true)]),
            .object(["type": .string("future_item"), "id": .string("future_native"), "payload": .string("retained")]),
        ]
        var accumulator = ResponsesGenerationAccumulator()
        for item in raw { try accumulator.consume(.providerOutputItem(item)) }
        try accumulator.consume(.outputTextDelta("answer"))
        try accumulator.consume(terminal(measured: false))
        let response = try accumulator.result().openResponsesResponse(responseID: "resp_wire", model: "fixture")
        #expect(response.usage == nil)
        let data = try JSONEncoder.osaurusCanonical().encode(response)
        let decoded = try JSONDecoder().decode(OpenResponsesResponse.self, from: data)
        let roundTrip = try JSONEncoder.osaurusCanonical().encode(decoded)
        let body = String(decoding: roundTrip, as: UTF8.self)
        #expect(body.contains("msg_native") && body.contains("final_answer") && body.contains("\"future\":true"))
        #expect(body.contains("future_native") && body.contains("retained"))
    }

    @Test(arguments: [false, true])
    func publicNonstreamEndpointUsesTypedCompletionAndPreservesPreviousNativeHistory(_ measured: Bool) async throws {
        let raw: JSONValue = .object(["type": .string("message"), "id": .string("msg_retained"),
            "phase": .string("commentary"), "future": .bool(true)])
        let engine = Engine([
            [.reasoningDelta("prior reasoning"), .reasoningItem(.init(id: "rs_retained", encryptedContent: "opaque")),
             .providerOutputItem(raw), .outputTextDelta("first answer"), terminal(measured: measured)],
            [.outputTextDelta("second answer"), terminal(measured: measured)],
        ])
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        func post(_ body: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/responses")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("false", forHTTPHeaderField: "X-Persist")
            request.authenticate()
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let first = try await post(["model": "fixture", "input": "first", "stream": false])
        let id = try #require(first["id"] as? String)
        let usage = first["usage"] as? [String: Any]
        #expect((usage != nil) == measured)
        if measured {
            #expect(usage?["input_tokens"] as? Int == 113)
            #expect(usage?["output_tokens"] as? Int == 17)
            #expect(usage?["tokens_per_second"] as? Double == 40.123456789)
        }
        _ = try await post(["model": "fixture", "input": "second", "previous_response_id": id, "stream": false])
        let requests = await engine.requests
        #expect(requests.count == 2)
        let prior = try #require(requests[1].input.first { $0.role == "assistant" })
        #expect(prior.reasoning_content == "prior reasoning")
        #expect(prior.reasoning_item_id == "rs_retained" && prior.reasoning_encrypted == "opaque")
        #expect(prior.responses_output_items == [raw])
        #expect(requests[0].generation.temperature == nil && requests[0].generation.topK == nil)
    }

    @Test func incompleteAndCancelledResultsHaveHonestPublicStatus() throws {
        for status in [ResponsesGenerationCompletion.Status.incomplete, .cancelled] {
            var accumulator = ResponsesGenerationAccumulator()
            try accumulator.consume(.outputTextDelta("partial"))
            try accumulator.consume(terminal(status, measured: false))
            let response = try accumulator.result().openResponsesResponse(responseID: "resp", model: "fixture")
            #expect(response.status == (status == .incomplete ? .incomplete : .cancelled))
            #expect(response.usage == nil)
            if status == .incomplete { #expect(response.incomplete_details?.reason == "max_output_tokens") }
        }
    }
}

extension HTTPResponsesNativeTests {
    private func post(_ server: ChatStreamingTestServer, path: String, body: [String: Any]) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "X-Persist")
        request.authenticate()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    @Test func nativeSSEProxyRetainsOriginalIDsPhaseAndOneTerminal() async throws {
        let item: JSONValue = .object(["type": .string("message"), "id": .string("msg_native"),
            "role": .string("assistant"), "status": .string("completed"), "phase": .string("commentary"),
            "future": .bool(true), "content": .array([.object(["type": .string("output_text"), "text": .string("native answer")])])])
        let created: JSONValue = .object(["type": .string("response.created"), "sequence_number": .number(1),
            "response": .object(["id": .string("resp_native"), "status": .string("in_progress"), "output": .array([])])])
        let delta: JSONValue = .object(["type": .string("response.output_text.delta"), "sequence_number": .number(2),
            "item_id": .string("msg_native"), "output_index": .number(0), "content_index": .number(0), "delta": .string("native answer")])
        let done: JSONValue = .object(["type": .string("response.completed"), "sequence_number": .number(3),
            "response": .object(["id": .string("resp_native"), "status": .string("completed"), "output": .array([item])])])
        let engine = Engine([[.providerEvent(created), .providerEvent(delta), .outputTextDelta("native answer"),
            .providerOutputItem(item), .providerEvent(done), terminal(measured: false)]])
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        let (status, body) = try await post(server, path: "/responses", body: ["model": "fixture", "input": "go", "stream": true])
        #expect(status == 200)
        let frames = body.components(separatedBy: .newlines).filter { $0.hasPrefix("data: ") }.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8))) as? [String: Any]
        }
        #expect(frames.compactMap { $0["type"] as? String } == ["response.created", "response.output_text.delta", "response.completed"])
        #expect(frames.compactMap { $0["sequence_number"] as? Int } == [1, 2, 3])
        #expect(body.contains("msg_native") && body.contains("resp_native") && body.contains("commentary") && body.contains("\"future\":true"))
        #expect(!body.contains("msg_resp_") && !body.contains("\u{FFFE}"))
        #expect(body.components(separatedBy: "data: [DONE]").count == 2)
    }

    @Test(arguments: [true, false], ["/chat/completions", "/api/chat", "/messages"].flatMap { path in
        [true, false].map { measured in (path: path, measured: measured) }
    })
    func explicitCompatibilityWiresStillUseTypedInference(streaming: Bool, route: (path: String, measured: Bool)) async throws {
        let path = route.path
        let measured = route.measured
        let engine = Engine([[.reasoningDelta("actual reasoning"), .outputTextDelta("actual answer"), terminal(measured: measured)]])
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        let (status, body) = try await post(server, path: path, body: ["model": "fixture", "stream": streaming,
            "max_tokens": 16, "messages": [["role": "user", "content": "go"]]])
        if path == "/messages" && !measured {
            #expect(status == (streaming ? 200 : 500))
            #expect(body.contains("requires reported input and output token counts"))
            #expect(!body.contains("\"type\":\"message_stop\""))
        } else {
            #expect(status == 200)
            #expect(body.contains("actual answer"))
            if path == "/api/chat" { #expect(body.contains("\"thinking\":\"actual reasoning\"")) }
        }
        #expect(!body.contains("unexpected-legacy") && !body.contains("\u{FFFE}"))
        #expect(await engine.requests.count == 1)
        let request = try #require(await engine.requests.first)
        #expect(request.generation.temperature == nil && request.generation.topK == nil)
    }

    @Test(arguments: [true, false])
    func chatNonstreamKeepsSparseMeasuredMetrics(_ reportsInput: Bool) async throws {
        let completion = ResponsesGenerationCompletion(responseID: "resp_sparse", status: .completed,
            functionCalls: [], tokenCount: 77, tokensPerSecond: 12.5, unclosedReasoning: false,
            stopReason: "stop", promptTokensPerSecond: nil, mtp: nil,
            inputTokenCount: reportsInput ? 257 : nil)
        let engine = Engine([[.outputTextDelta("actual answer"), .responseCompleted(completion)]])
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        let (status, body) = try await post(server, path: "/chat/completions", body: ["model": "fixture",
            "stream": false, "messages": [["role": "user", "content": "go"]]])
        #expect(status == 200)
        let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let metrics = try #require(object["generation_metrics"] as? [String: Any])
        #expect(metrics["completion_tokens"] as? Int == 77)
        #expect(metrics["tokens_per_second"] as? Double == 12.5)
        let usage = object["usage"] as? [String: Any]
        if reportsInput {
            #expect(usage?["prompt_tokens"] as? Int == 257)
            #expect(usage?["completion_tokens"] as? Int == 77)
            #expect(usage?["total_tokens"] as? Int == 334)
        } else {
            #expect(usage == nil && metrics["prompt_tokens"] == nil && metrics["total_tokens"] == nil)
        }
        #expect(await engine.requests.count == 1)
    }

    @Test(arguments: [true, false])
    func anthropicHTTPPreservesActualSignedAndRedactedOutput(_ streaming: Bool) async throws {
        let signed: JSONValue = .object(["type": .string("thinking"), "thinking": .string("actual chain"),
            "signature": .string("provider-signature"), "future": .bool(true)])
        let redacted: JSONValue = .object(["type": .string("redacted_thinking"),
            "data": .string("opaque-redacted"), "future": .string("retained")])
        let engine = Engine([[.inputTokenCount(113), .reasoningDelta("actual chain"),
            .anthropicThinkingBlock(signed), .anthropicThinkingBlock(redacted),
            .outputTextDelta("actual answer"), terminal()]])
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        let (status, body) = try await post(server, path: "/messages", body: ["model": "fixture",
            "max_tokens": 16, "stream": streaming, "messages": [["role": "user", "content": "go"]]])
        #expect(status == 200)
        if streaming {
            let frames = try body.components(separatedBy: .newlines).filter { $0.hasPrefix("data: ") }
                .map { try #require(JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any]) }
            let starts = frames.filter { $0["type"] as? String == "content_block_start" }
            #expect(starts.compactMap { $0["index"] as? Int } == [0, 1, 2])
            let hidden = try #require(starts.first { ($0["content_block"] as? [String: Any])?["type"] as? String == "redacted_thinking" })
            let opaque = try #require(hidden["content_block"] as? [String: Any])
            #expect(opaque["data"] as? String == "opaque-redacted" && opaque["future"] as? String == "retained")
            let deltas = frames.compactMap { $0["delta"] as? [String: Any] }
            #expect(deltas.compactMap { $0["thinking"] as? String }.joined() == "actual chain")
            #expect(deltas.compactMap { $0["signature"] as? String } == ["provider-signature"])
            #expect(deltas.compactMap { $0["text"] as? String }.joined() == "actual answer")
            #expect(frames.filter { $0["type"] as? String == "message_stop" }.count == 1)
            #expect(frames.filter { $0["type"] as? String == "content_block_stop" }.compactMap { $0["index"] as? Int } == [0, 1, 2])
        } else {
            let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            let blocks = try #require(object["content"] as? [[String: Any]])
            #expect(blocks.compactMap { $0["type"] as? String } == ["thinking", "redacted_thinking", "text"])
            #expect(blocks[0]["thinking"] as? String == "actual chain" && blocks[0]["signature"] as? String == "provider-signature")
            #expect(blocks[0]["future"] as? Bool == true)
            #expect(blocks[1]["data"] as? String == "opaque-redacted" && blocks[1]["future"] as? String == "retained")
            #expect(blocks[2]["text"] as? String == "actual answer")
        }
        #expect(!body.contains("\"error\""))
        #expect(await engine.requests.count == 1)
    }

    @Test func unknownPreviousResponseFailsBeforeInference() async throws {
        let engine = Engine([])
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        let (status, body) = try await post(server, path: "/responses", body: ["model": "fixture", "input": "continue",
            "previous_response_id": "missing-" + UUID().uuidString])
        #expect(status == 404)
        #expect(body.contains("previous response is unavailable"))
        #expect(await engine.requests.isEmpty)
    }

    @Test func perRequestInstructionsDoNotEraseExplicitSystemHistory() throws {
        let responseID = "test-instructions-" + UUID().uuidString
        let original = try JSONDecoder().decode(OpenResponsesRequest.self, from: Data(#"{"model":"fixture","instructions":"one-request-only","input":[{"role":"system","content":"retained explicit history"},{"role":"user","content":"first"}]}"#.utf8))
        let first = try original.toResponsesInferenceRequest()
        HTTPHandler.storeOpenResponsesContext(responseId: responseID, model: "fixture", request: first,
            assistantMessages: [ChatMessage(role: "assistant", content: "answer")], perRequestInstructions: original.instructions)
        let followup = ResponsesInferenceRequest(model: "fixture", input: [ChatMessage(role: "user", content: "next")])
        let restored = try HTTPHandler.applyOpenResponsesContext(to: followup, previousResponseId: responseID)
        #expect(!restored.input.contains { $0.content == "one-request-only" })
        #expect(restored.input.contains { $0.role == "system" && $0.content == "retained explicit history" })
    }

    @Test func ollamaThinkingAndOptionsAreCanonicalAndImagesRemainMedia() throws {
        let image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jhAAAAABJRU5ErkJggg=="
        let body: [String: Any] = ["model": "fixture", "think": true,
            "options": ["temperature": 1.0, "top_p": 0.95, "num_predict": 65536],
            "messages": [["role": "assistant", "content": "answer", "thinking": "prior reasoning"],
                         ["role": "user", "content": "inspect", "images": [image]]]]
        let request = try HTTPHandler.decodeOllamaChatRequest(JSONSerialization.data(withJSONObject: body))
        #expect(request.messages[0].reasoning_content == "prior reasoning")
        #expect(request.messages[1].imageUrls.count == 1)
        #expect(request.temperature == 1 && request.top_p == 0.95 && request.resolvedMaxTokens == 65536)
        #expect(request.enable_thinking == true && request.top_k == nil)
        let invalid = Data(#"{"model":"fixture","think":1,"messages":[]}"#.utf8)
        #expect(throws: (any Error).self) { try HTTPHandler.decodeOllamaChatRequest(invalid) }
    }

    @Test func anthropicThinkingAndRedactedBlocksKeepActualStateOffOpenAIWire() throws {
        let body = #"{"model":"fixture","max_tokens":16,"messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"actual chain","signature":"actual-signature","future":true},{"type":"redacted_thinking","data":"opaque-redacted"},{"type":"text","text":"answer"}]},{"role":"user","content":"next"}]}"#
        let request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: Data(body.utf8))
        let native = try request.toResponsesInferenceRequest()
        let assistant = try #require(native.input.first { $0.role == "assistant" })
        #expect(assistant.reasoning_content == "actual chain" && assistant.content == "answer")
        let blocks = try #require(assistant.anthropic_thinking_blocks)
        let serialized = String(decoding: try JSONEncoder.osaurusCanonical().encode(blocks), as: UTF8.self)
        #expect(serialized.contains("actual-signature") && serialized.contains("opaque-redacted") && serialized.contains("\"future\":true"))
        let openAI = String(decoding: try JSONEncoder.osaurusCanonical().encode(assistant), as: UTF8.self)
        #expect(!openAI.contains("actual-signature") && !openAI.contains("opaque-redacted"))
    }
}
