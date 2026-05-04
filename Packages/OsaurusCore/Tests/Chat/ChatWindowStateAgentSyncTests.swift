//
//  ChatWindowStateAgentSyncTests.swift
//  osaurusTests
//
//  Pin the contract introduced to fix
//  https://github.com/osaurus-ai/osaurus/issues/1004 — namely that a
//  `ChatWindowState`'s `agents` snapshot, `cachedActiveAgent`,
//  `cachedAgentDisplayName`, and `cachedSystemPrompt` reflect mutations
//  to `AgentManager.shared.agents` (and `ChatConfiguration` for the
//  Default agent) without requiring the chat window to be closed and
//  reopened.
//
//  Two refresh paths are exercised:
//  1. The `AgentManager.shared.$agents` Combine subscription in
//     `ChatWindowState.observeAgentManager`, which covers add / delete /
//     update / rename / avatar / theme / model / system-prompt / tool-
//     selection / tool-allowlist / skill-allowlist changes for custom
//     agents.
//  2. The retained `.appConfigurationChanged` notification observer,
//     which covers the Default agent whose mutable settings live in
//     `ChatConfiguration` rather than the `Agent` struct.
//
//  Tests reuse the `ChatHistoryTestStorage` helper to isolate chat history
//  and agent persistence while serializing access to `AgentManager.shared`.
//

