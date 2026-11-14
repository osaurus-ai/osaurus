import Foundation
import Testing

@testable import OsaurusCore

@Suite("Responses warm-up completion and cleanup", .timeLimit(.minutes(1)))
struct ResponsesModelWarmupTests {
    private actor Engine: ResponsesEngineProtocol {
        let events: [ResponsesGenerationEvent]
        private(set) var requests: [ResponsesInferenceRequest] = []

        init(_ events: [ResponsesGenerationEvent]) { self.events = events }

        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            requests.append(request)
            return AsyncThrowingStream { c in
                for event in events { c.yield(event) }
                c.finish()
            }
        }
    }

    private func completion(
        _ status: ResponsesGenerationCompletion.Status = .completed,
        stopReason: String = "stop"
    ) -> ResponsesGenerationEvent {
        .responseCompleted(.init(
            responseID: "resp_warmup", status: status, functionCalls: [],
            tokenCount: 8, tokensPerSecond: 42, unclosedReasoning: false,
            stopReason: stopReason, promptTokensPerSecond: 1000, mtp: nil
        ))
    }

    @Test(arguments: [0, 1, 2, 3])
    func failedOrUnfinishedGenerationIsNotReportedAsWarm(_ row: Int) async {
        let events: [ResponsesGenerationEvent]
        switch row {
        case 0: events = [completion(.cancelled), .drained]
        case 1: events = [completion(.incomplete, stopReason: "content_filter"), .drained]
        case 2: events = [completion(), .drainFailed("cache cleanup failed")]
        default: events = [.outputTextDelta("unfinished")]
        }
        let model = "warmup-failure-\(UUID().uuidString)"
        let engine = Engine(events)
        #expect(await ModelWarmup.warmUp(modelId: model, engine: engine) == false)
        // isWarm means attempted/in-flight, not a new retry policy.
        #expect(ModelWarmup.isWarm(model))
        #expect(await ModelWarmup.warmUp(modelId: model, engine: engine) == false)
        #expect(await engine.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func completedOrIntentionalLengthBoundedJITRunCanFinish(_ lengthBounded: Bool) async {
        let engine = Engine([
            completion(lengthBounded ? .incomplete : .completed, stopReason: lengthBounded ? "length" : "stop"),
            .drained,
        ])
        #expect(await ModelWarmup.warmUp(modelId: "warmup-success-\(UUID().uuidString)", engine: engine))
        let requests = await engine.requests
        #expect(requests.count == 1)
        #expect(requests.first?.generation.maxOutputTokens == 8)
        #expect(requests.first?.generation.temperature == 0)
        #expect(requests.first?.tools == nil)
    }
}
