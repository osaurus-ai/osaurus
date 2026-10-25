import Foundation
import Testing

@testable import OsaurusCore

@Suite("Responses engine routing and compatibility", .timeLimit(.minutes(1)))
struct ResponsesEngineTests {
    private actor Capture {
        var nativeCalls = 0
        var legacyCalls = 0
        var parameters: GenerationParameters?
        var messages: [ChatMessage] = []
        var tools: [Tool] = []
        var receivedToolChoice = false
        func native(
            _ messages: [ChatMessage],
            _ parameters: GenerationParameters,
            _ tools: [Tool],
            _ choice: ToolChoiceOption?
        ) {
            nativeCalls += 1
            self.messages = messages
            self.parameters = parameters
            self.tools = tools
            receivedToolChoice = choice != nil
        }
        func legacy() { legacyCalls += 1 }
    }

    private struct UnexpectedLegacyCall: Error {}

    private struct NativeService: ResponsesGenerationService {
        let capture: Capture
        var id: String { "responses-fixture" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?
        ) async throws -> String { throw UnexpectedLegacyCall() }
        func streamDeltas(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?,
            stopSequences: [String]
        ) async throws -> AsyncThrowingStream<String, Error> {
            await capture.legacy()
            throw UnexpectedLegacyCall()
        }
        func streamResponses(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            stopSequences: [String],
            tools: [Tool],
            toolChoice: ToolChoiceOption?,
            requestedModel: String?
        ) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            await capture.native(messages, parameters, tools, toolChoice)
            let events = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
                c.yield(.inputTokenCount(517))
                c.yield(.reasoning("plan"))
                c.yield(.tokens("answer"))
                if !tools.isEmpty {
                    c.yield(.toolInvocation(name: "lookup", argsJSON: #"{"key":"a"}"#))
                    c.yield(.toolInvocation(name: "lookup", argsJSON: #"{"key":"b"}"#))
                }
                c.yield(
                    .completionInfo(
                        tokenCount: 42,
                        tokensPerSecond: 21.123456789,
                        unclosedReasoning: false,
                        stopReason: tools.isEmpty ? "stop" : "tool_calls",
                        promptTokensPerSecond: 1024.987654321,
                        mtp: nil
                    )
                )
                c.finish()
            }
            return ResponsesGenerationStream.native(events, responseID: "resp_fixture")
        }
    }

    private struct LegacyService: ModelService {
        let capture: Capture
        var failureCode: Int? = nil
        var emitPartial = false
        var id: String { "responses-fixture" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?
        ) async throws -> String { throw UnexpectedLegacyCall() }
        func streamDeltas(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?,
            stopSequences: [String]
        ) async throws -> AsyncThrowingStream<String, Error> {
            await capture.legacy()
            return AsyncThrowingStream { c in
                if emitPartial { c.yield("partial") }
                if let failureCode {
                    c.finish(throwing: NSError(domain: "provider-fixture", code: failureCode))
                    return
                }
                c.yield(
                    StreamingResponsesOutputItemHint.encode(
                        .object([
                            "type": .string("message"), "id": .string("msg_fixture"),
                            "phase": .string("commentary"), "future": .object(["preserved": .bool(true)]),
                        ])
                    )
                )
                c.yield(StreamingReasoningItemHint.encode(id: "rs_fixture", encryptedContent: "opaque"))
                c.yield(
                    StreamingStatsHint.encode(
                        tokenCount: 19,
                        tokensPerSecond: 31.25,
                        stopReason: "tool_calls",
                        inputTokenCount: 151,
                        cachedInputTokenCount: 100
                    )
                )
                c.finish(
                    throwing: ServiceToolInvocations(invocations: [
                        ServiceToolInvocation(
                            toolName: "lookup",
                            jsonArguments: #"{"key":"a"}"#,
                            toolCallId: "call_a",
                            geminiThoughtSignature: "signature"
                        ),
                        ServiceToolInvocation(
                            toolName: "lookup",
                            jsonArguments: #"{"key":"b"}"#,
                            toolCallId: "call_b"
                        ),
                    ])
                )
            }
        }
    }

    private let tool = Tool(
        type: "function",
        function: ToolFunction(name: "lookup", description: nil, parameters: nil)
    )

    @Test(arguments: [false, true])
    func nativeRoutePreservesInputAndParametersWithoutLegacySerialization(_ disableTools: Bool) async throws {
        let capture = Capture()
        let engine: any ChatEngineProtocol = ChatEngine(
            services: [NativeService(capture: capture)],
            installedModelsProvider: { [] },
            remoteServicesProvider: { [] }
        )
        let samples = LocalAudioSamples(samples: [0.5, -0.25], sampleRate: 16000)
        let message = ChatMessage(
            role: "user",
            text: "inspect",
            imageData: [],
            audios: [(data: Data([1, 2]), format: "wav")],
            localAudioSamples: [samples],
            videos: []
        )
        var request = ResponsesInferenceRequest(
            model: "responses-fixture",
            input: [message],
            generation: ResponsesGenerationOptions(topK: 37, minP: 0.03),
            tools: [tool]
        )
        if disableTools { request.toolChoice = ToolChoiceOption.none }
        request.context.admissionPositionLimit = 4096
        request.context.admissionOutputTokensAreImplicit = true
        request.context.backgroundModelLoad = true
        request.context.cacheStableSystemPrefix = "byte exact prefix"
        var terminal: ResponsesGenerationCompletion?
        var drained = false
        for try await event in try await engine.streamResponses(request: request) {
            if case .responseCompleted(let value) = event { terminal = value }
            if case .drained = event { drained = true }
        }
        let completion = try #require(terminal)
        #expect(await capture.nativeCalls == 1)
        #expect(await capture.legacyCalls == 0)
        #expect(await capture.receivedToolChoice == false)
        #expect(await capture.messages.first?.localAudioSamples == [samples])
        let params = try #require(await capture.parameters)
        #expect(params.maxTokensExplicit == false)
        #expect(params.temperature == nil)
        #expect(params.topKOverride == 37)
        #expect(params.minPOverride == 0.03)
        #expect(params.admissionPositionLimit == 4096)
        #expect(params.admissionOutputTokensAreImplicit)
        #expect(params.cacheStableSystemPrefix == "byte exact prefix")
        #expect(params.loadIntent == .background)
        #expect(completion.functionCalls.count == (disableTools ? 0 : 2))
        #expect(completion.inputTokenCount == 517)
        #expect(completion.tokensPerSecond == 21.123456789)
        #expect(completion.promptTokensPerSecond == 1024.987654321)
        #expect(drained)
    }

    @Test func compatibilityKeepsRawItemsCacheUsageAndWholeCallBatch() async throws {
        let capture = Capture()
        let engine = ChatEngine(
            services: [LegacyService(capture: capture)],
            installedModelsProvider: { [] },
            remoteServicesProvider: { [] }
        )
        let request = ResponsesInferenceRequest(model: "responses-fixture", input: [])
        var raw: JSONValue?
        var reasoningID: String?
        var completion: ResponsesGenerationCompletion?
        var closed = false
        var claimedNativeDrain = false
        for try await event in try await engine.streamResponses(request: request) {
            switch event {
            case .providerOutputItem(let item): raw = item
            case .reasoningItem(let item): reasoningID = item.id; #expect(item.encryptedContent == "opaque")
            case .responseCompleted(let value): completion = value
            case .compatibilityStreamClosed: closed = true
            case .drained: claimedNativeDrain = true
            default: break
            }
        }
        let result = try #require(completion)
        #expect(result.dispatchableFunctionCalls.map(\.callID) == ["call_a", "call_b"])
        #expect(result.functionCalls.first?.geminiThoughtSignature == "signature")
        #expect(result.inputTokenCount == 151)
        #expect(result.cachedInputTokenCount == 100)
        #expect(result.tokenCount == 19)
        #expect(reasoningID == "rs_fixture")
        #expect(
            raw
                == .object([
                    "type": .string("message"), "id": .string("msg_fixture"),
                    "phase": .string("commentary"), "future": .object(["preserved": .bool(true)]),
                ])
        )
        #expect(await capture.legacyCalls == 1)
        #expect(closed)
        #expect(!claimedNativeDrain)
    }

