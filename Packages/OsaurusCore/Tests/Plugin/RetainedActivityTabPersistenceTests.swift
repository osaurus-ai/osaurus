import Foundation
import Testing

@testable import OsaurusCore

/// A real isolated defaults suite, with one controlled blocked write. The
/// safety deadline releases an old synchronous implementation so it fails
/// assertions instead of deadlocking the test runner.
private final class BlockingRetainedTabDefaults: UserDefaults, @unchecked Sendable {
    private let condition = NSCondition()
    private var shouldBlock = true
    private var entered = false
    private var blockedOnMain = false
    private var writes: [Data?] = []

    var hasEnteredWrite: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    var writeRanOnMain: Bool {
        condition.lock()
        defer { condition.unlock() }
        return blockedOnMain
    }

    var snapshots: [Data?] {
        condition.lock()
        defer { condition.unlock() }
        return writes
    }

    func releaseWrite() {
        condition.lock()
        shouldBlock = false
        condition.broadcast()
        condition.unlock()
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        // Foundation implements removeObject by forwarding to set(nil).
        // Count the explicit remove in its override below, not that internal
        // forwarding call as a second logical store mutation.
        if defaultName == "retainedNotchTabs.v1", let data = value as? Data {
            condition.lock()
            entered = true
            blockedOnMain = blockedOnMain || Thread.isMainThread
            let deadline = Date().addingTimeInterval(3)
            while shouldBlock, condition.wait(until: deadline) {}
            writes.append(data)
            condition.unlock()
        }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        if defaultName == "retainedNotchTabs.v1" {
            condition.lock()
            blockedOnMain = blockedOnMain || Thread.isMainThread
            writes.append(nil)
            condition.unlock()
        }
        super.removeObject(forKey: defaultName)
    }
}

@Suite(.serialized)
@MainActor
struct RetainedActivityTabPersistenceTests {
    private func waitForWrite(_ defaults: BlockingRetainedTabDefaults) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !defaults.hasEnteredWrite, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(defaults.hasEnteredWrite)
    }

    private func makeState() -> BackgroundTaskState {
        let id = UUID()
        let context = ExecutionContext(id: id, agentId: Agent.defaultId)
        context.chatSession.chatEngineFactory = { _ in MockChatEngine() }
        context.chatSession.turns = [
            ChatTurn(role: .user, content: "Retain this result"),
            ChatTurn(role: .assistant, content: "The completed answer"),
        ]
        context.chatSession.save()
        return BackgroundTaskState(
            id: id,
            taskTitle: "Original",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .running
        )
    }

    @Test func blockedWriteDoesNotHoldStreamingCompletionOrMainActor() async throws {
        try await ChatHistoryTestStorage.run {
            let suite = "RetainedActivityTabPersistenceTests.\(UUID())"
            let defaults = try #require(BlockingRetainedTabDefaults(suiteName: suite))
            defer { defaults.releaseWrite(); defaults.removePersistentDomain(forName: suite) }
            let manager = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
            let state = makeState()
            let session = try #require(state.chatSession)
            manager.registerTaskForTesting(state)
            manager.observeChatTask(state, session: session)
            session.isStreaming = true
            session.isStreaming = false
            try await waitForWrite(defaults)
            #expect(state.status == .completed(summary: "Chat completed"))
            #expect(!defaults.writeRanOnMain)
            // We reached this MainActor continuation while the store still
            // holds the write. Completion and UI state do not await that IPC.
            let notYetDrained = await Task.detached {
                manager.flushRetainedTabWrites(timeout: 0.02)
            }.value
            #expect(!notYetDrained)
            defaults.releaseWrite()
            let saved = await Task.detached { manager.flushRetainedTabWrites() }.value
            #expect(saved)
            let restored = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
            #expect(restored.taskState(for: state.id)?.taskTitle == "Original")
            #expect(restored.taskState(for: state.id)?.status == .completed(summary: "Chat completed"))
            manager.finalizeTask(state.id)
            let cleared = await Task.detached { manager.flushRetainedTabWrites() }.value
            #expect(cleared)
        }
    }

    @Test func blockedOlderSnapshotCannotOverwriteRenameOrResurrectFinalizedTab() async throws {
        try await ChatHistoryTestStorage.run {
            let suite = "RetainedActivityTabPersistenceTests.\(UUID())"
            let defaults = try #require(BlockingRetainedTabDefaults(suiteName: suite))
            defer { defaults.releaseWrite(); defaults.removePersistentDomain(forName: suite) }
            let manager = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
            let state = makeState()
            state.status = .completed(summary: "Chat completed")
            manager.registerTaskThroughProductionPathForTesting(state)
            try await waitForWrite(defaults)
            #expect(!defaults.writeRanOnMain)
            #expect(manager.renameTask(state.id, title: "Renamed"))
            manager.finalizeTask(state.id)
            defaults.releaseWrite()
            let drained = await Task.detached { manager.flushRetainedTabWrites() }.value
            #expect(drained)
            let snapshots = defaults.snapshots
            #expect(snapshots.count == 3)
            let titles = try snapshots.compactMap { data -> String? in
                guard let data else { return nil }
                let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                return records.first?["title"] as? String
            }
            #expect(titles == ["Original", "Renamed"])
            #expect(snapshots.last.map { $0 == nil } == true)
            #expect(defaults.data(forKey: "retainedNotchTabs.v1") == nil)
            let relaunched = BackgroundTaskManager.makeForTestingRetaining(defaults: defaults)
            #expect(relaunched.taskState(for: state.id) == nil)
        }
    }
}
