import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("API thinking budget: wire, engine, and report", .timeLimit(.minutes(1)))
struct ReasoningBudgetRequestTests {
    private func chatRequest(_ fields: String) throws -> ChatCompletionRequest {
        let json = #"{"model":"m","messages":[{"role":"user","content":"hi"}]"# + fields + "}"
        return try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
    }

    // MARK: - Wire

    @Test func chatCompletionsAcceptsBothSpellings() throws {
        #expect(try chatRequest(#","thinking_token_budget":300"#).thinking_token_budget == 300)
        #expect(try chatRequest(#","reasoning":{"max_tokens":200}"#).thinking_token_budget == 200)
        #expect(
            try chatRequest(#","thinking_token_budget":300,"reasoning":{"max_tokens":200}"#).thinking_token_budget
                == 300)
        #expect(try chatRequest(#","reasoning":{"effort":"low"}"#).thinking_token_budget == nil)
        #expect(try chatRequest("").thinking_token_budget == nil)
    }

    @Test(arguments: [#","thinking_token_budget":0"#, #","thinking_token_budget":-1"#, #","reasoning":{"max_tokens":0}"#])
    func chatCompletionsRejectsNonPositiveBudget(_ fields: String) {
        do {
            _ = try chatRequest(fields)
            Issue.record("Non-positive budget must not decode")
        } catch {
            #expect(RequestValidator.chatRequestDecodingMessage(for: error)
                == RequestValidator.reasoningBudgetValidationMessage)
        }
    }

    @Test func copiesKeepTheBudget() throws {
        let request = try chatRequest(#","thinking_token_budget":512"#)
        #expect(request.withModel("other").thinking_token_budget == 512)
        #expect(request.withContext(messages: request.messages, tools: nil, toolChoice: nil).thinking_token_budget == 512)
    }

    @Test func budgetNeverReachesAnUpstreamWire() throws {
        let chat = try chatRequest(#","thinking_token_budget":512"#)
        let chatBody = String(decoding: try JSONEncoder().encode(chat), as: UTF8.self)
        #expect(!chatBody.contains("thinking_token_budget") && !chatBody.contains("512"))

        let config = OpenResponsesReasoningConfig(effort: "low", max_tokens: 512)
        let configBody = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(configBody.contains("\"effort\":\"low\""))
        #expect(!configBody.contains("max_tokens"))
    }

    @Test func responsesBudgetReachesGenerationOptions() throws {
        func decode(_ reasoning: String) throws -> OpenResponsesRequest {
            try JSONDecoder().decode(OpenResponsesRequest.self,
                from: Data((#"{"model":"m","input":"go""# + reasoning + "}").utf8))
        }
        let budgeted = try decode(#","reasoning":{"effort":"high","max_tokens":256}"#)
        #expect(try budgeted.toResponsesInferenceRequest().generation.reasoningBudgetTokens == 256)
        #expect(try budgeted.toChatCompletionRequest().thinking_token_budget == 256)
        #expect(try decode("").toResponsesInferenceRequest().generation.reasoningBudgetTokens == nil)
        #expect(throws: (any Error).self) {
            try decode(#","reasoning":{"max_tokens":0}"#).toResponsesInferenceRequest()
        }
    }

    @Test func internalRequestRoundTripsTheBudget() throws {
        let canonical = ResponsesInferenceRequest(chatCompletion: try chatRequest(#","thinking_token_budget":128"#))
        #expect(canonical.generation.reasoningBudgetTokens == 128)
        #expect(canonical.chatCompletionsCompatibilityRequest().thinking_token_budget == 128)
        let none = ResponsesInferenceRequest(chatCompletion: try chatRequest(""))
        #expect(none.generation.reasoningBudgetTokens == nil)
    }

    // MARK: - Engine hand-off

    private actor Capture {
        var parameters: GenerationParameters?
        func record(_ value: GenerationParameters) { parameters = value }
    }

    private struct UnexpectedLegacyCall: Error {}

    private struct BudgetService: ResponsesGenerationService {
        let capture: Capture
        var report: ReasoningBudgetReport?
        var id: String { "budget-fixture" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?)
            async throws -> String
        { throw UnexpectedLegacyCall() }
        func streamDeltas(
            messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?,
            stopSequences: [String]
        ) async throws -> AsyncThrowingStream<String, Error> { throw UnexpectedLegacyCall() }
        func streamResponses(
            messages: [ChatMessage], parameters: GenerationParameters, stopSequences: [String],
            tools: [OsaurusCore.Tool], toolChoice: ToolChoiceOption?, requestedModel: String?
        ) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            await capture.record(parameters)
            let report = report
            let events = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
                c.yield(.inputTokenCount(12))
                if let report { c.yield(.reasoningBudget(report)) }
                c.yield(.tokens("answer"))
                c.yield(.completionInfo(tokenCount: 3, tokensPerSecond: 10, unclosedReasoning: false,
                    stopReason: "stop", promptTokensPerSecond: 100, mtp: nil))
                c.finish()
            }
            return ResponsesGenerationStream.native(events, responseID: "resp_budget")
        }
    }

    private func run(_ budget: Int?, report: ReasoningBudgetReport? = nil) async throws
        -> (GenerationParameters?, ResponsesGenerationCompletion?)
    {
        let capture = Capture()
        let engine = ChatEngine(services: [BudgetService(capture: capture, report: report)],
            installedModelsProvider: { [] }, remoteServicesProvider: { [] })
        var request = ResponsesInferenceRequest(model: "budget-fixture", input: [ChatMessage(role: "user", content: "hi")])
        request.generation.reasoningBudgetTokens = budget
        var completion: ResponsesGenerationCompletion?
        for try await event in try await engine.streamResponses(request: request) {
            if case .responseCompleted(let value) = event { completion = value }
        }
        return (await capture.parameters, completion)
    }

    @Test func chatEngineHandsTheBudgetToTheRuntime() async throws {
        let report = ReasoningBudgetReport(requestedTokens: 300, applied: true)
        let (params, completion) = try await run(300, report: report)
        #expect(params?.reasoningBudgetTokens == 300)
        #expect(completion?.reasoningBudget == report)
    }

    @Test func noBudgetStaysNilAllTheWayDown() async throws {
        let (params, completion) = try await run(nil)
        #expect(params != nil)
        #expect(params?.reasoningBudgetTokens == nil)
        #expect(completion?.reasoningBudget == nil)
    }

    @Test func chatEngineRejectsNonPositiveBudgetBeforeDispatch() async {
        await #expect(throws: (any Error).self) { _ = try await run(0) }
    }

    // MARK: - Runtime report

    @Test func mapperAnnouncesTheReportBeforeOutput() async throws {
        let report = ReasoningBudgetReport(requestedTokens: 64, applied: false)
        let source = AsyncStream<Generation> { c in
            c.yield(.chunk("ok"))
            c.yield(.info(GenerateCompletionInfo(promptTokenCount: 4, generationTokenCount: 1,
                promptTime: 0, generationTime: 0, stopReason: .stop)))
            c.finish()
        }
        var events: [ModelRuntimeEvent] = []
        for try await event in GenerationEventMapper.map(events: source, promptTokenCount: 4, reasoningBudget: report) {
            events.append(event)
        }
        guard events.count > 1, case .reasoningBudget(let seen) = events[1] else {
            Issue.record("Expected the budget report right after the input count, got \(events)")
            return
        }
        #expect(seen == report)
        let silent = AsyncStream<Generation> { c in
            c.yield(.info(GenerateCompletionInfo(promptTokenCount: 4, generationTokenCount: 0,
                promptTime: 0, generationTime: 0, stopReason: .stop)))
            c.finish()
        }
        for try await event in GenerationEventMapper.map(events: silent) {
            if case .reasoningBudget = event { Issue.record("No budget requested, no report") }
        }
    }

    @Test func requestedBudgetWithoutRuntimeReportIsNotApplied() throws {
        var accumulator = ResponsesGenerationAccumulator()
        try accumulator.consume(.outputTextDelta("answer"))
        try accumulator.consume(.responseCompleted(.init(responseID: "resp_remote", status: .completed,
            functionCalls: [], tokenCount: 3, tokensPerSecond: 10, unclosedReasoning: false,
            stopReason: "stop", promptTokensPerSecond: nil, mtp: nil, inputTokenCount: 5)))
        let result = try accumulator.result()
        #expect(result.reasoningBudgetReport(requestedTokens: nil) == nil)
        #expect(result.reasoningBudgetReport(requestedTokens: 300)
            == ReasoningBudgetReport(requestedTokens: 300, applied: false))
        #expect(result.generationMetrics(requestedReasoningBudget: nil)["reasoning_budget"] == nil)
        #expect(result.generationMetrics(requestedReasoningBudget: 300)["reasoning_budget"]
            == .object(["requested_tokens": .number(300), "applied": .bool(false)]))
        #expect(result.openResponsesResponse(responseID: "r", model: "m").generation_metrics == nil)
        #expect(result.openResponsesResponse(responseID: "r", model: "m", requestedReasoningBudget: 300)
            .generation_metrics?["reasoning_budget"] != nil)
    }

    @Test func mtpFallbackNamesTheBudget() {
        #expect(
            MLXBatchAdapter.nativeMTPFallbackReason(
                requestedDraftStrategy: .nativeMTP(depth: 2), effectiveDraftStrategy: nil,
                promptTokenCount: 4096, coldWarmup: true, reasoningBudgetArmed: true
            ) == "reasoning_budget")
    }

    // MARK: - vmlx arm check

    private struct VocabTokenizer: MLXLMCommon.Tokenizer {
        let vocab: [String: Int]
        let tail: String
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tail }
        func convertTokenToId(_ token: String) -> Int? { vocab[token] ?? 0 }
        func convertIdToToken(_ id: Int) -> String? { vocab.first { $0.value == id }?.key ?? "<unk>" }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { "<unk>" }
        func applyChatTemplate(
            messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] { [] }
    }

    @Test func armsOnlyWhenTheBundleCanCloseReasoning() {
        let think = ["<think>": 7, "</think>": 8]
        func arms(_ vocab: [String: Int], tail: String) -> Bool {
            MLXBatchAdapter.reasoningBudgetArms(tokenCount: 300, promptTokens: [1, 2, 3],
                tokenizer: VocabTokenizer(vocab: vocab, tail: tail))
        }
        #expect(arms(think, tail: "<|assistant|><think>\n"), "Primed tail counts at once")
        #expect(arms(think, tail: "<|assistant|>"), "Self-opening family arms on the open tag")
        #expect(!arms(["</think>": 8], tail: "<|assistant|>"), "No way to start a block")
        #expect(!arms([:], tail: "<|assistant|><think>"), "No close tag in vocab")
        #expect(!MLXBatchAdapter.reasoningBudgetArms(tokenCount: 0, promptTokens: [1],
            tokenizer: VocabTokenizer(vocab: think, tail: "<think>")))
    }
}

