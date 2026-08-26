//
//  SubagentBackgroundTaskBridgeTests.swift
//  osaurusTests
//
//  Pins the spawned-helper → background-task mirror contract: a registered
//  spawn feed surfaces as a running notch task, feed phases drive the
//  mirror's step/activity, the feed's terminal status closes the row, a
//  notch cancel trips the run's interrupt token, and mirrors never consume
//  a dispatch execution slot.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SubagentBackgroundTaskBridgeTests {

    // MARK: - Helpers

    private func makeBridge() -> (
        bridge: SubagentBackgroundTaskBridge,
        manager: BackgroundTaskManager,
        registry: SubagentFeedRegistry
    ) {
        let manager = BackgroundTaskManager.makeForTesting()
        let registry = SubagentFeedRegistry.makeForTesting()
        let bridge = SubagentBackgroundTaskBridge(manager: manager, registry: registry)
        bridge.start()
        return (bridge, manager, registry)
    }

    private func spawnFeed(
        toolCallId: String,
        title: String = "spawn → Helper",
        agentId: UUID? = Agent.defaultId
    ) -> SubagentFeed {
        SubagentFeed(
            toolCallId: toolCallId,
            kindId: SubagentCapabilityRegistry.spawn.id,
            title: title,
            agentId: agentId,
            parentSessionId: nil
        )
    }

    private func mirror(
        in manager: BackgroundTaskManager,
        toolCallId: String
    ) -> BackgroundTaskState? {
        manager.backgroundTasks.values.first { $0.subagentToolCallId == toolCallId }
    }

    /// Publisher delivery hops to the main queue; poll until the expected
    /// state lands (bounded so a regression fails fast instead of hanging).
    private func waitUntil(
        timeoutMs: Int = 2_000,
        _ condition: @MainActor () -> Bool
    ) async throws {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
    }

    // MARK: - Tests

    @Test("a registered spawn feed surfaces as a running mirror task")
    func spawnFeedCreatesRunningMirror() async throws {
        let (bridge, manager, registry) = makeBridge()
        _ = bridge
        let toolCallId = "bridge-test-\(UUID().uuidString)"

        registry.register(spawnFeed(toolCallId: toolCallId, title: "spawn → Research helper"))
        try await waitUntil { mirror(in: manager, toolCallId: toolCallId) != nil }

        let state = try #require(mirror(in: manager, toolCallId: toolCallId))
        #expect(state.status == .running)
        #expect(state.isSubagentMirror)
        #expect(state.taskTitle == "spawn → Research helper")
        #expect(state.agentId == Agent.defaultId)
        // Visible in the notch ordering (no window owns a spawn mirror).
        #expect(manager.sortedToastTasks.contains { $0.id == state.id })

        manager.finalizeTask(state.id)
    }

    @Test("true-delegation feeds are not mirrored (their dispatched run owns the notch row)")
    func delegatedFeedsAreNotMirrored() async throws {
        let (bridge, manager, registry) = makeBridge()
        _ = bridge
        let toolCallId = "bridge-test-\(UUID().uuidString)"

        registry.register(
            SubagentFeed(
                toolCallId: toolCallId,
                kindId: SubagentCapabilityRegistry.spawn.id,
                title: "spawn → Delegated Helper",
                agentId: Agent.defaultId,
                parentSessionId: nil,
                suppressNotchMirror: true
            )
        )
        // Give delivery a beat, then confirm nothing was adopted — the real
        // dispatched chat task is the run's single notch row.
        try await Task.sleep(for: .milliseconds(50))
        #expect(mirror(in: manager, toolCallId: toolCallId) == nil)
    }

    @Test("non-spawn subagent kinds are not mirrored")
    func nonSpawnKindsAreIgnored() async throws {
        let (bridge, manager, registry) = makeBridge()
        _ = bridge
        let toolCallId = "bridge-test-\(UUID().uuidString)"

        registry.register(
            SubagentFeed(toolCallId: toolCallId, kindId: "image", title: "an image job")
        )
        // Give delivery a beat, then confirm nothing was adopted.
        try await Task.sleep(for: .milliseconds(50))
        #expect(mirror(in: manager, toolCallId: toolCallId) == nil)
    }

    @Test("feed phases drive the mirror's current step and activity feed")
    func feedPhasesForwardIntoMirror() async throws {
        let (bridge, manager, registry) = makeBridge()
        _ = bridge
        let toolCallId = "bridge-test-\(UUID().uuidString)"
        let feed = spawnFeed(toolCallId: toolCallId)

        registry.register(feed)
        try await waitUntil { mirror(in: manager, toolCallId: toolCallId) != nil }
        let state = try #require(mirror(in: manager, toolCallId: toolCallId))

        feed.emitPhase("validating target")
        feed.emitPhase("running", detail: "turn 1")
        try await waitUntil { state.currentStep == "running" }

        #expect(state.currentStep == "running")
        #expect(state.activityFeed.contains { $0.title == "validating target" })
        #expect(state.activityFeed.contains { $0.title == "running" && $0.detail == "turn 1" })

        manager.finalizeTask(state.id)
    }

    @Test("finishing the feed closes the mirror with the digest summary")
    func feedFinishClosesMirror() async throws {
        let (bridge, manager, registry) = makeBridge()
        _ = bridge
        let toolCallId = "bridge-test-\(UUID().uuidString)"
        let feed = spawnFeed(toolCallId: toolCallId)

        registry.register(feed)
        try await waitUntil { mirror(in: manager, toolCallId: toolCallId) != nil }
        let state = try #require(mirror(in: manager, toolCallId: toolCallId))

        feed.finish(success: true, summary: "Weather fetched: 72°F, sunny")
        try await waitUntil { !state.status.isActive }

        #expect(state.status == .completed(summary: "Weather fetched: 72°F, sunny"))
        #expect(state.currentStep == nil)
        #expect(manager.hasPendingAutoFinalizeForTesting(state.id))

        manager.finalizeTask(state.id)
    }

    @Test("a failed feed closes the mirror as failed")
    func feedFailureClosesMirrorAsFailed() async throws {
        let (bridge, manager, registry) = makeBridge()
        _ = bridge
        let toolCallId = "bridge-test-\(UUID().uuidString)"
        let feed = spawnFeed(toolCallId: toolCallId)

        registry.register(feed)
        try await waitUntil { mirror(in: manager, toolCallId: toolCallId) != nil }
        let state = try #require(mirror(in: manager, toolCallId: toolCallId))

        feed.finish(success: false, summary: "iteration cap reached")
        try await waitUntil { !state.status.isActive }

        #expect(state.status == .failed(summary: "iteration cap reached"))

        manager.finalizeTask(state.id)
    }

    @Test("cancelling the mirror trips the spawn's interrupt token")
    func cancelMirrorInterruptsRun() async throws {
        let (bridge, manager, registry) = makeBridge()
        _ = bridge
        let toolCallId = "bridge-test-\(UUID().uuidString)"
        let feed = spawnFeed(toolCallId: toolCallId)
        let token = InterruptToken()
        SubagentInterruptCenter.shared.register(token, for: toolCallId)
        defer { SubagentInterruptCenter.shared.unregister(toolCallId) }

        registry.register(feed)
        try await waitUntil { mirror(in: manager, toolCallId: toolCallId) != nil }
        let state = try #require(mirror(in: manager, toolCallId: toolCallId))

        manager.cancelTask(state.id)

        #expect(token.isInterrupted)
        #expect(state.status == .cancelled)

        // The run's own terminal status arrives later; the user's cancel
        // verdict must not be overwritten by it.
        feed.finish(success: false, summary: "stopped")
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.status == .cancelled)

        manager.finalizeTask(state.id)
    }

    @Test("mirrors never consume dispatch execution slots")
    func mirrorsDoNotConsumeExecutionSlots() async throws {
        let manager = BackgroundTaskManager.makeForTesting()
        let agentId = Agent.defaultId

        // Six running mirrors — past the per-agent cap of five — must not
        // block admission of a real dispatched task for the same agent.
        for index in 0..<6 {
            let state = BackgroundTaskState(
                subagentMirrorId: UUID(),
                toolCallId: "slot-test-\(index)-\(UUID().uuidString)",
                parentSessionId: nil,
                taskTitle: "spawn → Helper \(index)",
                agentId: agentId
            )
            manager.registerSubagentMirror(state)
        }

        let context = ExecutionContext(agentId: agentId)
        let real = BackgroundTaskState(
            id: UUID(),
            taskTitle: "real task",
            agentId: agentId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .running
        )
        manager.admitTaskForTesting(real) {}

        #expect(real.status == .running)

        for id in manager.backgroundTasks.keys {
            manager.finalizeTask(id)
        }
    }
}
