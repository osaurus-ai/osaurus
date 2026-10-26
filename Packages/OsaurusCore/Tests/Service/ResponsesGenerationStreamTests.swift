import Foundation
import Testing

@testable import OsaurusCore

@Suite("Typed Responses native generation", .timeLimit(.minutes(1)))
struct ResponsesGenerationStreamTests {
    private actor Observation {
        var previews: [ResponsesFunctionCall] = []
        var completions: [ResponsesGenerationCompletion] = []
        var order: [String] = []
        var ended = false
        var failed = false
        var cancelledUpstream = false
        var producerDrainWasCancelled: Bool?

        func append(_ event: ResponsesGenerationEvent) {
            switch event {
            case .inputTokenCount(let value): order.append("input:\(value)")
            case .outputTextDelta(let value): order.append("text:\(value)")
            case .reasoningDelta(let value): order.append("reasoning:\(value)")
            case .prefillProgress: order.append("prefill")
            case .toolEnvelopeDelta(let value): order.append("envelope:\(value)")
            case .functionCallAdded(let call): previews.append(call); order.append("preview")
            case .responseCompleted(let completion): completions.append(completion); order.append("complete")
            case .drained: order.append("drained")
            case .compatibilityStreamClosed: order.append("compatibilityClosed")
            case .drainFailed: order.append("drainFailed")
            case .functionNamePreview, .functionPreviewReset, .functionArgumentsPreview, .providerOutputItem,
                .reasoningItem, .anthropicThinkingBlock, .providerEvent, .billing, .artifacts, .agentTool, .remoteToolCompleted, .compatibilityMetadata:
                order.append("metadata")
            }
        }
        func end(failed: Bool = false) { ended = true; self.failed = failed }
        func cancel() { cancelledUpstream = true }
        func drained(cancelled: Bool) { producerDrainWasCancelled = cancelled }
    }

    private actor Gate {
        var open = false
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { open = true; waiter?.resume(); waiter = nil }
    }

    private struct Failure: Error {}

    private func completion(_ reason: String = "tool_calls", mtp: MTPStatsSummary? = nil) -> ModelRuntimeEvent {
        .completionInfo(
            tokenCount: 42,
            tokensPerSecond: 21.125,
            unclosedReasoning: false,
            stopReason: reason,
            promptTokensPerSecond: 1024.5,
            mtp: mtp
        )
    }

    private func consume(
        _ upstream: AsyncThrowingStream<ModelRuntimeEvent, Error>,
        observed: Observation,
        drain: @escaping @Sendable () async -> Void = {}
    ) -> Task<Void, Never> {
        let events = ResponsesGenerationStream.native(upstream, responseID: "resp_test", waitForProducerDrain: drain)
        return Task {
            do {
                for try await event in events { await observed.append(event) }
                await observed.end()
            } catch { await observed.end(failed: true) }
        }
    }

