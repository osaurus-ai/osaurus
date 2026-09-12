//
//  ChatDraftPersistenceTests.swift
//  osaurusTests
//
//  Pin the fix for https://github.com/osaurus-ai/osaurus/issues/2708:
//  unsent composer text must survive switching to another chat or agent
//  and come back when the user returns.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatDraftPersistenceTests {
    @Test("draft typed into a saved chat comes back after loading it again")
    func draftSurvivesLoadRoundTrip() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let first = ChatSessionData(id: UUID(), title: "First")
            let second = ChatSessionData(id: UUID(), title: "Second")

            let session = ChatSession()
            session.load(from: first)
            session.input = "half-typed question"

            session.load(from: second)
            #expect(session.input == "")

            session.load(from: first)
            #expect(session.input == "half-typed question")
        }
    }

    @Test("new-chat draft is kept per agent across reset(for:)")
    func newChatDraftFollowsAgent() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let agentA = UUID()
            let agentB = UUID()

            let session = ChatSession()
            session.agentId = agentA
            session.input = "draft for A"

            session.reset(for: agentB)
            #expect(session.input == "")

            session.input = "draft for B"
            session.reset(for: agentA)
            #expect(session.input == "draft for A")

            session.reset(for: agentB)
            #expect(session.input == "draft for B")
        }
    }

    @Test("draft typed into a saved chat comes back after starting a new chat")
    func draftSurvivesNewChatThenReturn() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let existing = ChatSessionData(id: UUID(), title: "Existing")

            let session = ChatSession()
            session.load(from: existing)
            session.input = "not sent yet"

            session.reset()
            #expect(session.input == "")

            session.load(from: existing)
            #expect(session.input == "not sent yet")
        }
    }

    @Test("a deleted draft does not come back")
    func clearedDraftStaysCleared() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let existing = ChatSessionData(id: UUID(), title: "Existing")

            let session = ChatSession()
            session.load(from: existing)
            session.input = "temporary"
            session.reset()
            session.load(from: existing)
            #expect(session.input == "temporary")

            session.input = ""
            session.reset()
            session.load(from: existing)
            #expect(session.input == "")
        }
    }

    @Test("restore never overwrites text already typed")
    func restoreDoesNotClobberTypedText() {
        ChatDraftStore.shared.removeAll()
        let session = ChatSession()
        session.agentId = nil
        ChatDraftStore.shared.stash("stale", for: session.draftKey)
        session.input = "fresh"
        session.restoreDraft()
        #expect(session.input == "fresh")
        ChatDraftStore.shared.removeAll()
    }

    /// The composer only syncs from `input` when the string changes, so an
    /// in-place agent switch that leaves `input` at `""` must still signal
    /// the card to drop the previous agent's keystrokes.
    @Test("reset(for:) bumps composerGeneration even when input reads the same")
    func resetForBumpsGeneration() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let session = ChatSession()
            session.agentId = UUID()
            session.noteComposerDraft("typed, never promoted")
            #expect(session.input == "")

            let before = session.composerGeneration
            session.reset(for: UUID())
            #expect(session.input == "")
            #expect(session.composerGeneration > before)
        }
    }

    @Test("pending attachments travel with the per-agent draft")
    func attachmentsFollowAgent() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let agentA = UUID()
            let agentB = UUID()
            let pasted = Attachment.pastedContent(String(repeating: "x", count: 64))

            let session = ChatSession()
            session.agentId = agentA
            session.input = "see attached"
            session.pendingAttachments = [pasted]

            session.reset(for: agentB)
            #expect(session.input == "")
            #expect(session.pendingAttachments.isEmpty)

            session.reset(for: agentA)
            #expect(session.input == "see attached")
            #expect(session.pendingAttachments == [pasted])
        }
    }

    @Test("an attachment with no text is still a draft worth keeping")
    func attachmentOnlyDraftIsKept() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let agentA = UUID()
            let agentB = UUID()
            let pasted = Attachment.pastedContent(String(repeating: "y", count: 64))

            let session = ChatSession()
            session.agentId = agentA
            session.pendingAttachments = [pasted]

            session.reset(for: agentB)
            #expect(session.pendingAttachments.isEmpty)
            session.reset(for: agentA)
            #expect(session.pendingAttachments == [pasted])
            #expect(session.input == "")
        }
    }
}

// MARK: - Window-level agent switching

extension ChatDraftPersistenceTests {
    private func makeAgent(_ label: String) -> Agent {
        let agent = Agent(name: "\(label)-\(UUID().uuidString.prefix(6))")
        AgentManager.shared.add(agent)
        return agent
    }

    /// Blank chat, keystrokes only in the composer mirror, pick another
    /// agent: the same session is repurposed in place. The incoming agent
    /// must start empty and the outgoing agent's text must come back.
    @Test("in-place agent switch keeps the draft with its agent")
    func inPlaceSwitchKeepsDraftPerAgent() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let agentB = makeAgent("B")
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            let session = window.session
            session.noteComposerDraft("for the orchestrator")

            window.switchAgent(to: agentB.id)
            #expect(window.session === session)
            #expect(session.agentId == agentB.id)
            #expect(session.input == "")
            #expect(session.unsentComposerText == "")

            session.noteComposerDraft("for B")
            window.switchAgent(to: Agent.defaultId)
            #expect(session.input == "for the orchestrator")

