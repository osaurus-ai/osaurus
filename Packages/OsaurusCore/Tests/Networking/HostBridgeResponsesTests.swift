import Foundation
import Testing

@testable import OsaurusCore

@Suite("Host bridge uses Responses", .timeLimit(.minutes(1)))
struct HostBridgeResponsesTests {
    private actor Engine: ResponsesEngineProtocol {
        let stream: AsyncThrowingStream<ResponsesGenerationEvent, Error>
        private(set) var requests: [ResponsesInferenceRequest] = []

        init(_ stream: AsyncThrowingStream<ResponsesGenerationEvent, Error>) { self.stream = stream }

        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            requests.append(request)
            return stream
        }
    }

    private func completion(_ status: ResponsesGenerationCompletion.Status) -> ResponsesGenerationEvent {
        .responseCompleted(.init(
            responseID: "resp_bridge", status: status, functionCalls: [],
            tokenCount: nil, tokensPerSecond: nil, unclosedReasoning: false,
            stopReason: status == .incomplete ? "length" : "stop", promptTokensPerSecond: nil, mtp: nil
        ))
    }

    @Test func logicalTextCompletionPreservesDefaultsAndDoesNotWaitForProducerTail() async throws {
        let (stream, producer) = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
        let engine = Engine(stream)
        producer.yield(.reasoningDelta("private reasoning"))
        producer.yield(.outputTextDelta("Visible answer"))
        producer.yield(completion(.completed))
        let answer = try await HostBridgeInference.completeContent(
            model: "bridge-model", input: [ChatMessage(role: "user", content: "hello")], engine: engine
        )
        #expect(answer == "Visible answer")
        let request = try #require(await engine.requests.first)
        #expect(request.model == "bridge-model")
        #expect(request.input.first?.content == "hello")
        #expect(request.generation.temperature == nil)
        #expect(request.generation.maxOutputTokens == nil)
        #expect(request.generation.topP == nil)
        #expect(request.generation.topK == nil)
        #expect(request.tools == nil)
        producer.yield(.drained)
        producer.finish()
    }

    @Test(arguments: [false, true])
    func incompleteAndCancelledBodiesAreNotSuccessfulText(_ cancelled: Bool) async {
        let engine = Engine(AsyncThrowingStream { c in
            c.yield(.outputTextDelta("partial"))
            c.yield(completion(cancelled ? .cancelled : .incomplete))
            c.finish()
        })
        do {
            _ = try await HostBridgeInference.completeContent(model: "bridge-model", input: [], engine: engine)
            Issue.record("Unfinished output returned as successful text")
        } catch is CancellationError {
            #expect(cancelled)
        } catch ResponsesGenerationResult.CollectionError.incomplete {
            #expect(!cancelled)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func transportFailureDoesNotReplayRequest() async {
        let engine = Engine(AsyncThrowingStream { c in
            c.yield(.outputTextDelta("partial"))
            c.finish(throwing: NSError(domain: "fixture", code: 503))
        })
        do {
            _ = try await HostBridgeInference.completeContent(model: "bridge-model", input: [], engine: engine)
            Issue.record("Transport failure became success")
        } catch { #expect((error as NSError).code == 503) }
        #expect(await engine.requests.count == 1)
    }
}