@Suite("API thinking budget: HTTP report", .serialized, .timeLimit(.minutes(2)))
struct ReasoningBudgetHTTPTests {
    private actor Engine: ChatEngineProtocol {
        let events: [ResponsesGenerationEvent]
        private(set) var requests: [ResponsesInferenceRequest] = []
        init(_ events: [ResponsesGenerationEvent]) { self.events = events }
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            requests.append(request)
            let events = events
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
            }
        }
        func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
            throw NSError(domain: "unexpected-legacy-stream", code: 998)
        }
        func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
            throw NSError(domain: "unexpected-legacy-completion", code: 997)
        }
    }

    private static func events(report: ReasoningBudgetReport?) -> [ResponsesGenerationEvent] {
        var completion = ResponsesGenerationCompletion(responseID: "resp_engine", status: .completed,
            functionCalls: [], tokenCount: 17, tokensPerSecond: 40, unclosedReasoning: false,
            stopReason: "stop", promptTokensPerSecond: nil, mtp: nil, inputTokenCount: 113)
        completion.reasoningBudget = report
        return [.inputTokenCount(113), .reasoningDelta("brief"), .outputTextDelta("answer"),
            .responseCompleted(completion)]
    }

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

    private func json(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private func sseObjects(_ body: String) -> [[String: Any]] {
        body.components(separatedBy: .newlines).filter { $0.hasPrefix("data: ") }
            .compactMap { json(String($0.dropFirst(6))) }
    }

    /// The `reasoning_budget` objects found anywhere in the body.
    private func reports(_ body: String, streaming: Bool) -> [[String: Any]] {
        func find(_ value: Any) -> [[String: Any]] {
            if let object = value as? [String: Any] {
                var found = (object["reasoning_budget"] as? [String: Any]).map { [$0] } ?? []
                for (key, nested) in object where key != "reasoning_budget" { found += find(nested) }
                return found
            }
            if let array = value as? [Any] { return array.flatMap(find) }
            return []
        }
        return streaming ? sseObjects(body).flatMap(find) : json(body).map(find) ?? []
    }

    private static func endpoint(_ index: Int) -> (path: String, budgetFields: [String: Any], base: [String: Any]) {
        let chat: [String: Any] = ["model": "fixture", "messages": [["role": "user", "content": "go"]]]
        switch index {
        case 0: return ("/chat/completions", ["thinking_token_budget": 300], chat)
        case 1: return ("/chat/completions", ["reasoning": ["max_tokens": 300]], chat)
        case 2: return ("/responses", ["reasoning": ["max_tokens": 300]], ["model": "fixture", "input": "go"])
        default:
            return ("/messages", ["thinking": ["type": "enabled", "budget_tokens": 300]],
                ["model": "fixture", "max_tokens": 1024, "messages": [["role": "user", "content": "go"]]])
        }
    }

    @Test(arguments: [0, 1, 2, 3], [false, true])
    func everyEndpointReportsWhetherTheBudgetApplied(_ index: Int, _ streaming: Bool) async throws {
        let endpoint = Self.endpoint(index)
        for applied in [true, false] {
            let engine = Engine(Self.events(report: applied
                ? ReasoningBudgetReport(requestedTokens: 300, applied: true) : nil))
            let server = try await startChatStreamingTestServer(with: engine)
            defer { Task { await server.shutdown() } }
            var body = endpoint.base.merging(endpoint.budgetFields) { $1 }
            body["stream"] = streaming
            let (status, text) = try await post(server, path: endpoint.path, body: body)
            #expect(status == 200, "\(endpoint.path) \(text)")
            let found = reports(text, streaming: streaming)
            #expect(found.count == 1, "\(endpoint.path) streaming=\(streaming): \(text)")
            #expect(found.first?["requested_tokens"] as? Int == 300)
            #expect(found.first?["applied"] as? Bool == applied)
            #expect(await engine.requests.first?.generation.reasoningBudgetTokens == 300)
        }
    }

    @Test(arguments: [0, 2, 3], [false, true])
    func noBudgetMeansNoReport(_ index: Int, _ streaming: Bool) async throws {
        let endpoint = Self.endpoint(index)
        let engine = Engine(Self.events(report: nil))
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        var body = endpoint.base
        body["stream"] = streaming
        let (status, text) = try await post(server, path: endpoint.path, body: body)
        #expect(status == 200)
        #expect(reports(text, streaming: streaming).isEmpty, "\(endpoint.path): \(text)")
        #expect(!text.contains("reasoning_budget"))
        #expect(await engine.requests.first?.generation.reasoningBudgetTokens == nil)
    }

    @Test(arguments: [0, 2, 3], [0, -4])
    func nonPositiveBudgetIsRejectedBeforeInference(_ index: Int, _ budget: Int) async throws {
        let endpoint = Self.endpoint(index)
        let path = endpoint.path
        var body = endpoint.base
        switch index {
        case 0: body["thinking_token_budget"] = budget
        case 2: body["reasoning"] = ["max_tokens": budget]
        default: body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        }
        let engine = Engine(Self.events(report: nil))
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        let (status, text) = try await post(server, path: path, body: body)
        #expect(status == 400, "\(path): \(text)")
        #expect(await engine.requests.isEmpty)
    }
}
