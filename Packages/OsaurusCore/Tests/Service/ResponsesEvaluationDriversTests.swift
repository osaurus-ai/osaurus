import Foundation
import Testing

@testable import OsaurusCore

@Suite("Responses evaluation driver continuity", .timeLimit(.minutes(1)))
@MainActor
struct ResponsesEvaluationDriversTests {
    private actor Engine: ResponsesEngineProtocol {
        let rows: [[ResponsesGenerationEvent]]
        private(set) var requests: [ResponsesInferenceRequest] = []
        init(_ rows: [[ResponsesGenerationEvent]]) { self.rows = rows }
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            let index = requests.count
            requests.append(request)
            guard index < rows.count else { throw NSError(domain: "unexpected replay", code: 999) }
            let events = rows[index]
            return AsyncThrowingStream { c in
                for event in events { c.yield(event) }
                c.finish()
            }
        }
    }

    private let raw: JSONValue = .object([
        "type": .string("message"), "id": .string("msg_eval"), "phase": .string("commentary"),
        "future": .object(["keep": .bool(true)]),
    ])

    private func row(
        _ text: String, status: ResponsesGenerationCompletion.Status = .completed,
        measured: Bool = true
    ) -> [ResponsesGenerationEvent] {
        [
            .reasoningDelta("reasoning"), .outputTextDelta(text), .providerOutputItem(raw),
            .reasoningItem(.init(id: "rs_eval", encryptedContent: "opaque")),
            .responseCompleted(.init(
                responseID: "resp_eval", status: status, functionCalls: [],
                tokenCount: measured ? 17 : nil, tokensPerSecond: measured ? 43.123456789 : nil,
                unclosedReasoning: status == .incomplete,
                stopReason: status == .incomplete ? "length" : "stop", promptTokensPerSecond: nil, mtp: nil
            )),
            .drained,
        ]
    }

    @Test func reasoningMultiTurnKeepsRawItemsReasoningAndBundleDefaults() async throws {
        let engine = Engine([row("first", measured: false), row("second")])
        let result = await ReasoningChannelEvaluator.runConversation(
            queries: ["one", "two"], model: "selected-eval-model", maxTokens: 192,
            supportsThinking: true, engine: engine
        )
        #expect(result.error == nil)
        #expect(result.turns.map(\.visibleText) == ["first", "second"])
        #expect(result.turns.first?.tokenCount == nil)
        #expect(result.turns.first?.decodeTokensPerSecond == nil)
        #expect(result.turns.last?.decodeTokensPerSecond == 43.123456789)
        let requests = await engine.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.model == "selected-eval-model" && $0.generation.temperature == nil })
        #expect(requests.allSatisfy { $0.generation.maxOutputTokens == 192 && $0.generation.topK == nil })
        #expect(requests[0].sessionID == requests[1].sessionID)
        let assistant = try #require(requests[1].input.first { $0.role == "assistant" })
        #expect(assistant.responses_output_items == [raw])
        #expect(assistant.reasoning_content == "reasoning")
        #expect(assistant.reasoning_item_id == "rs_eval")
        #expect(assistant.reasoning_encrypted == "opaque")
    }

    @Test func memoryInjectionIsTransientAndMetricsAndProviderHistorySurvive() async throws {
        let engine = Engine([row("first"), row("second", measured: false)])
        let result = await MemoryRecallEvaluator.runConversation(
            queries: ["one", "two"], agentId: "eval-agent", model: "selected-eval-model", maxTokens: 96,
            engine: engine, memorySectionProvider: { agent, query in "memory-\(agent)-\(query)" }
        )
        #expect(result.error == nil)
        #expect(result.turns.count == 2)
        #expect(result.turns.allSatisfy { $0.memoryInjected })
        #expect(result.turns.first?.decodeTokensPerSecond == 43.123456789)
        #expect(result.turns.last?.decodeTokensPerSecond == nil)
        let requests = await engine.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.generation.temperature == nil && $0.model == "selected-eval-model" })
        #expect(requests[0].input.first?.content?.contains("memory-eval-agent-one") == true)
        #expect(requests[1].input.first?.content == "one")
        #expect(requests[1].input.last?.content?.contains("memory-eval-agent-two") == true)
        let assistant = try #require(requests[1].input.first { $0.role == "assistant" })
        #expect(assistant.responses_output_items == [raw])
        #expect(assistant.reasoning_encrypted == "opaque")
        let restored = try JSONDecoder().decode(MemoryRecallTurn.self, from: JSONEncoder().encode(result.turns[0]))
        #expect(restored.tokenCount == 17)
        #expect(restored.decodeTokensPerSecond == 43.123456789)
        let old = try JSONDecoder().decode(MemoryRecallTurn.self,
            from: Data(#"{"visibleText":"old","memoryInjected":false}"#.utf8))
        #expect(old.tokenCount == nil && old.decodeTokensPerSecond == nil)
    }

    @Test(arguments: [false, true])
    func interruptedEvalRowsAreRetainedAndDoNotStartAnotherTurn(_ cancelled: Bool) async {
        let status: ResponsesGenerationCompletion.Status = cancelled ? .cancelled : .incomplete
        let reasoningEngine = Engine([row("partial", status: status)])
        let reasoning = await ReasoningChannelEvaluator.runConversation(
            queries: ["one", "two"], model: "selected-eval-model", maxTokens: 96,
            supportsThinking: true, engine: reasoningEngine
        )
        #expect(reasoning.error != nil)
        #expect(reasoning.turns.count == 1)
        #expect(reasoning.turns.first?.visibleText == "partial")
        #expect(await reasoningEngine.requests.count == 1)
        let memoryEngine = Engine([row("partial", status: status)])
        let memory = await MemoryRecallEvaluator.runConversation(
            queries: ["one", "two"], agentId: "eval-agent", model: "selected-eval-model", maxTokens: 96,
            engine: memoryEngine, memorySectionProvider: { _, _ in nil }
        )
        #expect(memory.error != nil)
        #expect(memory.turns.count == 1)
        #expect(await memoryEngine.requests.count == 1)
    }

    @Test func explicitEvaluationTemperatureIsPreserved() async {
        let engine = Engine([row("answer")])
        _ = await ReasoningChannelEvaluator.runConversation(
            queries: ["one"], model: "selected-eval-model", maxTokens: 96, temperature: 0,
            supportsThinking: true, engine: engine
        )
        #expect(await engine.requests.first?.generation.temperature == 0)
    }
}