            window.switchAgent(to: agentB.id)
            #expect(session.input == "for B")
        }
    }

    /// The outgoing chat has content, so the incoming agent opens in a
    /// fresh tab. That fresh New Chat must pick up the draft the user left
    /// in the agent's earlier (repurposed) blank chat.
    @Test("a new tab for an agent restores that agent's stranded draft")
    func newTabRestoresAgentDraft() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let agentB = makeAgent("B")
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.session.noteComposerDraft("orchestrator draft")
            // Blank -> repurposed in place for B; the draft is stashed.
            window.switchAgent(to: agentB.id)
            let bSession = window.session
            #expect(bSession.input == "")
            bSession.turns.append(ChatTurn(role: .user, content: "hello B"))

            // B has content now, so the Orchestrator opens in a new tab.
            window.switchAgent(to: Agent.defaultId)
            #expect(window.session !== bSession)
            #expect(window.session.agentId == Agent.defaultId)
            #expect(window.session.input == "orchestrator draft")
        }
    }

    /// https://github.com/osaurus-ai/osaurus/issues/2723: open an existing
    /// conversation, ⌘N a new one, type (not paste), switch to the existing
    /// tab and back. The typed text must still be in the composer. Both
    /// tabs stay warm here, so this is the pure tab-switch path (the
    /// mirror promoted on adopt), not a stash/restore.
    @Test("typed draft survives switching tabs and back (#2723)")
    func typedDraftSurvivesTabRoundTrip() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let existing = ChatSessionData(
                id: UUID(),
                title: "Existing",
                turns: [ChatTurnData(role: .user, content: "earlier question")],
                agentId: Agent.defaultId
            )
            ChatSessionsManager.shared.save(existing)
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.loadSession(existing)
            let existingTabId = window.activeTabId
            window.newTab()
            let fresh = window.session
            let freshTabId = window.activeTabId
            #expect(fresh.turns.isEmpty)
            #expect(window.tabs.count == 2)

            // Keystrokes only reach the composer mirror.
            fresh.noteComposerDraft("half-typed follow up")
            #expect(fresh.input == "")

            window.selectTab(id: existingTabId)
            #expect(window.session !== fresh)
            window.selectTab(id: freshTabId)
            #expect(window.session === fresh)
            #expect(fresh.input == "half-typed follow up")
            #expect(fresh.unsentComposerText == "half-typed follow up")
        }
    }

    /// Switching to an agent that already has a tab drops the blank tab
    /// left behind; the text typed into that blank tab must survive.
    @Test("a dropped blank tab stashes its draft")
    func droppedBlankTabKeepsDraft() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let agentB = makeAgent("B")
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            let aSession = window.session
            aSession.turns.append(ChatTurn(role: .user, content: "hello A"))

            // A has content -> B opens in a fresh blank tab.
            window.switchAgent(to: agentB.id)
            let bSession = window.session
            #expect(bSession !== aSession)
            bSession.noteComposerDraft("half a question for B")

            // Back to A: focuses A's tab and drops B's blank one.
            window.switchAgent(to: Agent.defaultId)
            #expect(window.session === aSession)
            #expect(window.tabs.count == 1)

            // B has no tab any more; A has content -> B gets a new tab
            // that restores the dropped draft.
            window.switchAgent(to: agentB.id)
            #expect(window.session.agentId == agentB.id)
            #expect(window.session.input == "half a question for B")
        }
    }
}

extension ChatDraftPersistenceTests {
    /// The composer keeps keystrokes local and only writes `input` on
    /// send, so the session sees the unsent text through `composerDraft`.
    /// That mirror alone must be enough to bring the draft back.
    @Test("draft mirrored from the composer survives switching chats")
    func composerMirrorSurvivesLoadRoundTrip() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let first = ChatSessionData(id: UUID(), title: "First")
            let second = ChatSessionData(id: UUID(), title: "Second")

            let session = ChatSession()
            session.load(from: first)
            session.noteComposerDraft("draft one")
            #expect(session.input == "")

            session.load(from: second)
            #expect(session.input == "")
            #expect(session.composerDraft == "")

            session.load(from: first)
            #expect(session.input == "draft one")
            #expect(session.composerDraft == "draft one")
        }
    }
}

extension ChatDraftPersistenceTests {
    /// Switching tabs never reloads or resets the outgoing session, so the
    /// draft only lives in the mirror; promoting it into `input` is what
    /// the remounted composer rehydrates from.
    @Test("promoteComposerDraft surfaces the mirror and keeps untyped input")
    func promoteComposerDraft() {
        let session = ChatSession()
        session.noteComposerDraft("typed in tab")
        session.promoteComposerDraft()
        #expect(session.input == "typed in tab")

        // Input set programmatically with no keystroke since stays put.
        let other = ChatSession()
        other.input = "quick action"
        other.promoteComposerDraft()
        #expect(other.input == "quick action")
    }

    /// After a restore `input` holds the old draft while further keystrokes
    /// only reach the mirror. The mirror must win on the next stash,
    /// promote, or hibernate, including when the user deleted everything.
    @Test("edits after a restore replace the restored draft")
    func editsAfterRestoreWin() async throws {
        try await ChatHistoryTestStorage.run {
            ChatDraftStore.shared.removeAll()
            let first = ChatSessionData(id: UUID(), title: "First")
            let second = ChatSessionData(id: UUID(), title: "Second")

            let session = ChatSession()
            session.load(from: first)
            session.noteComposerDraft("v1")
            session.load(from: second)
            session.load(from: first)
            #expect(session.input == "v1")

            // User keeps typing; only the mirror sees it.
            session.noteComposerDraft("v1 plus more")
            #expect(session.unsentComposerText == "v1 plus more")
            session.promoteComposerDraft()
            #expect(session.input == "v1 plus more")

            session.load(from: second)
            session.load(from: first)
            #expect(session.input == "v1 plus more")

            // User deletes the whole draft, then leaves and returns.
            session.noteComposerDraft("")
            #expect(session.unsentComposerText == "")
            session.promoteComposerDraft()
            #expect(session.input == "")
            session.load(from: second)
            session.load(from: first)
            #expect(session.input == "")
        }
    }
}
