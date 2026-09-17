import Foundation
import Testing

@testable import OsaurusCore

private actor AuxiliaryHandoffLog {
    var entries: [String] = []
    func record(_ value: String) { entries.append(value) }
}

private enum AuxiliaryBodyFailure: Error { case expected }

@Suite("Auxiliary model handoff")
struct AuxiliaryModelHandoffTests {
    @Test(
        "explicit invocation survives detachment without borrowing ambient provenance",
        arguments: SessionSource.allCases
    )
    func detachedInvocation(source: SessionSource) async throws {
        let captured = ChatExecutionContext.$currentModelName.withValue("parent-a") {
            ChatExecutionContext.$currentSessionSource.withValue(source) {
                ModelJobInvocation.current()
            }
        }
        await ChatExecutionContext.$currentModelName.withValue("unrelated-b") {
            do {
                try await Task.detached {
                    #expect(ChatExecutionContext.currentModelName == nil)
                    try await captured.withContext {
                        #expect(ChatExecutionContext.currentModelName == "parent-a")
                        #expect(ChatExecutionContext.currentSessionSource == source)
                        throw AuxiliaryBodyFailure.expected
                    }
                }.value
                Issue.record("Expected the body error")
            } catch AuxiliaryBodyFailure.expected {
                #expect(ChatExecutionContext.currentModelName == "unrelated-b")
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("typed results use the same cleanup ordering on success and failure", arguments: [false, true])
    func typedLifecycle(bodyFails: Bool) async throws {
        let log = AuxiliaryHandoffLog()
        let handoff = makeHandoff(log: log)
        do {
            let result: String = try await handoff.withResidency(scope: scope, resolved: resolved, feed: feed()) {
                await log.record("body")
                if bodyFails { throw AuxiliaryBodyFailure.expected }
                return "the unchanged summary"
            }
            #expect(!bodyFails)
            #expect(result == "the unchanged summary")
        } catch AuxiliaryBodyFailure.expected {
            #expect(bodyFails)
        }
        #expect(await log.entries == ["preflight", "unload", "body", "release-child", "restore-parent"])
    }

    @Test("a non-rejoining deadline cannot restore while the producer is still draining")
    func deadlineKeepsOwnedLifecycleInOperation() async throws {
        let log = AuxiliaryHandoffLog()
        let (producerDrain, allowDrain) = AsyncStream<Void>.makeStream()
        let (producerStarted, started) = AsyncStream<Void>.makeStream()
        let (cleanupFinished, finished) = AsyncStream<Void>.makeStream()
        let handoff = makeHandoff(
            log: log,
            onRestored: {
                finished.yield(())
                finished.finish()
            }
        )
        let caller = Task {
            try await valueWithDeadline(seconds: 0.1, operationName: "compaction test") {
                try await handoff.withResidency(scope: scope, resolved: resolved, feed: feed()) {
                    await log.record("body-start")
                    started.yield(())
                    started.finish()
                    // Deliberately non-cooperative producer drain. Cancellation
                    // of the caller must not trigger parent restoration early.
                    await Task.detached {
                        for await _ in producerDrain { break }
                    }.value
                    await log.record("body-drained")
                    return "late summary"
                }
            }
        }
        for await _ in producerStarted { break }
        do {
            _ = try await caller.value
            Issue.record("Expected the deadline to return before drain")
        } catch is DeadlineExceededError {}
        #expect(await log.entries == ["preflight", "unload", "body-start"])
        allowDrain.yield(())
        allowDrain.finish()
        for await _ in cleanupFinished { break }
        #expect(
            await log.entries == [
                "preflight", "unload", "body-start", "body-drained", "release-child", "restore-parent",
            ]
        )
    }

    @Test("compaction snapshots invocation and encloses ownership inside the deadline")
    func compactionWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(
            contentsOf: root.appendingPathComponent("Services/Chat/ContextCompactionService.swift"),
            encoding: .utf8
        )
        let deadline = try #require(service.range(of: "responseText = try await valueWithDeadline("))
        let handoff = try #require(service.range(of: "try await AuxiliaryModelHandoff.run("))
        let generate = try #require(service.range(of: "try await service.generateOneShot("))
        #expect(deadline.lowerBound < handoff.lowerBound && handoff.lowerBound < generate.lowerBound)
        #expect(service.contains("loadIntent: .background"))
        #expect(!service.contains("loadIntent: .interactive"))
        let view = try String(contentsOf: root.appendingPathComponent("Views/Chat/ChatView.swift"), encoding: .utf8)
        let capture = try #require(
            view.range(of: "let invocation = ModelJobInvocation(parentModelName: selectedModel, source: source)")
        )
        let task = try #require(view.range(of: "compactionTask = Task {"))
        #expect(capture.lowerBound < task.lowerBound)
        #expect(view.contains("invocation: invocation,"))
    }

