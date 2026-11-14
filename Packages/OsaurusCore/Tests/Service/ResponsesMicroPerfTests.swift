import Foundation
import Testing

@testable import OsaurusCore

@Suite("Responses micro-perf timing and lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct ResponsesMicroPerfTests {
    private actor Engine: ResponsesEngineProtocol {
        let events: [ResponsesGenerationEvent]
        private(set) var request: ResponsesInferenceRequest?
        init(_ events: [ResponsesGenerationEvent]) { self.events = events }
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            self.request = request
            return AsyncThrowingStream { c in
                for event in events { c.yield(event) }
                c.finish()
            }
        }
    }

    private func completion(
        status: ResponsesGenerationCompletion.Status = .completed,
        measured: Bool = true
    ) -> ResponsesGenerationEvent {
        .responseCompleted(.init(
            responseID: "resp_perf", status: status, functionCalls: [],
            tokenCount: measured ? 29 : nil, tokensPerSecond: measured ? 52.123456789 : nil,
            unclosedReasoning: false, stopReason: status == .incomplete ? "length" : "stop",
            promptTokensPerSecond: measured ? 1024.987654321 : nil, mtp: nil
        ))
    }

    private func measure(_ engine: Engine) async throws -> MicroPerfSample {
        try await MicroPerfEvaluator.measureRep(
            engine: engine, model: "perf-model", prompt: "benchmark fixture", maxTokens: 48,
            sessionId: "perf-session", enableThinking: true
        )
    }

    @Test func metadataDoesNotStartFirstOutputOrCreateMissingMeasurements() async throws {
        let engine = Engine([
            .inputTokenCount(400),
            .prefillProgress(.init(stage: .prefill, completedUnitCount: 300, totalUnitCount: 400, detail: nil)),
            .compatibilityMetadata("future_metric"), .providerOutputItem(.object(["type": .string("reasoning")])),
            completion(measured: false), .drained,
        ])
        let result = try await measure(engine)
        #expect(result.ttftMs == nil)
        #expect(result.decodeTokensPerSecond == nil && result.prefillTokensPerSecond == nil)
        #expect(result.tokenCount == nil)
        #expect(result.contentChars == 0)
    }

    @Test func exactRuntimeRatesAreSeparateFromWallTimeAndReasoningCharacters() async throws {
        let engine = Engine([
            .reasoningDelta("plan"), .outputTextDelta("answer"), completion(), .drained,
        ])
        let result = try await measure(engine)
        #expect(result.ttftMs != nil)
        #expect(result.decodeTokensPerSecond == 52.123456789)
        #expect(result.prefillTokensPerSecond == 1024.987654321)
        #expect(result.tokenCount == 29 && result.contentChars == 6)
        let request = try #require(await engine.request)
        #expect(request.sessionID == "perf-session")
        #expect(request.generation.maxOutputTokens == 48)
        #expect(request.generation.temperature == 0) // explicit fixed-shape benchmark contract
        #expect(request.generation.topK == nil && request.generation.enableThinking == true)
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func cancellationMissingCompletionAndCleanupErrorsCannotBecomeSamples(_ row: Int) async {
        let events: [ResponsesGenerationEvent]
        switch row {
        case 0: events = [.reasoningDelta("partial")]
        case 1: events = [completion(status: .cancelled), .drained]
        case 2: events = [completion(), .drainFailed("cleanup failed")]
        case 3: events = [completion(), .outputTextDelta("late")]
        default: events = [.drained, completion()]
        }
        do {
            _ = try await measure(Engine(events))
            Issue.record("Invalid lifecycle became a speed sample")
        } catch is CancellationError {
            #expect(row == 1)
        } catch let error as ResponsesGenerationResult.CollectionError {
            switch (row, error) {
            case (0, .missingCompletion), (2, .drainFailed("cleanup failed")),
                (3, .outputAfterCompletion), (4, .drainBeforeCompletion): break
            default: Issue.record("Wrong lifecycle error: \(error)")
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func fixedDecodeCapIsABenchmarkSampleAndToolSyntaxIsGeneratedOutput() async throws {
        let engine = Engine([.reasoningDelta("plan"), completion(status: .incomplete), .drained])
        #expect(try await measure(engine).tokenCount == 29)
        #expect(ResponsesGenerationEvent.toolEnvelopeDelta("<tool_call>").isGeneratedOutput)
        #expect(ResponsesGenerationEvent.functionArgumentsPreview("{").isGeneratedOutput)
        #expect(!ResponsesGenerationEvent.functionPreviewReset.isGeneratedOutput)
        #expect(!ResponsesGenerationEvent.reasoningDelta("").isGeneratedOutput)
    }
}