    @Test(arguments: [401, 404, 429, 500], [false, true])
    func providerFailureIsNeverReplayedOrCompleted(_ code: Int, _ partial: Bool) async {
        let capture = Capture()
        let engine = ChatEngine(
            services: [LegacyService(capture: capture, failureCode: code, emitPartial: partial)],
            installedModelsProvider: { [] },
            remoteServicesProvider: { [] }
        )
        var completed = false
        var text = ""
        do {
            let stream = try await engine.streamResponses(
                request:
                    ResponsesInferenceRequest(model: "responses-fixture", input: [])
            )
            for try await event in stream {
                if case .outputTextDelta(let value) = event { text += value }
                if case .responseCompleted = event { completed = true }
            }
            Issue.record("Expected provider failure")
        } catch {
            #expect((error as NSError).domain == "provider-fixture")
            #expect((error as NSError).code == code)
        }
        #expect(!completed)
        #expect(text == (partial ? "partial" : ""))
        #expect(await capture.legacyCalls == 1)
    }

    @Test func compatibilityDoesNotInventMissingUsageOrSpeed() async throws {
        let source = AsyncThrowingStream<String, Error> { $0.finish() }
        var result: ResponsesGenerationCompletion?
        for try await event in ResponsesGenerationStream.compatibility(source) {
            if case .responseCompleted(let value) = event { result = value }
        }
        let completion = try #require(result)
        #expect(completion.tokenCount == nil)
        #expect(completion.tokensPerSecond == nil)
        #expect(completion.promptTokensPerSecond == nil)
        #expect(completion.inputTokenCount == nil)
        #expect(completion.cachedInputTokenCount == nil)
    }