    private func waitFor(_ predicate: () async -> Bool) async throws -> Bool {
        for _ in 0 ..< 200 {
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    @Test func delayedBatchHasStableIDsAndOnlyCompletesOnceBeforeDrain() async throws {
        let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let observed = Observation()
        let drain = Gate()
        let consumer = consume(upstream, observed: observed, drain: { await drain.wait() })
        producer.yield(.toolInvocation(name: "read_file", argsJSON: #"{"path":"a"}"#))
        #expect(try await waitFor { await observed.previews.count == 1 })
        #expect(await observed.completions.isEmpty)
        producer.yield(.toolInvocation(name: "read_file", argsJSON: #"{"path":"b"}"#))
        producer.yield(completion())
        #expect(try await waitFor { await observed.completions.count == 1 })
        let result = try #require(await observed.completions.first)
        let previews = await observed.previews
        #expect(result.dispatchableFunctionCalls.map(\.arguments) == [#"{"path":"a"}"#, #"{"path":"b"}"#])
        #expect(result.functionCalls.map(\.callID) == previews.map(\.callID))
        #expect(Set(result.functionCalls.map(\.id)).count == 2)
        #expect(Set(result.functionCalls.map(\.callID)).count == 2)
        #expect(result.responseID == "resp_test")
        #expect(await observed.ended == false)
        producer.yield(completion())
        producer.yield(.tokens("late duplicate"))
        producer.finish()
        #expect(await observed.order.contains("drained") == false)
        await drain.release()
        await consumer.value
        #expect(await observed.completions.count == 1)
        #expect(await observed.order.suffix(2) == ["complete", "drained"])
        #expect(await observed.failed == false)
    }

    @Test func fullStatsAndChannelOrderSurviveWithoutStringEncoding() async throws {
        let mtp = MTPStatsSummary(
            depth: 3,
            activeDepth: 2,
            verifyCalls: 7,
            acceptedDraftTokens: 11,
            bonusTokens: 5,
            rejectedTokens: 2,
            arFallbackTokens: 3,
            adaptiveDownshifts: 1,
            adaptiveFallbackReason: nil,
            avgCommittedPerVerify: 2.285714
        )
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(.inputTokenCount(517))
            c.yield(.reasoning("think"))
            c.yield(.toolCallProgress("partial"))
            c.yield(.tokens("answer"))
            c.yield(completion("stop", mtp: mtp))
            c.finish()
        }
        let observed = Observation()
        await consume(upstream, observed: observed).value
        let result = try #require(await observed.completions.first)
        #expect(result.mtp == mtp)
        #expect(result.tokensPerSecond == 21.125)
        #expect(result.promptTokensPerSecond == 1024.5)
        #expect(result.tokenCount == 42)
        #expect(
            await observed.order == [
                "input:517", "reasoning:think", "envelope:partial", "text:answer", "complete", "drained",
            ]
        )
    }

    @Test(arguments: ["length", "cancelled"])
    func interruptedResponseNeverDispatchesPreviewedCalls(_ reason: String) async throws {
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(.toolInvocation(name: "write_file", argsJSON: "{}"))
            c.yield(completion(reason))
            c.finish()
        }
        let observed = Observation()
        await consume(upstream, observed: observed).value
        let result = try #require(await observed.completions.first)
        #expect(result.functionCalls.count == 1)
        #expect(result.dispatchableFunctionCalls.isEmpty)
        switch (reason, result.status) {
        case ("length", .incomplete), ("cancelled", .cancelled): break
        default: Issue.record("Incorrect terminal status")
        }
    }

    @Test func errorBeforeCompletionPublishesNoBatchAndDoesNotWaitForCleanup() async throws {
        let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let observed = Observation()
        let drain = Gate()
        let consumer = consume(upstream, observed: observed, drain: { await drain.wait() })
        producer.yield(.toolInvocation(name: "write_file", argsJSON: "{}"))
        producer.finish(throwing: Failure())
        #expect(try await waitFor { await observed.ended })
        #expect(await observed.failed)
        #expect(await observed.completions.isEmpty)
        await drain.release()
        await consumer.value
    }

    @Test func drainFailureCannotReplaceCompletedResponse() async {
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(completion("stop"))
            c.finish(throwing: Failure())
        }
        let observed = Observation()
        await consume(upstream, observed: observed).value
        #expect(await observed.order == ["complete", "drainFailed"])
        #expect(await observed.completions.count == 1)
        #expect(await observed.failed == false)
    }

    @Test func eofWithoutCompletionDoesNotInventSuccessfulResponse() async {
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(.tokens("partial"))
            c.finish()
        }
        let observed = Observation()
        await consume(upstream, observed: observed).value
        #expect(await observed.failed)
        #expect(await observed.completions.isEmpty)
        #expect(await observed.order == ["text:partial"])
    }

    @Test func stopBetweenCallsCancelsUpstreamWithoutDispatch() async throws {
        let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let observed = Observation()
        producer.onTermination = { termination in
            if case .cancelled = termination { Task { await observed.cancel() } }
        }
        let consumer = consume(upstream, observed: observed)
        producer.yield(.toolInvocation(name: "read_file", argsJSON: "{}"))
        #expect(try await waitFor { await observed.previews.count == 1 })
        consumer.cancel()
        await consumer.value
        #expect(try await waitFor { await observed.cancelledUpstream })
        #expect(await observed.completions.isEmpty)
        producer.finish()
    }

    @Test func consumerClosingAfterCompletionPreservesProducerDrain() async throws {
        let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let observed = Observation()
        producer.onTermination = { termination in
            if case .cancelled = termination { Task { await observed.cancel() } }
        }
        let consumer = consume(
            upstream,
            observed: observed,
            drain: {
                await observed.drained(cancelled: Task.isCancelled)
            }
        )
        producer.yield(completion("stop"))
        #expect(try await waitFor { await observed.completions.count == 1 })
        // A UI/tool-loop consumer may end its task at logical completion while
        // the cache-owning producer is still awaiting its final upstream EOF.
        consumer.cancel()
        await consumer.value
        producer.finish()
        #expect(try await waitFor { await observed.producerDrainWasCancelled != nil })
        #expect(await observed.producerDrainWasCancelled == false)
        #expect(await observed.cancelledUpstream == false)
    }

    @Test func nextToolEnvelopeResetsThePreviousCanonicalPreviewOnce() async throws {
        let source = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(.toolInvocation(name: "first", argsJSON: "{}"))
            c.yield(.toolCallProgress("second-start"))
            c.yield(.toolCallProgress("second-tail"))
            c.yield(.toolInvocation(name: "second", argsJSON: "{}"))
            c.yield(completion())
            c.finish()
        }
        var order: [String] = []
        for try await event in ResponsesGenerationStream.native(source) {
            switch event {
            case .functionCallAdded(let call): order.append(call.name)
            case .functionPreviewReset: order.append("reset")
            case .toolEnvelopeDelta(let delta): order.append(delta)
            case .responseCompleted(let value): #expect(value.functionCalls.map(\.name) == ["first", "second"])
            default: break
            }
        }
        #expect(order == ["first", "reset", "second-start", "second-tail", "second"])
    }
}
