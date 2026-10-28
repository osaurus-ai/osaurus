import Combine
import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("Responses cancellation Insights fidelity", .timeLimit(.minutes(1)))
@MainActor
struct ResponsesCancellationInsightsTests {
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func signal() {
            open = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private final class DrainProbe: @unchecked Sendable {
        struct Snapshot: Sendable {
            var entered = false
            var completed = false
            var cancellationRequested = false
            var taskWasCancelled = false
        }
        private let lock = NSLock()
        private var state = Snapshot()
        func enter(cancelled: Bool) {
            lock.lock(); defer { lock.unlock() }
            state.entered = true
            state.taskWasCancelled = state.taskWasCancelled || cancelled
        }
        func complete(cancelled: Bool) {
            lock.lock(); defer { lock.unlock() }
            state.completed = true
            state.taskWasCancelled = state.taskWasCancelled || cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            state.cancellationRequested = true
        }
        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return state
        }
    }

    private final class Service: ResponsesGenerationService, @unchecked Sendable {
        let model: String
        let events: AsyncThrowingStream<ResponsesGenerationEvent, Error>
        private let lock = NSLock()
        private var typedCalls = 0
        private var legacyCalls = 0
        init(model: String, events: AsyncThrowingStream<ResponsesGenerationEvent, Error>) {
            self.model = model
            self.events = events
        }
        var id: String { "cancellation-fixture" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == model }
        private func record(typed: Bool) {
            lock.lock(); defer { lock.unlock() }
            if typed { typedCalls += 1 } else { legacyCalls += 1 }
        }
        func counts() -> (typed: Int, legacy: Int) {
            lock.lock(); defer { lock.unlock() }
            return (typedCalls, legacyCalls)
        }
        func streamResponses(
            messages: [ChatMessage], parameters: GenerationParameters, stopSequences: [String],
            tools: [OsaurusCore.Tool], toolChoice: ToolChoiceOption?, requestedModel: String?
        ) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            record(typed: true)
            return events
        }
        func streamDeltas(
            messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]
        ) async throws -> AsyncThrowingStream<String, Error> {
            record(typed: false)
            throw FixtureError.legacyReplay
        }
        func generateOneShot(
            messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?
        ) async throws -> String {
            record(typed: false)
            throw FixtureError.legacyReplay
        }
    }

    private enum FixtureError: Error { case legacyReplay }

    private func request(_ model: String) -> ResponsesInferenceRequest {
        var request = ResponsesInferenceRequest(model: model, input: [ChatMessage(role: "user", content: "fixture")])
        request.context.turnId = UUID()
        return request
    }

    /// Observe the actual published log, without assuming a delay is a flush.
    private func row(_ model: String) async throws -> RequestLog {
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        let observer = InsightsService.shared.$hasLogs.sink { _ in continuation.yield(()) }
        defer { observer.cancel(); continuation.finish() }
        for await _ in changes {
            // log(_:) inserts the hot-cache row before publishing hasLogs.
            let matches = InsightsService.shared.logs.filter { $0.model == model }
            if !matches.isEmpty {
                #expect(matches.count == 1, "Exactly one inference row per request")
                return try #require(matches.first)
            }
        }
        throw FixtureError.legacyReplay
    }

    private func native(_ events: [Generation]) -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
        ResponsesGenerationStream.native(GenerationEventMapper.map(
            events: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }, promptTokenCount: 73, suppressProgressUI: true
        ))
    }

    @Test func cancellationDecisionWinsBeforeBufferedInfoWithoutWaitingForTaskCancellation() async {
        let lifecycle = ChatEngine.StreamLoggingLifecycle()
        let decided = Gate()
        let resumeCallback = Gate()
        let cancellationCallback = Task.detached {
            let shouldCancel = lifecycle.consumerDidCancel()
            await decided.signal()
            // Reproduce a callback preempted after its decision but before
            // producer.cancel(), while a buffered .info reaches the logger.
            await resumeCallback.wait()
            return shouldCancel
        }
        await withTaskCancellationHandler {
            await decided.wait()
            lifecycle.observeTerminalStats()
            let atLogging = lifecycle.snapshot()
            #expect(atLogging.terminalStatsObserved)
            #expect(atLogging.consumerCancelledBeforeTerminal,
                "Buffered measured info cannot turn the already committed cancellation into stop/200")
            await resumeCallback.signal()
            #expect(await cancellationCallback.value)
        } onCancel: {
            Task { await decided.signal(); await resumeCallback.signal() }
        }
    }

    @Test func genuineTerminalInfoWinsBeforeConsumerClose() {
        let lifecycle = ChatEngine.StreamLoggingLifecycle()
        lifecycle.observeTerminalStats()
        #expect(!lifecycle.consumerDidCancel())
        #expect(lifecycle.snapshot().terminalStatsObserved)
        #expect(!lifecycle.snapshot().consumerCancelledBeforeTerminal)
    }

    @Test(arguments: [false, true])
    func consumerCancellationBeforeInfoLogsOnceWithKnownInputAndUnknownOutput(afterReasoning: Bool) async throws {
        let model = "cancel-before-info-\(UUID())"
        let (upstream, producer) = AsyncStream<Generation>.makeStream()
        defer { producer.finish() }
        let service = Service(model: model, events: ResponsesGenerationStream.native(
            GenerationEventMapper.map(events: upstream, promptTokenCount: 73, suppressProgressUI: true)
        ))
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        let stream = try await engine.streamResponses(request: request(model))
        let reachedBoundary = Gate()
        let consumer = Task { () -> (String, Int) in
            var partial = ""
            var completions = 0
            do {
                for try await event in stream {
                    if case .reasoningDelta(let text) = event { partial += text }
                    if case .responseCompleted = event { completions += 1 }
                    if afterReasoning {
                        if case .reasoningDelta = event { await reachedBoundary.signal() }
                    } else if case .inputTokenCount = event { await reachedBoundary.signal() }
                }
            } catch is CancellationError {
                // User cancellation is not a natural stop or runtime failure.
            } catch { Issue.record("Unexpected cancellation error: \(error)") }
            return (partial, completions)
        }
        if afterReasoning { producer.yield(.reasoning("partial reasoning stays visible")) }
        let output = await withTaskCancellationHandler {
            await reachedBoundary.wait()
            consumer.cancel()
            return await consumer.value
        } onCancel: {
            consumer.cancel()
            producer.finish()
            Task { await reachedBoundary.signal() }
        }
        #expect(output.0 == (afterReasoning ? "partial reasoning stays visible" : ""))
        #expect(output.1 == 0)
        let log = try await row(model)
        #expect(log.finishReason == .cancelled && log.statusCode == 499)
        #expect(!log.isSuccess && log.errorMessage == nil)
        #expect(log.inputTokens == 73)
        #expect(log.outputTokens == nil && log.tokensPerSecond == nil)
        #expect(service.counts().typed == 1 && service.counts().legacy == 0)
    }

    @Test(arguments: [false, true])
    func actualTerminalInfoRetainsExactUsageAndStatus(cancelled: Bool) async throws {
        let model = "measured-terminal-\(UUID())"
        let service = Service(model: model, events: native([
            .reasoning("This chunk estimate must not replace seventeen measured tokens."),
            .chunk("partial answer"),
            .info(GenerateCompletionInfo(promptTokenCount: 73, generationTokenCount: 17,
                promptTime: 0.25, generationTime: 1,
                stopReason: cancelled ? .cancelled : .stop)),
        ]))
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        var completions: [ResponsesGenerationCompletion] = []
        var reasoning = ""
        var text = ""
        for try await event in try await engine.streamResponses(request: request(model)) {
            if case .responseCompleted(let completion) = event { completions.append(completion) }
            if case .reasoningDelta(let delta) = event { reasoning += delta }
            if case .outputTextDelta(let delta) = event { text += delta }
        }
        let completion = try #require(completions.count == 1 ? completions.first : nil)
        #expect(completion.status == (cancelled ? .cancelled : .completed))
        #expect(completion.tokenCount == 17 && completion.tokensPerSecond == 17)
        #expect(reasoning == "This chunk estimate must not replace seventeen measured tokens.")
        #expect(text == "partial answer")
        let log = try await row(model)
        #expect(log.finishReason == (cancelled ? .cancelled : .stop))
        #expect(log.statusCode == (cancelled ? 499 : 200))
        #expect(log.isSuccess == !cancelled)
        #expect(log.inputTokens == 73 && log.outputTokens == 17)
        #expect(service.counts().typed == 1 && service.counts().legacy == 0)
    }

    @Test func emptyNativeEOFIsAnErrorWithUnknownOutputRatherThanNaturalStop() async throws {
        let model = "empty-native-eof-\(UUID())"
        let service = Service(model: model, events: native([]))
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        do {
            for try await event in try await engine.streamResponses(request: request(model)) {
                if case .responseCompleted = event { Issue.record("Empty EOF became a success") }
            }
            Issue.record("Missing completion must fail")
        } catch ResponsesGenerationStream.StreamError.missingCompletion {
            // A missing local terminal event is not evidence of cancellation.
        }
        let log = try await row(model)
        #expect(log.finishReason == .error && log.statusCode == 500)
        #expect(log.inputTokens == 73 && log.outputTokens == nil && log.tokensPerSecond == nil)
        #expect(service.counts().typed == 1 && service.counts().legacy == 0)
    }

    @Test func consumerClosingAfterMeasuredCompletionPreservesNaturalStopAndOwnedDrain() async throws {
        let model = "completed-consumer-close-\(UUID())"
        let releaseDrain = Gate()
        let drainEntered = Gate()
        let drainCompleted = Gate()
        let drainProbe = DrainProbe()
        defer { Task { await releaseDrain.signal() } }
        let measured = GenerateCompletionInfo(promptTokenCount: 73, generationTokenCount: 17,
            promptTime: 0.25, generationTime: 1, stopReason: .stop)
        let source = AsyncStream<Generation> { continuation in
            continuation.yield(.chunk("answer"))
            continuation.yield(.info(measured))
            continuation.finish()
        }
        let service = Service(model: model, events: ResponsesGenerationStream.native(
            GenerationEventMapper.map(events: source, promptTokenCount: 73, suppressProgressUI: true),
            waitForProducerDrain: {
                await withTaskCancellationHandler {
                    drainProbe.enter(cancelled: Task.isCancelled)
                    await drainEntered.signal()
                    await releaseDrain.wait()
                    drainProbe.complete(cancelled: Task.isCancelled)
                    await drainCompleted.signal()
                } onCancel: { drainProbe.cancel() }
            }
        ))
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        let stream = try await engine.streamResponses(request: request(model))
        let consumer = Task { () -> Int in
            var completions = 0
            do {
                for try await event in stream {
                    if case .responseCompleted = event {
                        completions += 1
                        // HTTP/native consumers may close at logical completion
                        // while the producer still owns cache/Metal cleanup.
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            } catch is CancellationError {
            } catch { Issue.record("Unexpected close-after-completion error: \(error)") }
            return completions
        }
        try await withTaskCancellationHandler {
            #expect(await consumer.value == 1)
            await drainEntered.wait()
            let pending = drainProbe.snapshot()
            #expect(pending.entered && !pending.completed)
            #expect(!pending.cancellationRequested && !pending.taskWasCancelled)
            #expect(!InsightsService.shared.logs.contains { $0.model == model },
                "Neither cleanup completion nor the final Insights row may precede the owned drain")
            await releaseDrain.signal()
            await drainCompleted.wait()
            let drained = drainProbe.snapshot()
            #expect(drained.completed && !drained.cancellationRequested && !drained.taskWasCancelled)
            let log = try await row(model)
            #expect(log.statusCode == 200 && log.finishReason == .stop && log.isSuccess)
            #expect(log.inputTokens == 73 && log.outputTokens == 17)
            #expect(service.counts().typed == 1 && service.counts().legacy == 0)
        } onCancel: {
            consumer.cancel()
            Task {
                await releaseDrain.signal()
                await drainEntered.signal()
                await drainCompleted.signal()
            }
        }
    }

    @Test func canonicalCancelledStatusOverridesStopLabelWithoutInventingUsage() async throws {
        let model = "provider-cancel-status-\(UUID())"
        let service = Service(model: model, events: AsyncThrowingStream { continuation in
            continuation.yield(.reasoningDelta("partial provider reasoning"))
            continuation.yield(.responseCompleted(.init(responseID: "resp_cancelled", status: .cancelled,
                functionCalls: [], tokenCount: nil, tokensPerSecond: nil, unclosedReasoning: true,
                stopReason: "stop", promptTokensPerSecond: nil, mtp: nil)))
            continuation.yield(.compatibilityStreamClosed)
            continuation.finish()
        })
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        var statuses: [ResponsesGenerationCompletion.Status] = []
        for try await event in try await engine.streamResponses(request: request(model)) {
            if case .responseCompleted(let completion) = event { statuses.append(completion.status) }
        }
        #expect(statuses == [.cancelled])
        let log = try await row(model)
        #expect(log.statusCode == 499 && log.finishReason == .cancelled && !log.isSuccess)
        #expect(log.inputTokens == nil && log.outputTokens == nil && log.tokensPerSecond == nil)
        #expect(service.counts().typed == 1 && service.counts().legacy == 0)
    }

    @Test func legacyCompatibilityTextWithoutUsageRemainsTextWithUnknownCounts() async throws {
        let model = "legacy-no-stats-\(UUID())"
        let engine = ChatEngine(services: [FakeModelService(supportedModel: model, deltas: ["a", "b"])],
            installedModelsProvider: { [] }, source: .chatUI)
        var text = ""
        for try await delta in try await engine.streamChat(request: request(model).chatCompletionsCompatibilityRequest()) {
            text += delta
        }
        #expect(text == "ab")
        let log = try await row(model)
        #expect(log.statusCode == 200 && log.finishReason == .stop)
        #expect(log.inputTokens == nil && log.outputTokens == nil && log.tokensPerSecond == nil)
    }
}