    @Test func oneShotCollectionUsesTheTypedEngineProtocolEntryPoint() async throws {
        let capture = Capture()
        let engine: any ResponsesEngineProtocol = ChatEngine(
            services: [NativeService(capture: capture)],
            installedModelsProvider: { [] },
            remoteServicesProvider: { [] }
        )
        let result = try await engine.completeResponse(
            request:
                ResponsesInferenceRequest(model: "responses-fixture", input: []),
            endAt: .streamEnd
        )
        #expect(await capture.nativeCalls == 1)
        #expect(await capture.legacyCalls == 0)
        #expect(result.text == "answer")
        #expect(result.reasoning == "plan")
        #expect(result.inputTokenCount == 517)
        #expect(result.completion.tokensPerSecond == 21.123456789)
        #expect(try result.completedAssistantInput().content == "answer")
    }

    @Test func compatibilityLengthStopCannotDispatchParsedCalls() async throws {
        let source = AsyncThrowingStream<String, Error> { c in
            c.yield(StreamingStatsHint.encode(tokenCount: 10, tokensPerSecond: 20, stopReason: "length"))
            c.finish(throwing: ServiceToolInvocation(toolName: "write_file", jsonArguments: "{}", toolCallId: "call_x"))
        }
        var result: ResponsesGenerationCompletion?
        for try await event in ResponsesGenerationStream.compatibility(source) {
            if case .responseCompleted(let value) = event { result = value }
        }
        let completion = try #require(result)
        #expect(completion.functionCalls.count == 1)
        #expect(completion.dispatchableFunctionCalls.isEmpty)
        #expect(completion.stopReason == "length")
    }

    @Test func unknownCompatibilityMetadataStaysOpaqueAndNeverBecomesVisibleOutput() async throws {
        let raw = "\u{FFFE}unknown:private protocol payload"
        let source = AsyncThrowingStream<String, Error> { c in
            c.yield(raw)
            c.yield(StreamingInputTokenHint.encode(2072))
            c.finish()
        }
        var metadata: [String] = []
        var inputTokens: Int?
        for try await event in ResponsesGenerationStream.compatibility(source) {
            if case .compatibilityMetadata(let value) = event { metadata.append(value) }
            if case .inputTokenCount(let count) = event { inputTokens = count }
            if case .outputTextDelta = event { Issue.record("Reserved metadata became visible output") }
        }
        #expect(metadata == [raw])
        #expect(inputTokens == 2072)
    }
}
