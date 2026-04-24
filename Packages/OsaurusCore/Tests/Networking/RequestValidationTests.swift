//
//  RequestValidationTests.swift
//  osaurusTests
//
//  Coverage for `HTTPHandler.unsupportedSamplerReason` — the request
//  validator added in §1.4 of the inference-and-tool-calling gap audit.
//  Silent ignoring of unsupported sampler params is the worst behavior
//  for an OpenAI-compatible harness; this test pins the reject-with-400
//  contract for `n>1` and `response_format=json_schema`, and verifies
//  the supported flavors (`json_object`, `text`, default) pass through.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct RequestValidationTests {

    private func makeRequest(
        n: Int? = nil,
        responseFormatType: String? = nil
    ) -> ChatCompletionRequest {
        var req = ChatCompletionRequest(
            model: "default",
            messages: [ChatMessage(role: "user", content: "hello")],
            temperature: 0.7,
            max_tokens: 32,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: n,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
        if let type = responseFormatType {
            req.response_format = ResponseFormat(type: type)
        }
        return req
    }

    @Test func defaultRequestIsAccepted() {
        let req = makeRequest()
        #expect(HTTPHandler.unsupportedSamplerReason(req) == nil)
    }

    @Test func nEqualToOneIsAccepted() {
        let req = makeRequest(n: 1)
        #expect(HTTPHandler.unsupportedSamplerReason(req) == nil)
    }

    @Test func nGreaterThanOneIsRejected() {
        let req = makeRequest(n: 2)
        let reason = HTTPHandler.unsupportedSamplerReason(req)
        #expect(reason != nil)
        #expect((reason ?? "").contains("n"))
    }

    @Test func responseFormatJSONObjectIsAccepted() {
        let req = makeRequest(responseFormatType: "json_object")
        #expect(HTTPHandler.unsupportedSamplerReason(req) == nil)
    }

    @Test func responseFormatTextIsAccepted() {
        let req = makeRequest(responseFormatType: "text")
        #expect(HTTPHandler.unsupportedSamplerReason(req) == nil)
    }

    @Test func responseFormatJSONSchemaIsRejected() {
        let req = makeRequest(responseFormatType: "json_schema")
        let reason = HTTPHandler.unsupportedSamplerReason(req)
        #expect(reason != nil)
        #expect((reason ?? "").contains("json_schema"))
    }
}
