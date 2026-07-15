//
//  ChatWindowSessionDetachTests.swift
//  osaurusTests
//
//  Pins the "UI context switch only detaches the view" contract on
//  `ChatWindowState` + `BackgroundTaskManager`:
//
//  - Starting a new chat / loading another session / switching agent while
//    a run is streaming hands the running `ChatSession` to the registry
//    (execution continues) and installs a replacement session — it never
//    stops the run.
//  - The detached run's output lands only in its own session; the window's
//    new session never sees it.
//  - Reopening a chat the registry is still running re-attaches the SAME
//    in-memory `ChatSession` instance (subsequent deltas keep landing in
//    it) instead of hydrating a stale copy from disk.
//  - Tearing down one window state never stops another window's stream.
//
//  Uses `ChatHistoryTestStorage` for isolated persistence; engines are
//  scripted test doubles, so no real model is loaded.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Engine double

/// Blocks long enough for the test to switch UI context mid-stream, then
/// yields one delta and finishes cleanly.
private actor SlowFinishingChatEngine: ChatEngineProtocol {
    let delayMs: Int

    init(delayMs: Int) {
        self.delayMs = delayMs
    }

    func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let delay = delayMs
        return AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(delay))
                continuation.yield("background answer")
                continuation.finish()
            }
        }
    }

    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatWindowSessionDetachTests", code: 1)
    }
}

// MARK: - Local waitUntil

private func waitUntil(
    timeout: Duration = .seconds(5),
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "ChatWindowSessionDetachTests", code: 2)
}

// MARK: - Tests

@Suite(.serialized)
@MainActor
struct ChatWindowSessionDetachTests {

    private var mgr: BackgroundTaskManager { BackgroundTaskManager.shared }

    /// Finalize the registry task (if any) that owns the given session so
    /// no state leaks into other suites on the shared manager.
    private func finalizeTask(ownedBy session: ChatSession) {
        if let sessionId = session.sessionId,
            let task = mgr.liveTask(forSessionId: sessionId)
        {
            mgr.finalizeTask(task.id)
        }
    }

    /// Start a stream on the window's current session and wait for it to
    /// be genuinely in flight.
    private func startStream(
        in window: ChatWindowState,
        prompt: String,
        delayMs: Int = 500
    ) async throws -> ChatSession {
        let session = window.session
        session.chatEngineFactory = { _ in SlowFinishingChatEngine(delayMs: delayMs) }
        session.send(prompt)
        try await waitUntil(timeout: .seconds(2)) { session.isStreaming }
        return session
    }

    // MARK: New chat while streaming

    @Test func startNewChat_whileStreaming_detachesRunAndKeepsItStreaming() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let running = try await startStream(in: window, prompt: "long question")

            window.startNewChat()

            // The view detached: the window shows a fresh session while the
            // run keeps executing, now owned by the registry.
            #expect(window.session !== running, "window must install a replacement session")
            #expect(running.isStreaming, "UI context switch must not stop the run")
            let sessionId = try #require(running.sessionId)
            let task = try #require(mgr.liveTask(forSessionId: sessionId))
            #expect(task.status == .running)
            #expect(task.chatSession === running)
            // The detached run no longer pushes view state into this window.
            #expect(running.windowState == nil)

            // The run finishes in the background: its output lands ONLY in
            // its own session; the window's new chat never sees it.
            try await waitUntil { !running.isStreaming }
            #expect(running.turns.contains { $0.role == .assistant && $0.content.contains("background answer") })
            #expect(window.session.turns.isEmpty, "background output must not leak into the new chat")
            try await waitUntil { task.status == .completed(summary: "Chat completed") }