    @Test("image cleanup joins the producer before unload, restore and releasing the parent hold")
    func imageDrainWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let coordinator = try String(
            contentsOf: root.appendingPathComponent(
                "Services/AgentDelegation/NativeImageJobCoordinator.swift"
            ),
            encoding: .utf8
        )
        let drain = try #require(coordinator.range(of: "await imageService.waitForJobDrain(jobID: jobID)"))
        let unload = try #require(coordinator.range(of: "if unloadImage { await imageService.unload() }"))
        let restore = try #require(coordinator.range(of: "await ChatResidencyHandoff.restoreBestEffort(lease)"))
        let release = try #require(coordinator.range(of: "await ModelRuntime.shared.releaseInvokingParent(retention)"))
        #expect(drain.lowerBound < unload.lowerBound)
        #expect(unload.lowerBound < restore.lowerBound)
        #expect(restore.lowerBound < release.lowerBound)
        #expect(coordinator.contains("guard plan.shouldUnload else { return .empty }"))
        #expect(coordinator.contains("restoreParentWhenNotResident: true"))
        #expect(coordinator.contains("SubagentResidency.planForLocalTarget("))
        let service = try String(
            contentsOf: root.appendingPathComponent(
                "Services/ModelRuntime/ImageGenerationService.swift"
            ),
            encoding: .utf8
        )
        #expect(!service.contains("task.cancel()"))
        #expect(service.contains("cancellation.cancel()"))
        #expect(service.contains("await producerJobs[jobID]?.task.value"))
        #expect(service.contains("producerJobs[jobID]?.cancel()"))
    }

    @Test("queued image cancellation does not acquire or release a GPU lane")
    func queuedImageCancellation() async throws {
        let gate = MetalGate.makeForTesting()
        await gate.acquire("other-producer", shared: false)
        let cancellation = ImageJobCancellation { try await gate.enterImageGeneration() }
        cancellation.cancel()
        do {
            try await cancellation.enter()
            Issue.record("Cancelled image acquired the occupied GPU lane")
        } catch is CancellationError {}
        #expect(cancellation.isRequested)
        await gate.release("other-producer")
        // A subsequent acquisition also detects an accidentally retained gate.
        try await gate.enterImageGeneration()
        await gate.exitImageGeneration()
    }

    @Test("in-flight image cancellation leaves the engine consumer alive through its final event")
    func imageConsumerDrainsAfterCancellation() async throws {
        let cancellation = ImageJobCancellation(enter: {})
        let (events, emit) = AsyncStream<Int>.makeStream()
        let (entered, signalEntry) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            try await cancellation.enter()
            signalEntry.yield(())
            signalEntry.finish()
            var drained: [Int] = []
            for await event in events {
                #expect(!Task.isCancelled)
                drained.append(event)
            }
            return drained
        }
        for await _ in entered { break }
        emit.yield(1)
        cancellation.cancel()
        emit.yield(2)
        emit.finish()
        #expect(try await consumer.value == [1, 2])
        #expect(cancellation.isRequested)
    }

    @Test(
        "restoration retains schedule/API provenance instead of becoming chat-owned",
        arguments: SessionSource.allCases
    )
    func restoreProvenance(source: SessionSource) {
        let lease = ChatResidencyLease(
            unloadedModelNames: [],
            restoreModelNames: ["parent"],
            parentSource: source.inferenceSource
        )
        #expect(lease.isRestoreOnly)
        #expect(lease.parentSource == source.inferenceSource)
    }

    private func makeHandoff(log: AuxiliaryHandoffLog, onRestored: @escaping @Sendable () -> Void = {})
        -> ResidencyHandoff
    {
        ResidencyHandoff(
            plan: { _ in ResidencyPlan(shouldUnload: true) },
            preflight: { _, _, _ in await log.record("preflight") },
            unload: { parent, _, _ in
                #expect(parent == "parent")
                await log.record("unload")
                return ChatResidencyLease(unloadedModelNames: ["parent"])
            },
            restore: { _, _ in
                #expect(!Task.isCancelled)
                await log.record("restore-parent")
                onRestored()
                return ["parent"]
            },
            releaseDelegate: { _, _ in
                await log.record("release-child")
                return ["child"]
            }
        )
    }

    private var scope: SubagentScope {
        SubagentScope(sessionId: "session", toolCallId: "job", agentId: Agent.defaultId, parentModelName: "parent")
    }
    private var resolved: ResolvedModel { ResolvedModel(name: "child", id: "child", isLocal: true) }
    private func feed() -> SubagentFeed {
        SubagentFeed(toolCallId: "job", kindId: "context_compaction", title: "compaction")
    }
}
