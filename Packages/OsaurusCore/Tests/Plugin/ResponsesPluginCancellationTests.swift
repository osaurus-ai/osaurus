import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite("Plugin cancellation without stream events", .serialized, .timeLimit(.minutes(1)))
struct ResponsesPluginCancellationTests {
    private final class Observation: Sendable {
        let cancelledTerminations = OSAllocatedUnfairLock(initialState: 0)
    }
    private actor PausedEngine: ResponsesEngineProtocol {
        let observation: Observation
        var continuations: [AsyncThrowingStream<ResponsesGenerationEvent, Error>.Continuation] = []
        private(set) var started = 0
        private var released = false
        init(_ observation: Observation) { self.observation = observation }
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            started += 1
            let pair = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
            let observation = observation
            pair.continuation.onTermination = { reason in
                if case .cancelled = reason { observation.cancelledTerminations.withLock { $0 += 1 } }
            }
            if released { pair.continuation.finish() } else { continuations.append(pair.continuation) }
            return pair.stream
        }
        func releaseAll() {
            released = true
            continuations.forEach { $0.finish() }
            continuations.removeAll()
        }
    }
    private struct Job: Sendable {
        let returned: OSAllocatedUnfairLock<Bool>
        let task: Task<String, Never>
    }
    private func start(_ context: PluginHostContext, id: String) -> Job {
        let returned = OSAllocatedUnfairLock(initialState: false)
        let body = #"{"model":"paused-fixture","messages":[{"role":"user","content":"wait"}],"max_iterations":1,"stream_id":"\#(id)"}"#
        let task = Task.detached {
            let response = context.completeStream(requestJSON: body, onChunk: nil, userData: nil)
            returned.withLock { $0 = true }
            return response
        }
        return Job(returned: returned, task: task)
    }
    private func waitFor(_ predicate: () async -> Bool) async -> Bool {
        let until = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < until {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
    private func error(_ text: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? String
    }

    @Test func unknownCancellationIDsAreNoOps() throws {
        let context = try PluginHostContext(pluginId: "test.responses.cancel.unknown.\(UUID())")
        let id = UUID().uuidString
        context.completeCancel(streamId: id)
        #expect(!context.isStreamCancelled(id))
    }

    @Test(arguments: [1, 2])
    func cancellationReachesEveryMatchingOwnerWithoutAnotherDelta(_ ownerCount: Int) async throws {
        let observation = Observation()
        let engine = PausedEngine(observation)
        defer { Task { await engine.releaseAll() } }
        let context = try PluginHostContext(pluginId: "test.responses.cancel.stalled.\(UUID())", inferenceEngineFactory: { engine })
        let id = UUID().uuidString
        let jobs = (0..<ownerCount).map { _ in start(context, id: id) }
        let started = await waitFor { await engine.started == ownerCount }
        context.completeCancel(streamId: id)
        let completedBeforeFixtureRelease = await waitFor { jobs.allSatisfy { $0.returned.withLock { $0 } } }
        let cancelledBeforeFixtureRelease = observation.cancelledTerminations.withLock { $0 }
        // Always release the fixture before assertions, including on RED,
        // so this test cannot leave the blocking host threads behind.
        await engine.releaseAll()
        var responses: [String] = []
        for job in jobs { responses.append(await job.task.value) }
        #expect(started)
        #expect(completedBeforeFixtureRelease)
        #expect(cancelledBeforeFixtureRelease == ownerCount)
        #expect(responses.allSatisfy { error($0) == "cancelled" })
    }

    @Test func cancellingOneIDDoesNotStopAnotherActiveStream() async throws {
        let observation = Observation()
        let engine = PausedEngine(observation)
        defer { Task { await engine.releaseAll() } }
        let context = try PluginHostContext(pluginId: "test.responses.cancel.scoped.\(UUID())", inferenceEngineFactory: { engine })
        let firstID = UUID().uuidString, secondID = UUID().uuidString
        let first = start(context, id: firstID), second = start(context, id: secondID)
        let started = await waitFor { await engine.started == 2 }
        context.completeCancel(streamId: firstID)
        let firstFinished = await waitFor { first.returned.withLock { $0 } }
        let secondStillActive = !second.returned.withLock { $0 }
        context.completeCancel(streamId: secondID)
        await engine.releaseAll()
        let firstResult = await first.task.value, secondResult = await second.task.value
        #expect(started && firstFinished && secondStillActive)
        #expect(error(firstResult) == "cancelled" && error(secondResult) == "cancelled")
    }

    @Test func anOldOwnerCannotResetOrRemoveAnotherOwner() throws {
        let context = try PluginHostContext(pluginId: "test.responses.cancel.ownership.\(UUID())")
        let id = UUID().uuidString
        let first = UUID(), second = UUID(), replacement = UUID()
        let observed = OSAllocatedUnfairLock(initialState: [UUID: Int]())
        for owner in [first, second] {
            context.registerStream(id, owner: owner) {
                // Reentry must not deadlock the registry.
                _ = context.isStreamCancelled(id, owner: owner)
                observed.withLock { $0[owner, default: 0] += 1 }
            }
        }
        context.completeCancel(streamId: id)
        context.completeCancel(streamId: id)
        context.unregisterStream(id, owner: first)
        context.registerStream(id, owner: replacement) { observed.withLock { $0[replacement, default: 0] += 1 } }
        #expect(context.isStreamCancelled(id, owner: second))
        #expect(!context.isStreamCancelled(id, owner: replacement))
        context.unregisterStream(id, owner: first)
        context.completeCancel(streamId: id)
        #expect(observed.withLock { $0 } == [first: 1, second: 1, replacement: 1])
        context.unregisterStream(id, owner: second)
        #expect(context.isStreamCancelled(id, owner: replacement))
        context.unregisterStream(id, owner: replacement)
        #expect(!context.isStreamCancelled(id))
    }

    @Test func cancellationAttachmentAndCompletionRaces() {
        let observed = OSAllocatedUnfairLock(initialState: 0)
        let beforeAttach = PluginStreamCancellationHandle()
        beforeAttach.cancel()
        beforeAttach.attach { observed.withLock { $0 += 1 } }
        beforeAttach.cancel()
        beforeAttach.finish()
        let beforeFinish = PluginStreamCancellationHandle()
        beforeFinish.attach { observed.withLock { $0 += 10 } }
        beforeFinish.finish()
        beforeFinish.cancel()
        let finishBeforeAttach = PluginStreamCancellationHandle()
        finishBeforeAttach.finish()
        finishBeforeAttach.attach { observed.withLock { $0 += 100 } }
        finishBeforeAttach.cancel()
        #expect(observed.withLock { $0 } == 1)
    }

}
