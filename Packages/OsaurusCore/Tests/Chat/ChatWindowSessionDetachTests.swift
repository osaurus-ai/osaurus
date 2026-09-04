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
        // This suite exercises window/session lifecycle with a scripted
        // plain-chat engine. Once the run detaches from the originating test
        // task, a TaskLocal value no longer describes its intent, so pin the
        // test-only override on the session that actually owns the run.
        session.toolsDisabledForTestingOverride = true
        // Never let the user's installed/default model selection reroute this
        // scripted text-engine test through an image-generation model.
        session.selectedModel = "chat-window-detach-test-model"
        session.forceChatEngineRouteForTests = true
        session.chatEngineFactory = { _ in SlowFinishingChatEngine(delayMs: delayMs) }
        session.send(prompt)
        try await waitUntil(timeout: .seconds(2)) { session.isStreaming }
        return session
    }

    // MARK: New chat while streaming

    /// A new chat while a run is in flight opens a NEW tab (browser-style):
    /// the run keeps its own tab, still window-owned and streaming, and its
    /// output never leaks into the new chat.
    @Test func startNewChat_whileStreaming_opensNewTabAndKeepsRunInItsTab() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let running = try await startStream(in: window, prompt: "long question")

            window.startNewChat()

            #expect(window.session !== running, "window must show a fresh session")
            #expect(window.session.turns.isEmpty)
            #expect(running.isStreaming, "UI context switch must not stop the run")
            #expect(window.tabs.count == 2)
            #expect(window.tabSessions.contains { $0 === running })
            #expect(running.windowState === window)
            let sessionId = try #require(running.sessionId)
            #expect(mgr.liveTask(forSessionId: sessionId) == nil, "no registry hand-off: the tab owns the run")

            try await waitUntil { !running.isStreaming }
            #expect(running.turns.contains { $0.role == .assistant && $0.content.contains("background answer") })
            #expect(window.session.turns.isEmpty, "background output must not leak into the new chat")

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

    /// Reopening a chat that is still running in ANOTHER tab focuses that
    /// tab: the exact live instance is shown again, never a stale disk copy
    /// loaded into a second session.
    @Test func loadSession_ofLiveRun_focusesItsTab() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let running = try await startStream(in: window, prompt: "still working", delayMs: 800)

            // New chat: the run keeps its tab while a fresh tab takes over.
            window.startNewChat()
            let runningId = try #require(running.sessionId)
            #expect(window.session !== running)
            #expect(running.isStreaming)
            let runningTabId = try #require(window.tabs.first { $0.session === running }?.id)

            // Reopen the running chat (e.g. from history): its tab is
            // selected and the live instance is back on screen.
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

            #expect(window.session === running, "reopening a live chat must show the in-memory session")
            #expect(window.activeTabId == runningTabId)
            #expect(window.tabs.count == 2, "no duplicate tab for a chat that is already open")
            #expect(running.windowState === window)
            #expect(mgr.liveTask(forSessionId: runningId) == nil, "tab-owned run: no registry task")

            // Subsequent deltas keep landing in the same session.
            try await waitUntil { !running.isStreaming }
            #expect(window.session.turns.contains { $0.role == .assistant && $0.content.contains("background answer") })

            window.cleanup()
        }
    }

    // MARK: Agent switch while streaming

    /// Switching agents while a run is in flight opens the new agent in a
    /// NEW tab (browser-style) rather than detaching the run to the
    /// background registry: the streaming chat keeps its tab, keeps
    /// rendering, and stays owned by the window.
    @Test func switchAgent_whileStreaming_opensNewTabAndKeepsRunInItsTab() async throws {
        try await ChatHistoryTestStorage.run {
            let custom = Agent(
                name: "DetachSwitch-\(UUID().uuidString.prefix(6))",
                systemPrompt: "test",
                agentAddress: "test-detach-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: false)
            )
            AgentManager.shared.add(custom)

            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            let running = try await startStream(in: window, prompt: "hold on")

            window.switchAgent(to: custom.id)

            #expect(window.session !== running)
            #expect(window.session.agentId == custom.id)
            #expect(window.session.turns.isEmpty)
            #expect(running.isStreaming, "switching agents must not stop the previous run")
            // The run stayed in its own tab, still window-owned: no registry
            // hand-off, and the window now shows two tabs.
            #expect(window.tabs.count == 2)
            #expect(window.tabSessions.contains { $0 === running })
            #expect(running.windowState === window)
            let runningId = try #require(running.sessionId)
            #expect(mgr.liveTask(forSessionId: runningId) == nil)

            try await waitUntil { !running.isStreaming }
            #expect(running.turns.contains { $0.role == .assistant && $0.content.contains("background answer") })
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
