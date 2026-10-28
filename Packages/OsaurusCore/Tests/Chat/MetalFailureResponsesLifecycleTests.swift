import Combine
import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// Injected terminal failures exercise production adapters and the real agent
/// driver. This is containment/lifecycle proof, not a GPU0e reproduction.
@Suite("Controlled Metal failure through Responses", .timeLimit(.minutes(1)))
@MainActor
struct MetalFailureResponsesLifecycleTests {
    private static let signature = "[METAL] Command buffer execution failed: Impacting Interactivity (0000000e:kIOGPUCommandBufferCallbackErrorImpactingInteractivity)."

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

    private final class Probe: @unchecked Sendable {
        struct Report: Sendable {
            let failure: GenerationFailure
            let prompt: Int
            let generated: Int
        }
        struct Snapshot: Sendable {
            var entered = false
            var finished = false
            var cancelled = false
            var reports: [Report] = []
        }
        private let lock = NSLock()
        private var state = Snapshot()
        func enter(cancelled: Bool) {
            lock.lock(); defer { lock.unlock() }
            state.entered = true
            state.cancelled = state.cancelled || cancelled
        }
        func finish(cancelled: Bool) {
            lock.lock(); defer { lock.unlock() }
            state.finished = true
            state.cancelled = state.cancelled || cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            state.cancelled = true
        }
        func report(_ failure: GenerationFailure, prompt: Int, generated: Int) {
            lock.lock(); defer { lock.unlock() }
            state.reports.append(.init(failure: failure, prompt: prompt, generated: generated))
        }
        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return state
        }
    }

    private actor FailedProducer {
        let entered = Gate()
        let release = Gate()
        let finished = Gate()
        private let prefix: [Generation]
        private let probe: Probe
        private var index = 0
        init(stage: GenerationFailure.Stage, failure: GenerationFailure, probe: Probe) {
            self.probe = probe
            var events: [Generation] = []
            if stage == .decoding {
                events += [.reasoning("partial reasoning"), .chunk("partial answer")]
                let arguments: [String: MLXLMCommon.JSONValue] = ["path": .string("must-not-write.txt")]
                events.append(.toolCall(MLXLMCommon.ToolCall(function: .init(name: "write_file", arguments: arguments))))
            }
            events.append(.info(GenerateCompletionInfo(promptTokenCount: 73,
                generationTokenCount: stage == .decoding ? 3 : 0, promptTime: 0.2,
                generationTime: 0.1, stopReason: .cancelled, generationFailure: failure)))
            // A late secondary diagnostic must not replace the first error or
            // publish another handled report/success/precise usage count.
            events.append(.info(GenerateCompletionInfo(promptTokenCount: 73,
                generationTokenCount: 999, promptTime: 0, generationTime: 0,
                stopReason: .cancelled, generationFailure: .init(stage: stage,
                    cause: "controlled secondary cleanup diagnostic"))))
            prefix = events
        }
        func next() async -> Generation? {
            if index < prefix.count {
                defer { index += 1 }
                return prefix[index]
            }
            await withTaskCancellationHandler {
                probe.enter(cancelled: Task.isCancelled)
                await entered.signal()
                await release.wait()
                probe.finish(cancelled: Task.isCancelled)
                await finished.signal()
            } onCancel: { probe.cancel() }
            return nil
        }
    }

    private final class Service: ResponsesGenerationService, @unchecked Sendable {
        let model: String
        private let factories: [@Sendable () -> AsyncThrowingStream<ResponsesGenerationEvent, Error>]
        private let lock = NSLock()
        private var typedCalls = 0
        private var legacyCalls = 0
        init(model: String, factories: [@Sendable () -> AsyncThrowingStream<ResponsesGenerationEvent, Error>]) {
            self.model = model
            self.factories = factories
        }
        var id: String { "controlled-metal-responses" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == model }
        private func take() throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            lock.lock()
            guard typedCalls < factories.count else {
                lock.unlock()
                throw FixtureError.unexpectedReplay
            }
            let factory = factories[typedCalls]
            typedCalls += 1
            lock.unlock()
            return factory()
        }
        private func legacy() {
            lock.lock(); defer { lock.unlock() }
            legacyCalls += 1
        }
        func counts() -> (typed: Int, legacy: Int) {
            lock.lock(); defer { lock.unlock() }
            return (typedCalls, legacyCalls)
        }
        func streamResponses(
            messages: [ChatMessage], parameters: GenerationParameters, stopSequences: [String],
            tools: [OsaurusCore.Tool], toolChoice: ToolChoiceOption?, requestedModel: String?
        ) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> { try take() }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error> {
            legacy(); throw FixtureError.unexpectedReplay
        }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?) async throws -> String {
            legacy(); throw FixtureError.unexpectedReplay
        }
    }

    private enum FixtureError: Error { case unexpectedReplay, missingLog }

    private func log(turn: UUID) async throws -> RequestLog {
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        let observer = InsightsService.shared.$hasLogs.sink { _ in continuation.yield(()) }
        defer { observer.cancel(); continuation.finish() }
        for await _ in changes {
            let rows = InsightsService.shared.logs.filter { $0.turnId == turn }
            if !rows.isEmpty {
                #expect(rows.count == 1)
                return try #require(rows.first)
            }
        }
        throw FixtureError.missingLog
    }

    @Test(arguments: [GenerationFailure.Stage.preparation, .decoding])
    func firstFailureStopsDispatchPreservesPartialChannelsAndDrainsBeforeHealthyFollowup(stage: GenerationFailure.Stage) async throws {
        let model = "controlled-metal-\(UUID())"
        let failure = GenerationFailure(stage: stage, cause: Self.signature)
        let sourceProbe = Probe()
        let nativeDrainProbe = Probe()
        let source = FailedProducer(stage: stage, failure: failure, probe: sourceProbe)
        let nativeDrained = Gate()
        defer { Task { await source.release.signal() } }
        let mapped = GenerationEventMapper.map(
            events: AsyncStream(unfolding: { await source.next() }, onCancel: { sourceProbe.cancel() }),
            modelName: model, promptTokenCount: 73, suppressProgressUI: true,
            onConsumerCancellation: { sourceProbe.cancel() },
            reportFailure: { value, _, prompt, generated, _ in
                sourceProbe.report(value, prompt: prompt, generated: generated)
            })
        let failing = ResponsesGenerationStream.native(mapped, waitForProducerDrain: {
            await withTaskCancellationHandler {
                nativeDrainProbe.enter(cancelled: Task.isCancelled)
                await source.finished.wait()
                nativeDrainProbe.finish(cancelled: Task.isCancelled)
                await nativeDrained.signal()
            } onCancel: { nativeDrainProbe.cancel() }
        })
        let service = Service(model: model, factories: [{ failing }, {
            // Construct the next producer only after actual failed-producer
            // drain, rather than pre-buffering a healthy response in advance.
            let previous = nativeDrainProbe.snapshot()
            #expect(previous.finished && !previous.cancelled)
            return ResponsesGenerationStream.native(GenerationEventMapper.map(
                events: AsyncStream { continuation in
                    continuation.yield(.chunk("independent healthy answer"))
                    continuation.yield(.info(GenerateCompletionInfo(promptTokenCount: 73,
                        generationTokenCount: 4, promptTime: 0.2, generationTime: 0.1, stopReason: .stop)))
                    continuation.finish()
                }, promptTokenCount: 73, suppressProgressUI: true))
        }])
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        let turn = UUID()
        var request = ResponsesInferenceRequest(model: model, input: [ChatMessage(role: "user", content: "fixture")])
        request.context.turnId = turn
        request.tools = [OsaurusCore.Tool(type: "function",
            function: ToolFunction(name: "write_file", description: nil, parameters: nil))]
        var reasoning = ""
        var text = ""
        var previews = 0
        var completions = 0
        var modelSteps = 0
        var executedTools = 0
        let hooks = AgentLoopHooks(
            buildMessages: { _ in AgentLoopIterationInput(messages: request.input) },
            modelStep: { _, _ in
                modelSteps += 1
                var accumulator = ResponsesGenerationAccumulator()
                for try await event in try await engine.streamResponses(request: request) {
                    if case .reasoningDelta(let value) = event { reasoning += value }
                    if case .outputTextDelta(let value) = event { text += value }
                    if case .functionCallAdded = event { previews += 1 }
                    if case .responseCompleted = event { completions += 1 }
                    try accumulator.consume(event)
                }
                let result = try accumulator.result()
                let assistant = try result.completedAssistantInput()
                let calls = (assistant.tool_calls ?? []).map { call in
                    ServiceToolInvocation(toolName: call.function.name,
                        jsonArguments: call.function.arguments, toolCallId: call.id)
                }
                return calls.isEmpty ? .finalResponse : .toolCalls(calls)
            },
            executeTool: { _, _ in
                executedTools += 1
                return AgentLoopToolExecution(result: "unexpected execution")
            })
        try await withTaskCancellationHandler {
            do {
                _ = try await AgentToolLoop.run(policy: .init(maxIterations: 8,
                    stopOnToolRejection: false, dedupeNoticeEnabled: false), state: AgentTaskState(), hooks: hooks)
                Issue.record("The controlled model failure must escape the actual driver")
            } catch let caught as GenerationFailure {
                #expect(caught == failure)
                #expect(caught.localizedDescription == Self.signature)
            }
            #expect(reasoning == (stage == .decoding ? "partial reasoning" : ""))
            #expect(text == (stage == .decoding ? "partial answer" : ""))
            #expect(previews == (stage == .decoding ? 1 : 0))
            #expect(completions == 0 && executedTools == 0 && modelSteps == 1)
            let errorLog = try await log(turn: turn)
            #expect(errorLog.statusCode == 500 && errorLog.finishReason == .error && !errorLog.isSuccess)
            #expect(errorLog.errorMessage == Self.signature)
            #expect(errorLog.inputTokens == 73 && errorLog.outputTokens == nil && errorLog.tokensPerSecond == nil)
            #expect(service.counts().typed == 1 && service.counts().legacy == 0)
            await source.entered.wait()
            let pending = sourceProbe.snapshot()
            #expect(pending.entered && !pending.finished && !pending.cancelled)
            try #require(pending.reports.count == 1)
            #expect(pending.reports.first?.failure == failure)
            #expect(pending.reports.first?.generated == (stage == .decoding ? 3 : 0))
            #expect(pending.reports.first?.prompt == 73)
            let handled = try #require(HandledGPUFailureReport(failure: failure,
                modelName: "OsaurusAI/controlled-fixture", promptTokens: 73,
                generatedTokens: stage == .decoding ? 3 : 0))
            #expect(handled.stage == stage.rawValue)
            await source.release.signal()
            await nativeDrained.wait()
            #expect(sourceProbe.snapshot().finished && !sourceProbe.snapshot().cancelled)
            #expect(nativeDrainProbe.snapshot().finished && !nativeDrainProbe.snapshot().cancelled)

            var followup = ResponsesInferenceRequest(model: model,
                input: [ChatMessage(role: "user", content: "independent followup")])
            let followupTurn = UUID()
            followup.context.turnId = followupTurn
            let result = try await ResponsesGenerationResult.collect(
                try await engine.streamResponses(request: followup), endAt: .streamEnd)
            #expect(result.text == "independent healthy answer")
            #expect(result.completion.status == .completed && result.completion.tokenCount == 4)
            let success = try await log(turn: followupTurn)
            #expect(success.statusCode == 200 && success.finishReason == .stop && success.errorMessage == nil)
            #expect(success.outputTokens == 4)
            #expect(service.counts().typed == 2 && service.counts().legacy == 0)
        } onCancel: {
            Task {
                await source.release.signal()
                await source.entered.signal()
                await source.finished.signal()
                await nativeDrained.signal()
            }
        }
    }
}
