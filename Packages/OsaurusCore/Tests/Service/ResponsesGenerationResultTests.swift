import Foundation
import Testing

@testable import OsaurusCore

@Suite("Responses one-shot result boundaries", .timeLimit(.minutes(1)))
struct ResponsesGenerationResultTests {
    private func completion(status: ResponsesGenerationCompletion.Status = .completed) -> ResponsesGenerationCompletion
    {
        .init(
            responseID: "resp_fixture",
            status: status,
            functionCalls: [
                ResponsesFunctionCall(
                    id: "fc_1",
                    callID: "call_1",
                    name: "lookup",
                    arguments: #"{"key":"a"}"#,
                    geminiThoughtSignature: "signature"
                )
            ],
            tokenCount: 12,
            tokensPerSecond: 31.123456789,
            unclosedReasoning: false,
            stopReason: "tool_calls",
            promptTokensPerSecond: 512.987654321,
            mtp: nil
        )
    }

    private func stream(_ events: [ResponsesGenerationEvent]) -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
        AsyncThrowingStream { c in
            for event in events { c.yield(event) }
            c.finish()
        }
    }

    @Test func oneShotKeepsProviderItemsChannelsIDsAndExactMetrics() async throws {
        let raw: JSONValue = .object([
            "type": .string("message"), "phase": .string("commentary"),
            "id": .string("msg_1"), "future": .object(["preserved": .bool(true)]),
        ])
        let result = try await ResponsesGenerationResult.collect(
            stream([
                .inputTokenCount(400), .reasoningDelta("Plan."), .outputTextDelta("Checking."),
                .providerOutputItem(raw), .reasoningItem(.init(id: "rs_1", encryptedContent: "opaque")),
                .responseCompleted(completion()), .drained,
            ]),
            endAt: .streamEnd
        )
        let message = try result.completedAssistantInput()
        #expect(result.inputTokenCount == 400)
        #expect(result.completion.tokensPerSecond == 31.123456789)
        #expect(result.completion.promptTokensPerSecond == 512.987654321)
        #expect(message.content == "Checking.")
        #expect(message.reasoning_content == "Plan.")
        #expect(message.responses_output_items == [raw])
        #expect(message.reasoning_item_id == "rs_1")
        #expect(message.reasoning_encrypted == "opaque")
        #expect(message.tool_calls?.first?.id == "call_1")
        #expect(message.tool_calls?.first?.function.arguments == #"{"key":"a"}"#)
        #expect(message.tool_calls?.first?.geminiThoughtSignature == "signature")
        guard case .nativeProducerDrained = result.drainStatus else {
            Issue.record("Missing native producer fence"); return
        }
    }

    @Test func logicalCollectionDoesNotWaitForOrClaimProducerDrain() async throws {
        let (source, producer) = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
        producer.yield(.responseCompleted(completion()))
        let result = try await ResponsesGenerationResult.collect(source)
        guard case .notObserved = result.drainStatus else {
            Issue.record("Logical completion claimed drain"); return
        }
        producer.yield(.drained)
        producer.finish()
    }

    @Test func compatibilityEOFIsNotANativeProducerFence() async throws {
        let result = try await ResponsesGenerationResult.collect(
            stream([
                .responseCompleted(completion()), .compatibilityStreamClosed,
            ]),
            endAt: .streamEnd
        )
        guard case .compatibilityStreamClosed = result.drainStatus else {
            Issue.record("Compatibility closure must retain its weaker boundary"); return
        }
    }

    @Test(arguments: [false, true])
    func incompleteOrCancelledResponseCannotBecomeExecutableHistory(_ cancelled: Bool) async throws {
        let result = try await ResponsesGenerationResult.collect(
            stream([
                .responseCompleted(completion(status: cancelled ? .cancelled : .incomplete))
            ])
        )
        do {
            _ = try result.completedAssistantInput()
            Issue.record("Interrupted response became executable history")
        } catch is CancellationError {
            #expect(cancelled)
        } catch ResponsesGenerationResult.CollectionError.incomplete {
            #expect(!cancelled)
        }
    }

    @Test func EOFWithoutTerminalCannotInventACompletedResult() async {
        do {
            _ = try await ResponsesGenerationResult.collect(stream([.outputTextDelta("partial")]))
            Issue.record("Incomplete stream became success")
        } catch ResponsesGenerationResult.CollectionError.missingCompletion {
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [0, 1, 2, 3])
    func streamEndCollectionRejectsInvalidOrderingOrDrainFailure(_ row: Int) async {
        let tail: ResponsesGenerationEvent
        switch row {
        case 0: tail = .responseCompleted(completion())
        case 1: tail = .outputTextDelta("late")
        case 2: tail = .providerOutputItem(.object(["late": .bool(true)]))
        default: tail = .drainFailed("fixture cache failure")
        }
        do {
            _ = try await ResponsesGenerationResult.collect(
                stream([.responseCompleted(completion()), tail]),
                endAt: .streamEnd
            )
            Issue.record("Invalid terminal sequence became success")
        } catch let error as ResponsesGenerationResult.CollectionError {
            switch (row, error) {
            case (0, .duplicateCompletion), (1, .outputAfterCompletion), (2, .outputAfterCompletion),
                (3, .drainFailed("fixture cache failure")):
                break
            default: Issue.record("Wrong error: \(error)")
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func producerFenceBeforeCompletionIsRejected() async {
        do {
            _ = try await ResponsesGenerationResult.collect(
                stream([.drained, .responseCompleted(completion())]),
                endAt: .streamEnd
            )
            Issue.record("Invalid producer fence became success")
        } catch ResponsesGenerationResult.CollectionError.drainBeforeCompletion {
        } catch { Issue.record("Unexpected error: \(error)") }
    }
}
