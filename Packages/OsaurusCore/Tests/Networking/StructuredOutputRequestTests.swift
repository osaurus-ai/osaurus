import Foundation
import Testing
@testable import OsaurusCore

@Suite("Structured output request fidelity")
struct StructuredOutputRequestTests {
    private let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["answer": .object(["type": .string("string")])]),
        "required": .array([.string("answer")]),
        "additionalProperties": .bool(false),
    ])

    @Test func rawNumericConstraintsAreCheckedBeforeDoubleDecoding() {
        let invalid = ["9007199254740993", "-9007199254740993", "9.007199254740993e15",
                       "1.0000000000000001", "0.00000000000000000000000000000000000000001",
                       "1e0", "1.0"]
        for number in invalid {
            for constraint in ["\"const\": " + number,
                               "\"enum\": [{\"nested\": [" + number + "]}]"] {
                let schema = "{" + constraint + "}"
                let chat = "{\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"n\",\"schema\":" + schema + "}}}"
                let responses = "{\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"n\",\"schema\":" + schema + "}}}"
                #expect(RequestValidator.rawResponseSchemaReason(Data(chat.utf8), responses: false) != nil)
                #expect(RequestValidator.rawResponseSchemaReason(Data(responses.utf8), responses: true) != nil)
            }
        }
        for number in ["0", "-7", "9007199254740991", "-9007199254740991"] {
            let body = "{\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"n\",\"schema\":{\"const\":" + number + "}}}}"
            #expect(RequestValidator.rawResponseSchemaReason(Data(body.utf8), responses: false) == nil)
        }
    }

    @Test func rawSchemaSliceHandlesEscapesDuplicatesAndUnrelatedNumbers() {
        let escaped = #"{"response_\u0066ormat":{"type":"json_schema","json_schema":{"schema":{"const":1.0000000000000001}}}}"#
        #expect(RequestValidator.rawResponseSchemaReason(Data(escaped.utf8), responses: false) != nil)
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            if let encoded = escaped.data(using: encoding) {
                #expect(RequestValidator.rawResponseSchemaReason(encoded, responses: false) != nil)
            }
        }
        let duplicate = #"{"response_format":{"type":"json_schema","json_schema":{"schema":{"const":1.0000000000000001},"schema":{"const":1}}}}"#
        #expect(RequestValidator.rawResponseSchemaReason(Data(duplicate.utf8), responses: false) != nil)
        let ordinary = #"{"temperature":0.1234567890123456789,"messages":[{"role":"user","content":"\"schema\": { \"const\":1e0 }"}]}"#
        #expect(RequestValidator.rawResponseSchemaReason(Data(ordinary.utf8), responses: false) == nil)
        let literal = #"{"response_format":{"type":"json_schema","json_schema":{"schema":{"const":"literal } ] \"const\":1e0"}}}}"#
        #expect(RequestValidator.rawResponseSchemaReason(Data(literal.utf8), responses: false) == nil)
    }

    @Test func chatSchemaRoundTripsWithoutLosingPayload() throws {
        let format = ResponseFormat(type: "json_schema", json_schema:
            ResponseJSONSchema(name: "answer_v1", description: "Typed answer", schema: schema, strict: true))
        let decoded = try JSONDecoder().decode(ResponseFormat.self, from: JSONEncoder().encode(format))
        #expect(decoded == format)
        #expect(RequestValidator.responseFormatReason(decoded) == nil)
        let encoded = try #require(decoded.json_schema).encodedSchema()
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8)) == schema)
    }

    @Test func responsesFlatSchemaReachesInternalChatRequest() throws {
        let payload = #"{"model":"local-model","input":"answer","text":{"format":{"type":"json_schema","name":"answer_v1","description":"Typed answer","schema":{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false},"strict":true}}}"#
        let response = try JSONDecoder().decode(OpenResponsesRequest.self, from: Data(payload.utf8))
        let chat = response.toChatCompletionRequest()
        #expect(chat.response_format?.type == "json_schema")
        #expect(chat.response_format?.json_schema?.schema == schema)
        #expect(chat.response_format?.json_schema?.name == "answer_v1")
        #expect(chat.response_format?.json_schema?.description == "Typed answer")
        #expect(chat.response_format?.json_schema?.strict == true)
        #expect(HTTPHandler.unsupportedSamplerReason(chat) == nil)
    }

    @Test func responsesJSONObjectAlsoPreservesExplicitFormat() throws {
        let payload = #"{"model":"local-model","input":"answer","text":{"format":{"type":"json_object"}}}"#
        let response = try JSONDecoder().decode(OpenResponsesRequest.self, from: Data(payload.utf8))
        #expect(response.toChatCompletionRequest().response_format == ResponseFormat(type: "json_object"))
    }

    @Test func missingSchemaAndInvalidNamesAreRejected() {
        #expect(RequestValidator.responseFormatReason(ResponseFormat(type: "json_schema")) != nil)
        for name in ["", "space name", String(repeating: "a", count: 65)] {
            #expect(RequestValidator.responseFormatReason(ResponseFormat(type: "json_schema",
                json_schema: ResponseJSONSchema(name: name, schema: schema))) != nil)
        }
    }

    @Test func malformedSchemaEnvelopeTypesAreNotCoerced() {
        for payload in [
            #"{"type":"json_schema","json_schema":{"name":"answer","schema":{"type":"string"},"strict":"true"}}"#,
            #"{"type":"json_schema","json_schema":{"name":42,"schema":{"type":"string"}}}"#,
            #"{"type":"json_schema","json_schema":{"name":"answer"}}"#,
        ] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(ResponseFormat.self, from: Data(payload.utf8))
            }
        }
        #expect(RequestValidator.responseFormatReason(ResponseFormat(type: "json_schema",
            json_schema: ResponseJSONSchema(name: "bad", schema: .string("not a schema")))) != nil)
    }

    @Test func schemaParametersDoNotEnablePromptInjection() throws {
        let encoded = try ResponseJSONSchema(name: "answer", schema: schema).encodedSchema()
        let parameters = GenerationParameters(temperature: nil, maxTokens: 128, jsonSchema: encoded)
        #expect(parameters.jsonSchema == encoded)
        #expect(parameters.jsonMode == false)
        let original = [ChatMessage(role: "user", content: "answer")]
        let output = ModelRuntime.applyJSONMode(original, jsonMode: parameters.jsonMode)
        #expect(output.count == 1)
        #expect(output.first?.role == "user")
        #expect(output.first?.content == "answer")
        #expect(GenerationParameters(temperature: nil, maxTokens: 128).jsonSchema == nil)
    }
    @Test func unsupportedServiceAndToolRoutesFailBeforeGeneration() async throws {
        let engine = ChatEngine(services: [FakeModelService()], installedModelsProvider: { [] },
            remoteServicesProvider: { [] }, source: .httpAPI)
        let payload = #"{"model":"fake","messages":[{"role":"user","content":"answer"}],"response_format":{"type":"json_schema","json_schema":{"name":"answer","schema":{"type":"string"}}}}"#
        let original = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(payload.utf8))
        for mode in ["provider", "tools", "stops", "remoteAgent", "invalidFormat"] {
            var request = original
            if mode == "tools" {
                var object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
                object["tools"] = [["type": "function", "function": ["name": "lookup", "parameters": ["type": "object"]]]]
                request = try JSONDecoder().decode(ChatCompletionRequest.self,
                    from: JSONSerialization.data(withJSONObject: object))
            }
            if mode == "stops" {
                var object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
                object["stop"] = ["answer"]
                request = try JSONDecoder().decode(ChatCompletionRequest.self,
                    from: JSONSerialization.data(withJSONObject: object))
            }
            if mode == "remoteAgent" { request.runAsRemoteAgent = true }
            if mode == "invalidFormat" { request.response_format = ResponseFormat(type: "invalid") }
            for streaming in [true, false] {
                do {
                    if streaming { _ = try await engine.streamChat(request: request) }
                    else { _ = try await engine.completeChat(request: request) }
                    Issue.record("unsupported structured request must fail: \(mode)")
                } catch let error as ChatEngine.EngineError {
                    #expect(error.httpStatus == 400)
                    if mode == "stops" { #expect(error.localizedDescription.contains("stop strings")) }
                    #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 400)
                    #expect(HTTPHandler.openAIErrorType(for: error) == "invalid_request_error")
                    #expect(HTTPHandler.openResponsesErrorCode(for: error) == "invalid_request_error")
                }
            }
        }
        var ordinary = original
        ordinary.response_format = nil
        let response = try await engine.completeChat(request: ordinary)
        #expect(response.choices.first?.message.content == "hello")
    }

}