            mgr.finalizeTask(task.id)
            window.cleanup()
        }
    }

    @Test func startNewChat_whileIdle_reusesSessionWithoutRegistryTask() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let idle = window.session

            window.startNewChat()

            // No run in flight → plain reset, no detach, no registry entry.
            #expect(window.session === idle)
            window.cleanup()
        }
    }

    // MARK: Loading another chat while streaming

    @Test func loadSession_whileStreaming_keepsOldRunningAndIsolatesTranscripts() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let running = try await startStream(in: window, prompt: "keep going")

            // The user clicks a different conversation in the sidebar.
            let targetId = UUID()
            let target = ChatSessionData(
                id: targetId,
                title: "Other conversation",
                createdAt: Date(),
                updatedAt: Date(),
                selectedModel: nil,
                turns: [
                    ChatTurnData(role: .user, content: "old question"),
                    ChatTurnData(role: .assistant, content: "old answer"),
                ],
                agentId: Agent.defaultId
            )
            window.loadSession(target)

            // The target loaded into a brand-new session; the old run is
            // registry-owned and still streaming.
            #expect(window.session !== running)
            #expect(window.session.sessionId == targetId)
            #expect(window.session.turns.map(\.content) == ["old question", "old answer"])
            #expect(running.isStreaming)
            let runningId = try #require(running.sessionId)
            #expect(mgr.liveTask(forSessionId: runningId) != nil)

            // Background completion stays out of the loaded conversation.
            try await waitUntil { !running.isStreaming }
            #expect(window.session.turns.count == 2)
            #expect(running.turns.contains { $0.role == .assistant && $0.content.contains("background answer") })

            finalizeTask(ownedBy: running)
            window.cleanup()
        }
    }

    // MARK: Reopening a running chat

    @Test func loadSession_ofLiveRun_reattachesSameSessionInstance() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let running = try await startStream(in: window, prompt: "still working", delayMs: 800)

            // Detach: the window moves to a new chat while the run continues.
            window.startNewChat()
            let runningId = try #require(running.sessionId)
            let task = try #require(mgr.liveTask(forSessionId: runningId))
            #expect(running.isStreaming)

            // Reopen the running chat from the sidebar: the EXACT live
            // instance is re-attached — not a stale disk copy — and the
            // window is bound to the task (view attachment, not ownership).
            let reopenData = ChatSessionData(
                id: runningId,
                title: running.title,
                createdAt: Date(),
                updatedAt: Date(),
                selectedModel: nil,
                turns: [],
                agentId: Agent.defaultId
            )
            window.loadSession(reopenData)

            #expect(window.session === running, "reopening a live chat must attach the in-memory session")
            #expect(mgr.taskId(forWindowId: window.windowId) == task.id)
            #expect(running.windowState === window)

            // Subsequent deltas keep landing in the re-attached session.
            try await waitUntil { !running.isStreaming }
            #expect(window.session.turns.contains { $0.role == .assistant && $0.content.contains("background answer") })

            mgr.finalizeTask(task.id)
            window.cleanup()
        }
    }

    // MARK: Agent switch while streaming

    @Test func switchAgent_whileStreaming_detachesInsteadOfResetting() async throws {
        try await ChatHistoryTestStorage.run {
            let custom = Agent(
                name: "DetachSwitch-\(UUID().uuidString.prefix(6))",
                systemPrompt: "test",
                agentAddress: "test-detach-\(UUID().uuidString)"
            )
            AgentManager.shared.add(custom)

            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let running = try await startStream(in: window, prompt: "hold on")

            window.switchAgent(to: custom.id)

            #expect(window.session !== running)
            #expect(window.session.agentId == custom.id)
            #expect(running.isStreaming, "switching agents must not stop the previous run")
            let runningId = try #require(running.sessionId)
            #expect(mgr.liveTask(forSessionId: runningId) != nil)

            try await waitUntil { !running.isStreaming }
            finalizeTask(ownedBy: running)
            window.cleanup()
            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    // MARK: Two windows

    @Test func tearingDownOneWindow_doesNotStopAnotherWindowsStream() async throws {
        try await ChatHistoryTestStorage.run {
            let windowA = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let windowB = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let streamB = try await startStream(in: windowB, prompt: "window B work")

            // Window A closes (idle) — full cleanup path.
            windowA.cleanup()

            #expect(streamB.isStreaming, "closing window A must not stop window B's run")
            try await waitUntil { !streamB.isStreaming }
            #expect(streamB.turns.contains { $0.role == .assistant && $0.content.contains("background answer") })

            windowB.cleanup()
        }
    }
}
