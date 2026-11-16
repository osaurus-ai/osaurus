import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct RepetitionSeedCarrierTests {
    private func chat(_ fields: [String: Any] = [:]) throws -> ChatCompletionRequest {
        var body: [String: Any] = ["model": "carrier", "messages": [["role": "user", "content": "fixture"]]]
        body.merge(fields) { _, value in value }
        return try JSONDecoder().decode(ChatCompletionRequest.self, from: JSONSerialization.data(withJSONObject: body))
    }

    private func responses(_ fields: [String: Any] = [:]) throws -> OpenResponsesRequest {
        var body: [String: Any] = ["model": "carrier", "input": "fixture"]
        body.merge(fields) { _, value in value }
        return try JSONDecoder().decode(OpenResponsesRequest.self, from: JSONSerialization.data(withJSONObject: body))
    }

    @Test func chatDecodeCopyEncodingAndCanonicalRoundTripKeepSeparatePenalties() throws {
        let request = try chat(["repetition_penalty": 1.25, "seed": -1,
            "frequency_penalty": -0.5, "presence_penalty": 0.25])
        for copy in [request, request.withModel("other"),
            request.withContext(messages: request.messages, tools: nil, toolChoice: nil)] {
            #expect(copy.repetition_penalty == 1.25)
            #expect(copy.seed == -1)
            #expect(copy.frequency_penalty == -0.5 && copy.presence_penalty == 0.25)
            let decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: JSONEncoder().encode(copy))
            #expect(decoded.repetition_penalty == 1.25 && decoded.seed == -1)
            let canonical = ResponsesInferenceRequest(chatCompletion: copy)
            #expect(canonical.generation.repetitionPenalty == 1.25 && canonical.generation.seed == -1)
            #expect(canonical.generation.frequencyPenalty == -0.5 && canonical.generation.presencePenalty == 0.25)
            let compatible = canonical.chatCompletionsCompatibilityRequest()
            #expect(compatible.repetition_penalty == 1.25 && compatible.seed == -1)
        }
    }

    @Test(arguments: [Int.min, -1, 0, 42, Int.max])
    func responsesExtensionSeedRetainsEverySignedBitAndPenalty(seed: Int) throws {
        let wire = try responses(["seed": seed, "repetition_penalty": 1])
        let encoded = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(OpenResponsesRequest.self, from: encoded)
        #expect(decoded.seed == seed && decoded.repetition_penalty == 1)
        let canonical = try decoded.toResponsesInferenceRequest()
        #expect(canonical.generation.seed == seed && canonical.generation.repetitionPenalty == 1)
        #expect(decoded.toChatCompletionRequest().seed == seed)
        #expect(decoded.toChatCompletionRequest().repetition_penalty == 1)
        let compatible = canonical.chatCompletionsCompatibilityRequest()
        #expect(compatible.seed == seed && compatible.repetition_penalty == 1)
    }

    @Test func absentAndNullControlsStayNilAndDoNotChangeDefaultWire() throws {
        let cases: [[String: Any]] = [[:], ["seed": NSNull(), "repetition_penalty": NSNull()]]
        for fields in cases {
            let request = try chat(fields)
            let wire = try responses(fields)
            #expect(request.seed == nil && request.repetition_penalty == nil)
            #expect(wire.seed == nil && wire.repetition_penalty == nil)
            #expect(try wire.toResponsesInferenceRequest().generation.repetitionPenalty == nil)
            let chatBody = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            let responseBody = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
            #expect(chatBody["seed"] == nil && chatBody["repetition_penalty"] == nil)
            #expect(responseBody["seed"] == nil && responseBody["repetition_penalty"] == nil)
        }
    }

    private actor Capture {
        private var parameters: [GenerationParameters] = []
        func append(_ value: GenerationParameters) { parameters.append(value) }
        func values() -> [GenerationParameters] { parameters }
    }

    private struct RecordingService: ModelService {
        let capture: Capture
        private let base = FakeModelService(supportedModel: "carrier", completeText: "fixture")
        var id: String { base.id }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { base.handles(requestedModel: requestedModel) }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?) async throws -> String { throw CancellationError() }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error> {
            await capture.append(parameters)
            return try await base.streamDeltas(messages: messages, parameters: parameters,
                requestedModel: requestedModel, stopSequences: stopSequences)
        }
    }

    private func engine(_ capture: Capture) -> ChatEngine {
        ChatEngine(services: [RecordingService(capture: capture)], installedModelsProvider: { [] },
            remoteServicesProvider: { [] }, source: .httpAPI)
    }

    @Test func actualEngineDispatchRetainsExplicitValuesAndDoesNotLeakToNextRequest() async throws {
        let capture = Capture()
        let engine = engine(capture)
        let first = ResponsesInferenceRequest(chatCompletion: try chat(["seed": 0, "repetition_penalty": 1.25,
            "frequency_penalty": -0.5, "presence_penalty": 0.25]))
        let second = try responses(["seed": -1, "repetition_penalty": 1]).toResponsesInferenceRequest()
        let third = try responses().toResponsesInferenceRequest()
        for request in [first, second, third] {
            for try await _ in try await engine.streamResponses(request: request) {}
        }
        let values = await capture.values()
        try #require(values.count == 3)
        #expect(values[0].seed == 0 && values[0].repetitionPenalty == 1.25)
        #expect(values[0].frequencyPenalty == -0.5 && values[0].presencePenalty == 0.25)
        #expect(values[1].seed == UInt64.max && values[1].repetitionPenalty == 1)
        #expect(values[1].frequencyPenalty == nil && values[1].presencePenalty == nil)
        #expect(values[2].seed == nil && values[2].repetitionPenalty == nil)
        #expect(values[2].frequencyPenalty == nil && values[2].presencePenalty == nil)
    }

    @Test func localSamplerReceivesIndependentPenaltyAndSeed() {
        let runtime = ModelRuntime.makeGenerateParameters(temperature: 0.7, maxTokens: 16, topP: 0.9,
            repetitionPenalty: 1.25, presencePenalty: 0.25, frequencyPenalty: -0.5, randomSeed: UInt64.max)
        #expect(runtime.repetitionPenalty == 1.25)
        #expect(runtime.presencePenalty == 0.25 && runtime.frequencyPenalty == -0.5)
        #expect(runtime.randomSeed == UInt64.max)
    }

    @Test(arguments: [Float(-1), 0, .nan, .infinity])
    func invalidPenaltyFailsBeforeServiceInvocation(value: Float) async throws {
        let capture = Capture()
        var request = try responses().toResponsesInferenceRequest()
        request.generation.repetitionPenalty = value
        do {
            _ = try await engine(capture).streamResponses(request: request)
            Issue.record("Invalid repetition penalty reached streaming dispatch")
        } catch let error as ChatEngine.EngineError {
            #expect(error.httpStatus == 400)
            #expect(error.localizedDescription.contains("repetition_penalty"))
        }
        #expect(await capture.values().isEmpty)
    }

    @Test(arguments: [-1, 0])
    func invalidWirePenaltyIsRejected(value: Int) throws {
        #expect(throws: DecodingError.self) { try chat(["repetition_penalty": value]) }
        let wire = try responses(["repetition_penalty": value])
        #expect(throws: (any Error).self) { try wire.toResponsesInferenceRequest() }
    }

    private func service(_ type: RemoteProviderType = .openaiLegacy) -> RemoteProviderService {
        RemoteProviderService(provider: RemoteProvider(name: "fixture", host: "localhost", providerProtocol: .http,
            port: 8000, basePath: "/v1", authType: .none, providerType: type), models: ["carrier"], resolvedHeaders: [:])
    }

    @Test func omittedRemoteControlsKeepBothWireFormatsUnchanged() async throws {
        let request = await service().buildChatRequest(messages: [ChatMessage(role: "user", content: "fixture")],
            parameters: GenerationParameters(temperature: nil, maxTokens: 16),
            model: "carrier", stream: false, tools: nil, toolChoice: nil)
        let chatBody = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let wire = try request.toOpenResponsesRequest()
        let responseBody = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        #expect(request.seed == nil && request.repetition_penalty == nil)
        #expect(wire.seed == nil && wire.repetition_penalty == nil)
        #expect(chatBody["seed"] == nil && chatBody["repetition_penalty"] == nil)
        #expect(responseBody["seed"] == nil && responseBody["repetition_penalty"] == nil)
    }

    @Test(arguments: [Int.min, -1, 0, Int.max])
    func remoteChatAndCompatibleResponsesEncodeSameSignedSeed(seed: Int) async throws {
        let request = await service().buildChatRequest(messages: [ChatMessage(role: "user", content: "fixture")],
            parameters: GenerationParameters(temperature: nil, maxTokens: 16, repetitionPenalty: 1.25,
                seed: UInt64(bitPattern: Int64(seed))), model: "carrier", stream: true, tools: nil, toolChoice: nil)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(body["seed"] as? Int == seed)
        #expect(body["repetition_penalty"] as? Double == 1.25)
        let wire = try request.toOpenResponsesRequest()
        #expect(wire.seed == seed && wire.repetition_penalty == 1.25)
        let canonical = try wire.toResponsesInferenceRequest()
        #expect(canonical.generation.seed == seed && canonical.generation.repetitionPenalty == 1.25)
        let nativeBody = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        #expect(nativeBody["seed"] as? Int == seed)
        #expect(nativeBody["repetition_penalty"] as? Double == 1.25)
    }

    @Test(arguments: [RemoteProviderType.anthropic, .gemini, .openAICodex])
    func unsupportedRemotePenaltyFailsBeforeHTTPRequest(type: RemoteProviderType) async throws {
        let provider = service(type)
        let request = await provider.buildChatRequest(messages: [ChatMessage(role: "user", content: "fixture")],
            parameters: GenerationParameters(temperature: nil, maxTokens: 16, repetitionPenalty: 1.25),
            model: "carrier", stream: false, tools: nil, toolChoice: nil)
        do {
            _ = try await provider.buildURLRequest(for: request)
            Issue.record("Unsupported penalty accepted for \(type)")
        } catch let error as RemoteProviderServiceError {
            guard case .unsupportedParameter(let message) = error else { throw error }
            #expect(message.contains("repetition_penalty"))
        }
    }

    @Test(arguments: [RemoteProviderType.anthropic, .openAICodex])
    func unsupportedRemoteSeedFailsBeforeHTTPRequest(type: RemoteProviderType) async throws {
        let provider = service(type)
        let request = await provider.buildChatRequest(messages: [ChatMessage(role: "user", content: "fixture")],
            parameters: GenerationParameters(temperature: nil, maxTokens: 16, seed: 0),
            model: "carrier", stream: false, tools: nil, toolChoice: nil)
        do {
            _ = try await provider.buildURLRequest(for: request)
            Issue.record("Unsupported seed accepted for \(type)")
        } catch let error as RemoteProviderServiceError {
            guard case .unsupportedParameter(let message) = error else { throw error }
            #expect(message.contains("seed"))
        }
    }

    @Test func codexRejectsExtensionsWhileGeminiKeepsSupportedSeed() async throws {
        var request = await service().buildChatRequest(messages: [ChatMessage(role: "user", content: "fixture")],
            parameters: GenerationParameters(temperature: nil, maxTokens: 16, seed: 42),
            model: "carrier", stream: false, tools: nil, toolChoice: nil)
        #expect(throws: RemoteProviderServiceError.self) { try request.toCodexOpenResponsesRequest() }
        let gemini = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request.toGeminiRequest())) as? [String: Any])
        #expect((gemini["generationConfig"] as? [String: Any])?["seed"] as? Int == 42)
        request.seed = nil
        request.repetition_penalty = 1.25
        #expect(throws: RemoteProviderServiceError.self) { try request.toCodexOpenResponsesRequest() }
    }

    @Test func remoteAgentOwnedSettingsCannotSilentlyDropExplicitControls() async throws {
        let provider = service(.osaurus)
        let request = await provider.buildChatRequest(messages: [ChatMessage(role: "user", content: "fixture")],
            parameters: GenerationParameters(temperature: nil, maxTokens: 16, repetitionPenalty: 1.25,
                seed: 0, runAsRemoteAgent: true), model: "carrier", stream: false, tools: nil, toolChoice: nil)
        #expect(request.seed == 0 && request.repetition_penalty == 1.25)
        #expect(throws: RemoteProviderServiceError.self) { try request.validateSamplingExtensions(for: .osaurus) }
    }

    @Test func foundationRejectsUnsupportedControlsButOmissionRemainsValid() throws {
        let foundation = FoundationModelService()
        try ChatEngine.validateSamplingExtensions(GenerationParameters(temperature: nil, maxTokens: 16), for: foundation)
        #expect(throws: ChatEngine.EngineError.self) {
            try ChatEngine.validateSamplingExtensions(GenerationParameters(temperature: nil, maxTokens: 16,
                repetitionPenalty: 1), for: foundation)
        }
        #expect(throws: ChatEngine.EngineError.self) {
            try ChatEngine.validateSamplingExtensions(GenerationParameters(temperature: nil, maxTokens: 16,
                seed: 0), for: foundation)
        }
    }

    @Test(arguments: ["repetition_penalty", "seed", "chat_template_kwargs", "top_k"])
    func unsupportedProviderOptionsAreTypedClientErrorsAcrossHTTPFlavors(parameter: String) {
        let error = RemoteProviderServiceError.unsupportedParameter("Unsupported explicit \(parameter)")
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 400)
        #expect(HTTPHandler.openAIErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.anthropicErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.openResponsesErrorCode(for: error) == "invalid_request_error")
        #expect(HTTPHandler.ollamaErrorType(for: error) == "invalid_request_error")
        #expect(error.localizedDescription.contains(parameter))
        let unrelated = RemoteProviderServiceError.requestFailed("upstream failure")
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: unrelated).code == 500)
        #expect(HTTPHandler.openAIErrorType(for: unrelated) == "internal_error")
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: CancellationError()).code == 499)
    }


    @Test func canonicalReservedTemplateErrorIsTypedBadRequestBeforeDispatch() async throws {
        let capture = Capture()
        var request = try responses().toResponsesInferenceRequest()
        request.generation.templateKwargs = ["messages": .array([])]
        do {
            _ = try await engine(capture).streamResponses(request: request)
            Issue.record("Canonical reserved template key reached the inference service")
        } catch let error as ChatTemplateParameters.InvalidParameter {
            #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 400)
            #expect(HTTPHandler.openAIErrorType(for: error) == "invalid_request_error")
            #expect(HTTPHandler.openResponsesErrorCode(for: error) == "invalid_request_error")
            #expect(HTTPHandler.anthropicErrorType(for: error) == "invalid_request_error")
            #expect(HTTPHandler.ollamaErrorType(for: error) == "invalid_request_error")
        }
        #expect(await capture.values().isEmpty)
        // The mapping must not turn arbitrary NSError(code:400) into client errors.
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: NSError(domain: "unrelated", code: 400)).code == 500)
    }

    @Test(arguments: [true, false])
    func realHTTPChannelsRejectInvalidParametersBeforeStreamingOrInference(streaming: Bool) async throws {
        let capture = Capture()
        let server = try await startChatStreamingTestServer(with: engine(capture), trustLoopback: true)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            for path in ["/v1/chat/completions", "/v1/responses"] {
                for invalidField in ["repetition_penalty", "chat_template_kwargs"] {
                    var body: [String: Any] = ["model": "carrier", "stream": streaming, "seed": 0]
                    if path.hasSuffix("responses") { body["input"] = "fixture" }
                    else { body["messages"] = [["role": "user", "content": "fixture"]] }
                    if invalidField == "repetition_penalty" { body[invalidField] = 0 }
                    else { body[invalidField] = ["messages": []] as [String: [String]] }
                    var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 10
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("false", forHTTPHeaderField: "X-Persist")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (data, response) = try await session.data(for: request)
                    let http = try #require(response as? HTTPURLResponse)
                    #expect(http.statusCode == 400, "\(path) \(invalidField) stream=\(streaming)")
                    #expect(http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)
                    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let error = try #require(object["error"] as? [String: Any])
                    #expect(error[path.hasSuffix("responses") ? "code" : "type"] as? String == "invalid_request_error")
                    let text = String(decoding: data, as: UTF8.self)
                    #expect((error["message"] as? String)?.contains(invalidField) == true,
                        "\(path) \(invalidField) stream=\(streaming) response=\(text)")
                    #expect(!text.contains("data: ") && !text.contains("response.completed"))
                    #expect(!text.contains("[DONE]"))
                    #expect(await capture.values().isEmpty)
                }
            }
            let marker = "private-fixture-body-must-not-echo"
            let malformedBodies = [
                Data("{\"stream\":\(streaming),\"content\":\"\(marker)".utf8),
                try JSONSerialization.data(withJSONObject: ["model": "carrier", "messages": [],
                    "stream": streaming, "temperature": marker]),
            ]
            for body in malformedBodies {
                var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/v1/chat/completions")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("false", forHTTPHeaderField: "X-Persist")
                request.httpBody = body
                let (data, response) = try await session.data(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 400)
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let error = try #require(object["error"] as? [String: Any])
                #expect(error["message"] as? String == "Invalid request format")
                #expect(error["type"] as? String == "invalid_request_error")
                #expect(!String(decoding: data, as: UTF8.self).contains(marker))
                #expect(await capture.values().isEmpty)
            }
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func chatDecodeErrorsExposeOnlyKnownParameterValidation() throws {
        let invalidFields: [[String: Any]] = [
            ["repetition_penalty": 0],
            ["chat_template_kwargs": ["messages": []] as [String: [String]]],
        ]
        for fields in invalidFields {
            do {
                _ = try chat(fields)
                Issue.record("Invalid parameter unexpectedly decoded")
            } catch {
                let message = RequestValidator.chatRequestDecodingMessage(for: error)
                #expect(message.contains(fields.keys.first!))
                #expect(message != "Invalid request format")
            }
        }
        let secret = "private-fixture-contents-must-not-echo"
        let unrelatedErrors: [Error] = [
            NSError(domain: "fixture", code: 400, userInfo: [NSLocalizedDescriptionKey: secret]),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: secret)),
            DecodingError.dataCorrupted(.init(codingPath: [FixtureCodingKey(stringValue: "repetition_penalty")],
                debugDescription: secret)),
            DecodingError.dataCorrupted(.init(codingPath: [FixtureCodingKey(stringValue: "other")],
                debugDescription: "Parameter 'repetition_penalty' must be a finite number greater than zero.")),
        ]
        for error in unrelatedErrors {
            #expect(RequestValidator.chatRequestDecodingMessage(for: error) == "Invalid request format")
            #expect(!RequestValidator.chatRequestDecodingMessage(for: error).contains(secret))
        }
        for data in [Data("{\"content\":\"\(secret)".utf8),
            try JSONSerialization.data(withJSONObject: ["model": "carrier", "messages": [], "temperature": secret])] {
            do {
                _ = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
                Issue.record("Malformed fixture unexpectedly decoded")
            } catch {
                #expect(RequestValidator.chatRequestDecodingMessage(for: error) == "Invalid request format")
            }
        }
    }

    private struct FixtureCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

}