import Combine
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatWindowStateAgentSyncTests {

    // MARK: - Helpers

    /// Allow the main `OperationQueue` to drain once so that observers
    /// added with `addObserver(forName:object:queue: .main)` get a chance
    /// to run. Notification posts are synchronous, but the observer block
    /// is enqueued via `OperationQueue.main.addOperation`, which dispatches
    /// asynchronously even when the poster is already on main.
    private func flushMainQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    private func makeCustomAgent(
        name: String,
        systemPrompt: String = "Test identity",
        toolSelectionMode: ToolSelectionMode? = nil,
        manualToolNames: [String]? = nil,
        themeId: UUID? = nil,
        avatar: String? = nil
    ) -> Agent {
        Agent(
            name: "\(name)-\(UUID().uuidString.prefix(6))",
            systemPrompt: systemPrompt,
            themeId: themeId,
            agentAddress: "test-windowstate-\(UUID().uuidString)",
            toolSelectionMode: toolSelectionMode,
            manualToolNames: manualToolNames,
            avatar: avatar
        )
    }

    /// Build a `ChatWindowState` for a given agent id. The session has
    /// no turns and is never sent, so heavyweight chat-engine code is
    /// not exercised — only the agent-snapshot wiring under test.
    private func makeWindow(for agentId: UUID) -> ChatWindowState {
        ChatWindowState(windowId: UUID(), agentId: agentId)
    }

    // MARK: - 1. Add propagates to dropdown

    /// The primary failure mode reported in #1004: opening the new-chat
    /// agent dropdown while the chat window is open should reflect agents
    /// added afterwards (from AgentsView, onboarding, plugins, …).
    @Test("add → new agent appears in windowState.agents synchronously")
    func add_propagatesToWindowAgents() async throws {
        try await ChatHistoryTestStorage.run {
            let window = makeWindow(for: Agent.defaultId)
            let countBefore = window.agents.count

            let custom = makeCustomAgent(name: "AddTest")
            AgentManager.shared.add(custom)

            #expect(window.agents.contains(where: { $0.id == custom.id }))
            #expect(window.agents.count == countBefore + 1)

            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    // MARK: - 2. Active agent updates flow through the Combine sink

    @Test("rename active custom agent → cachedAgentDisplayName + cachedActiveAgent update")
    func renameActive_updatesCachesSynchronously() async throws {
        try await ChatHistoryTestStorage.run {
            let custom = makeCustomAgent(name: "RenameActive")
            AgentManager.shared.add(custom)

            let window = makeWindow(for: custom.id)
            #expect(window.cachedAgentDisplayName == custom.name)
            #expect(window.cachedActiveAgent.id == custom.id)

            var updated = custom
            updated.name = "RenamedAgent-\(UUID().uuidString.prefix(6))"
            updated.avatar = "🦖"
            AgentManager.shared.update(updated)

            #expect(window.cachedActiveAgent.name == updated.name)
            #expect(window.cachedActiveAgent.avatar == "🦖")
            #expect(window.cachedAgentDisplayName == updated.name)

            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    @Test("active custom agent system prompt change → cachedSystemPrompt updates")
    func activeCustomAgentSystemPromptChange_updatesCachedSystemPrompt() async throws {
        try await ChatHistoryTestStorage.run {
            let custom = makeCustomAgent(name: "PromptTest", systemPrompt: "before")
            AgentManager.shared.add(custom)

            let window = makeWindow(for: custom.id)
            #expect(window.cachedSystemPrompt == "before")

            var updated = custom
            updated.systemPrompt = "after-\(UUID().uuidString.prefix(6))"
            AgentManager.shared.update(updated)

            #expect(window.cachedSystemPrompt == updated.systemPrompt)

            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    @Test("active custom agent tool selection change → cachedActiveAgent reflects new mode/allowlist")
    func activeCustomAgentToolSelectionChange_updatesCachedActiveAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let custom = makeCustomAgent(name: "ToolSelTest", toolSelectionMode: .auto)
            AgentManager.shared.add(custom)

            let window = makeWindow(for: custom.id)
            #expect(window.cachedActiveAgent.toolSelectionMode == .auto)

            AgentManager.shared.updateToolSelectionMode(.manual, for: custom.id)
            AgentManager.shared.updateEnabledToolNames(["pdf_extract", "search_memory"], for: custom.id)

            #expect(window.cachedActiveAgent.toolSelectionMode == .manual)
            #expect(window.cachedActiveAgent.manualToolNames == ["pdf_extract", "search_memory"])

            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    /// Pins that the existing `.appConfigurationChanged` observer was
    /// preserved across the issue-1004 fix. Without this, a future
    /// contributor could remove that observer thinking the new Combine
    /// sink covers Default-agent updates too — but the Default agent's
    /// settings live in `ChatConfiguration`, not the `Agent` struct, so
    /// they never trigger a `$agents` emission.
    @Test("Default agent system prompt change → cachedSystemPrompt updates via .appConfigurationChanged")
    func defaultAgentSystemPromptChange_updatesCachedSystemPrompt() async throws {
        try await ChatHistoryTestStorage.run {
            let window = makeWindow(for: Agent.defaultId)
            let originalConfig = ChatConfigurationStore.load()
            defer { ChatConfigurationStore.save(originalConfig) }

            var updatedConfig = originalConfig
            updatedConfig.systemPrompt = "new-default-prompt-\(UUID().uuidString.prefix(6))"
            ChatConfigurationStore.save(updatedConfig)

            // .appConfigurationChanged observer dispatches via OperationQueue.main,
            // which is asynchronous even from main thread.
            await flushMainQueue()

            #expect(window.cachedSystemPrompt == updatedConfig.systemPrompt)
        }
    }

    // MARK: - 3. Non-active mutations stay cheap

    /// Renaming a non-active agent must update the dropdown's `agents`
    /// array but must NOT touch `cachedActiveAgent` (i.e. must skip the
    /// heavy `refreshAgentConfig()` path that invalidates the session
    /// token cache).
    @Test("rename non-active agent → list updates, active untouched")
    func renameNonActive_updatesListButLeavesActiveUntouched() async throws {
        try await ChatHistoryTestStorage.run {
            let agentA = makeCustomAgent(name: "ActiveA")
            let agentB = makeCustomAgent(name: "OtherB")
            AgentManager.shared.add(agentA)
            AgentManager.shared.add(agentB)

            let window = makeWindow(for: agentA.id)
            let preActive = window.cachedActiveAgent
            #expect(preActive.id == agentA.id)
            #expect(preActive.name == agentA.name)

            var updatedB = agentB
            updatedB.name = "RenamedB-\(UUID().uuidString.prefix(6))"
            AgentManager.shared.update(updatedB)

            #expect(window.agents.first(where: { $0.id == agentB.id })?.name == updatedB.name)
            #expect(window.cachedActiveAgent.id == agentA.id)
            #expect(window.cachedActiveAgent.name == agentA.name)
            #expect(window.cachedAgentDisplayName == agentA.name)

            _ = await AgentManager.shared.delete(id: agentA.id)
            _ = await AgentManager.shared.delete(id: agentB.id)
        }
    }

    // MARK: - 4. Delete propagates

    @Test("delete non-active agent → disappears from windowState.agents")
    func deleteNonActive_removesFromWindowAgents() async throws {
        try await ChatHistoryTestStorage.run {
            let agentA = makeCustomAgent(name: "KeepA")
            let agentB = makeCustomAgent(name: "DeleteB")
            AgentManager.shared.add(agentA)
            AgentManager.shared.add(agentB)

            let window = makeWindow(for: agentA.id)
            #expect(window.agents.contains(where: { $0.id == agentB.id }))

            _ = await AgentManager.shared.delete(id: agentB.id)

            #expect(!window.agents.contains(where: { $0.id == agentB.id }))
            #expect(window.agentId == agentA.id)
            #expect(window.cachedActiveAgent.id == agentA.id)

            _ = await AgentManager.shared.delete(id: agentA.id)
        }
    }

    /// Deleting the currently active agent from elsewhere must not leave
    /// the window pointing at a dangling id. `applyAgentsUpdate` detects
    /// the missing agent and falls back to the Default agent.
    @Test("delete active agent → falls back to Default")
    func deleteActive_fallsBackToDefault() async throws {
        try await ChatHistoryTestStorage.run {
            let custom = makeCustomAgent(name: "ToDeleteActive")
            AgentManager.shared.add(custom)

            let window = makeWindow(for: custom.id)
            #expect(window.agentId == custom.id)
            #expect(window.cachedActiveAgent.id == custom.id)

            _ = await AgentManager.shared.delete(id: custom.id)

            #expect(window.agentId == Agent.defaultId)
            #expect(window.cachedActiveAgent.id == Agent.defaultId)
            #expect(!window.agents.contains(where: { $0.id == custom.id }))
        }
    }

    // MARK: - 5. AgentManager publisher contract

    // MARK: - 6. Issue #1005 end-to-end repro

    /// End-to-end pin for https://github.com/osaurus-ai/osaurus/issues/1005.
    ///
    /// Reproduces the user's exact sequence:
    ///   1. Window opens on Default agent.
    ///   2. A conversation already exists on disk under custom agent X
    ///      (we seed it directly via the in-memory session model).
    ///   3. The user clicks that conversation in the sidebar
    ///      (`windowState.loadSession`).
    ///   4. The user clicks "New Chat" (`windowState.startNewChat`).
    ///
    /// Pre-fix bugs hit two places at once:
    ///   - `loadSession` did not update `window.agentId`, leaving the
    ///     chat header / dropdown / sidebar filter stuck on Default
    ///     while the loaded conversation belonged to X.
    ///   - `startNewChat` then called `session.reset(for: window.agentId
    ///     /* = default */)`, which (via `stop()` →
    ///     `completeRunCleanup()` → `save()`) re-tagged the original
    ///     session's row to Default.
    ///
    /// Post-fix we expect:
    ///   - `loadSession` sets `window.agentId = X`, refreshes
    ///     `cachedActiveAgent`, and re-filters the sidebar to X.
    ///   - Any save fired during `startNewChat` STILL targets X (the
    ///     `ChatSession.reset(for:)` re-order keeps the old agent in
    ///     scope while `stop()` runs).
    @Test("issue #1005: loadSession + startNewChat preserves conversation's agent")
    func issue1005_loadSession_thenNewChat_preservesAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let custom = makeCustomAgent(name: "Issue1005")
            AgentManager.shared.add(custom)

            // Window opens on Default — mirrors the user being in the
            // Default agent at the time they click on a custom-agent
            // conversation in the sidebar.
            let window = makeWindow(for: Agent.defaultId)
            #expect(window.agentId == Agent.defaultId)

            // Seed an existing conversation under custom agent X. We
            // hand-build a `ChatSessionData` with non-empty turns so the
            // subsequent `session.save()` in `startNewChat`'s reset
            // chain has something to persist (the bug only fires when
            // turns are non-empty).
            let originalSessionId = UUID()
            let seededSession = ChatSessionData(
                id: originalSessionId,
                title: "Seeded under X",
                createdAt: Date(),
                updatedAt: Date(),
                selectedModel: nil,
                turns: [
                    ChatTurnData(role: .user, content: "Hello X"),
                    ChatTurnData(role: .assistant, content: "Hi from X"),
                ],
                agentId: custom.id
            )

            // Capture every (sessionId, agentId) pair that `save()`
            // sees during the entire #1005 sequence. With the fix in
            // place, ALL such snapshots for `originalSessionId` must
            // carry `custom.id` — never `Agent.defaultId`.
            var saveSnapshots: [(sessionId: UUID?, agentId: UUID?)] = []
            window.session.onSessionChanged = {
                saveSnapshots.append(
                    (window.session.sessionId, window.session.agentId)
                )
            }

            // Step 4: user clicks the seeded conversation in the sidebar.
            window.loadSession(seededSession)

            // Post-loadSession: the window's active agent should now
            // match the conversation's. Pre-fix, `window.agentId` would
            // still be `Agent.defaultId` here, which is what set up the
            // disk corruption in the next step.
            #expect(
                window.agentId == custom.id,
                "loadSession must adopt the conversation's agent (#1005)"
            )
            #expect(window.cachedActiveAgent.id == custom.id)
            #expect(window.session.agentId == custom.id)
            #expect(window.session.sessionId == originalSessionId)

            // Sidebar filter follows the window's agent. After the fix,
            // any in-memory session not belonging to X must be filtered
            // out — pre-fix the window stayed on Default and would still
            // surface every session.
            for filtered in window.filteredSessions {
                #expect(
                    (filtered.agentId ?? Agent.defaultId) == custom.id,
                    "sidebar surfaced session for agent \(filtered.agentId?.uuidString ?? "default") while window adopted \(custom.id) (#1005)"
                )
            }

            // Step 5: user clicks "New Chat".
            window.startNewChat()

            // Every save that fired for the original session id must
            // have preserved the custom agent. A snapshot with
            // `agentId == Agent.defaultId` is the on-disk corruption
            // signature.
            for snapshot in saveSnapshots where snapshot.sessionId == originalSessionId {
                #expect(
                    snapshot.agentId == custom.id,
                    "save during loadSession+startNewChat re-tagged session \(originalSessionId) to \(snapshot.agentId?.uuidString ?? "nil") (#1005)"
                )
            }

            // Final state: the new empty chat sits under the same custom
            // agent the conversation was loaded into, NOT back on Default.
            #expect(window.agentId == custom.id)
            #expect(window.session.agentId == custom.id)
            #expect(window.session.sessionId == nil)
            #expect(window.session.turns.isEmpty)

            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    // MARK: - 7. AgentManager publisher contract

    /// Pin the publisher contract `ChatWindowState.observeAgentManager`
    /// now relies on. A future refactor that stops mutating
    /// `AgentManager.agents` on add/delete (e.g. switching to a
    /// notification-only model) would silently re-break the picker
    /// without this test.
    @Test("AgentManager.$agents emits on add and delete")
    func agentManagerPublisher_emitsOnAddAndDelete() async throws {
        try await ChatHistoryTestStorage.run {
            var emissionCount = 0
            let cancellable = AgentManager.shared.$agents.sink { _ in
                emissionCount += 1
            }
            // Discard the initial replay: Combine `@Published` always sends
            // the current value on subscribe.
            let initialReplayCount = emissionCount

            let custom = makeCustomAgent(name: "EmitTest")
            AgentManager.shared.add(custom)
            let afterAdd = emissionCount

            _ = await AgentManager.shared.delete(id: custom.id)
            let afterDelete = emissionCount

            cancellable.cancel()

            #expect(afterAdd > initialReplayCount, "add() should emit on $agents")
            #expect(afterDelete > afterAdd, "delete() should emit on $agents")
        }
    }
}
