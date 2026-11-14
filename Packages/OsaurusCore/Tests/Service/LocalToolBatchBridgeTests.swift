import Foundation
import Testing

@testable import OsaurusCore

@Suite("Local tool batches survive native streaming", .timeLimit(.minutes(1)))
struct LocalToolBatchBridgeTests {
    private actor Observation {
        var deltas: [String] = []
        var calls: [ServiceToolInvocation] = []
        var ended = false
        var failed = false
        var upstreamCancelled = false
        var exhaustedCallCount: Int?

        func delta(_ value: String) { deltas.append(value) }
        func finish(_ values: [ServiceToolInvocation] = [], failed: Bool = false) {
            calls = values
            self.failed = failed
            ended = true
        }
        func cancelUpstream() { upstreamCancelled = true }
        func exhausted(_ count: Int) {
            exhaustedCallCount = count
            finish(failed: true)
        }
        func sawPreview(_ name: String) -> Bool {
            deltas.contains { StreamingToolHint.decode($0) == name }
        }
    }

    private struct UpstreamFailure: Error {}

    private let first = ModelRuntimeEvent.toolInvocation(name: "read_file", argsJSON: #"{"path":"first.txt"}"#)
    private let second = ModelRuntimeEvent.toolInvocation(name: "read_file", argsJSON: #"{"path":"second.txt"}"#)
    private var completion: ModelRuntimeEvent {
        .completionInfo(tokenCount: 42, tokensPerSecond: 21, unclosedReasoning: false,
                        stopReason: "tool_calls", promptTokensPerSecond: 100, mtp: nil)
    }

    private func consume(
        _ upstream: AsyncThrowingStream<ModelRuntimeEvent, Error>,
        complete: Bool = false,
        observed: Observation
    ) -> Task<Void, Never> {
        let stream = ModelRuntime.bridgeToolEventStream(upstream, collectCompleteResponse: complete)
        return Task {
            do {
                for try await delta in stream { await observed.delta(delta) }
                await observed.finish()
            } catch let batch as ServiceToolInvocations {
                await observed.finish(batch.invocations)
            } catch let call as ServiceToolInvocation {
                await observed.finish([call])
            } catch let exhausted as ServiceToolResponseExhausted {
                await observed.exhausted(exhausted.toolCallCount)
            } catch {
                await observed.finish(failed: true)
            }
        }
    }

    /// Bounded observation only, never a production batch/grace timer.
    private func waitFor(_ predicate: () async -> Bool) async throws -> Bool {
        for _ in 0 ..< 200 {
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    @Test func delayedSecondCallWaitsForTheResponseBoundary() async throws {
        let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let observed = Observation()
        let consumer = consume(upstream, observed: observed)
        defer { producer.finish(); consumer.cancel() }

        producer.yield(first)
        #expect(try await waitFor { await observed.sawPreview("read_file") })
        #expect(await observed.ended == false)
        // Arrives after the first call has actually crossed the bridge. This
        // cannot pass by batching only the events already buffered at first call.
        producer.yield(second)
        producer.yield(completion)
        #expect(try await waitFor { await observed.ended })
        #expect(await observed.calls.map(\.jsonArguments) == [#"{"path":"first.txt"}"#, #"{"path":"second.txt"}"#])
        #expect(await observed.deltas.contains { StreamingStatsHint.decode($0)?.tokenCount == 42 })
        // No upstream EOF yet: native dispatch must not wait on wrapper cleanup.
        producer.finish()
        await consumer.value
    }

    @Test(arguments: [false, true])
    func cleanEOFWithoutStatsKeepsIdenticalCalls(_ complete: Bool) async {
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(first)
            c.yield(first)
            c.finish()
        }
        let observed = Observation()
        await consume(upstream, complete: complete, observed: observed).value
        #expect(await observed.calls.count == 2)
        #expect(await observed.calls.map(\.jsonArguments) == [#"{"path":"first.txt"}"#, #"{"path":"first.txt"}"#])
    }

    @Test(arguments: [false, true])
    func errorBeforeCompletionDoesNotPublishAPartialBatch(_ complete: Bool) async {
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(first)
            c.finish(throwing: UpstreamFailure())
        }
        let observed = Observation()
        await consume(upstream, complete: complete, observed: observed).value
        #expect(await observed.failed)
        #expect(await observed.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationBeforeAnyCallReachesUpstream(_ complete: Bool) async throws {
        let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let observed = Observation()
        producer.onTermination = { termination in
            if case .cancelled = termination { Task { await observed.cancelUpstream() } }
        }
        let consumer = consume(upstream, complete: complete, observed: observed)
        consumer.cancel()
        await consumer.value
        #expect(try await waitFor { await observed.upstreamCancelled })
        #expect(await observed.calls.isEmpty)
        producer.finish()
    }

    @Test func stopBetweenCallsDiscardsTheUnexecutedBatch() async throws {
        let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let observed = Observation()
        producer.onTermination = { termination in
            if case .cancelled = termination { Task { await observed.cancelUpstream() } }
        }
        let consumer = consume(upstream, observed: observed)
        defer { producer.finish(); consumer.cancel() }
        producer.yield(first)
        #expect(try await waitFor { await observed.sawPreview("read_file") })
        consumer.cancel()
        await consumer.value
        #expect(try await waitFor { await observed.upstreamCancelled })
        producer.yield(second)
        producer.yield(completion)
        #expect(await observed.calls.isEmpty)
    }

    @Test(arguments: [false, true], [0, 1, 8, 128])
    func cancellationWhileEventsAreBufferedReachesUpstream(_ complete: Bool, _ buffered: Int) async throws {
        // Repeat the real scheduling race without adding a production test hook.
        // Existing tests cover cancellation while next() is already suspended.
        for attempt in 0 ..< 100 {
            let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
            let observed = Observation()
            producer.onTermination = { termination in
                if case .cancelled = termination { Task { await observed.cancelUpstream() } }
            }
            let consumer = consume(upstream, complete: complete, observed: observed)
            defer { producer.finish(); consumer.cancel() }
            for _ in 0 ..< buffered { producer.yield(first) }
            consumer.cancel()
            await consumer.value
            // Observe cancellation before explicitly finishing the fixture.
            // Keep upstream alive: deinitialization must not mask a lost cancel.
            let cancelled = try await waitFor { await observed.upstreamCancelled }
            withExtendedLifetime(upstream) {}
            try #require(cancelled, "Lost upstream cancellation at attempt \(attempt), buffered=\(buffered), complete=\(complete)")
            #expect(await observed.calls.isEmpty)
        }
    }

    @Test func nativeCompletionDoesNotCancelOrWaitForTheTail() async throws {
        let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let observed = Observation()
        producer.onTermination = { termination in
            if case .cancelled = termination { Task { await observed.cancelUpstream() } }
        }
        let consumer = consume(upstream, observed: observed)
        defer { producer.finish(); consumer.cancel() }
        producer.yield(first)
        producer.yield(second)
        producer.yield(completion)
        #expect(try await waitFor { await observed.ended })
        #expect(await observed.calls.count == 2)
        #expect(await observed.upstreamCancelled == false)
        producer.finish(throwing: UpstreamFailure())
        await consumer.value
        #expect(await observed.calls.count == 2)
        #expect(await observed.failed == false)
    }

    @Test func fullResponseStillRejectsFailureAfterStats() async {
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(first)
            c.yield(second)
            c.yield(completion)
            c.finish(throwing: UpstreamFailure())
        }
        let observed = Observation()
        await consume(upstream, complete: true, observed: observed).value
        #expect(await observed.failed)
        #expect(await observed.calls.isEmpty)
    }

    @Test(arguments: [false, true], [1, 2, 64])
    func lengthExhaustionDoesNotPublishAnExecutableBatch(_ complete: Bool, _ callCount: Int) async {
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { producer in
            for _ in 0 ..< callCount { producer.yield(first) }
            producer.yield(.completionInfo(
                tokenCount: 16_384, tokensPerSecond: 38, unclosedReasoning: false,
                stopReason: "length", promptTokensPerSecond: 450, mtp: nil
            ))
            producer.finish()
        }
        let observed = Observation()
        await consume(upstream, complete: complete, observed: observed).value
        #expect(await observed.failed)
        #expect(await observed.calls.isEmpty)
        #expect(await observed.exhaustedCallCount == callCount)
        #expect(await observed.deltas.contains {
            guard let stats = StreamingStatsHint.decode($0) else { return false }
            return stats.stopReason == "length" && stats.tokenCount == 16_384
        })
    }

    @Test func lengthFailurePreservesTheUpstreamCleanupTail() async throws {
        let (upstream, producer) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let observed = Observation()
        producer.onTermination = { termination in
            if case .cancelled = termination { Task { await observed.cancelUpstream() } }
        }
        let consumer = consume(upstream, observed: observed)
        defer { producer.finish(); consumer.cancel() }
        producer.yield(first)
        producer.yield(.completionInfo(
            tokenCount: 16_384, tokensPerSecond: 38, unclosedReasoning: false,
            stopReason: "length", promptTokensPerSecond: 450, mtp: nil
        ))
        #expect(try await waitFor { await observed.ended })
        #expect(await observed.failed)
        #expect(await observed.calls.isEmpty)
        #expect(await observed.upstreamCancelled == false)
        producer.finish()
        await consumer.value
    }

    @Test func nonStreamingLengthExhaustionRejectsParsedCalls() async throws {
        let events = AsyncThrowingStream<ModelRuntimeEvent, Error> { producer in
            producer.yield(.tokens("Partial response"))
            producer.yield(first)
            producer.yield(second)
            producer.yield(.completionInfo(
                tokenCount: 16_384, tokensPerSecond: 38, unclosedReasoning: false,
                stopReason: "length", promptTokensPerSecond: 450, mtp: nil
            ))
            producer.finish()
        }
        do {
            _ = try await ModelRuntime.collectToolEventResponse(events)
            Issue.record("An exhausted tool response must fail explicitly")
        } catch let exhausted as ServiceToolResponseExhausted {
            #expect(exhausted.toolCallCount == 2)
        }
    }

    @Test func nonStreamingCompletedResponsePreservesTheBatch() async throws {
        let events = AsyncThrowingStream<ModelRuntimeEvent, Error> { producer in
            producer.yield(first)
            producer.yield(second)
            producer.yield(completion)
            producer.finish()
        }
        do {
            _ = try await ModelRuntime.collectToolEventResponse(events)
            Issue.record("Expected the completed tool batch")
        } catch let batch as ServiceToolInvocations {
            #expect(batch.invocations.map(\.jsonArguments) == [#"{"path":"first.txt"}"#, #"{"path":"second.txt"}"#])
        }
    }

    @Test func nextEnvelopeResetsThePreviousCallPreview() async {
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(first)
            c.yield(.toolCallProgress("second envelope"))
            c.yield(second)
            c.yield(completion)
            c.finish()
        }
        let observed = Observation()
        await consume(upstream, observed: observed).value
        let names = await observed.deltas.compactMap { StreamingToolHint.decode($0) }
        #expect(names == ["read_file", "", "read_file"])
        #expect(await observed.calls.count == 2)
    }
}
