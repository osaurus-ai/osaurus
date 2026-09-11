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
