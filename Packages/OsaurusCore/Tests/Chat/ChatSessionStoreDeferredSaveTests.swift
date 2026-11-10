//
//  ChatSessionStoreDeferredSaveTests.swift
//  osaurus
//
//  Regression coverage for #1737: turn writes that were deferred while the
//  conversation store was closed must be re-flushed, not dropped. Runs
//  against the real `SyncConversationStore`.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ChatSessionStoreDeferredSaveTests {
    private func withOpenStores(_ body: @MainActor @Sendable () throws -> Void) async throws {
        try await ChatHistoryTestStorage.run {
            try SyncConversationStore.shared.open()
            ChatSessionStore._markStorageOpenForTesting()
            defer { ChatSessionStore._resetForTesting() }
            try body()
        }
    }

    @Test func flushPersistsQueuedSavesToDatabase() async throws {
        try await withOpenStores {
            let session = ChatSessionData(
                id: UUID(),
                title: "Deferred chat",
                turns: [
                    ChatTurnData(role: .user, content: "queued question"),
                    ChatTurnData(role: .assistant, content: "queued answer"),
                ]
            )
            ChatSessionStore._enqueuePendingSaveForTesting(session)
            #expect(ChatSessionStore._pendingSaveCountForTesting == 1)

            ChatSessionStore.flushPendingSaves()

            #expect(ChatSessionStore._pendingSaveCountForTesting == 0)
            let loaded = SyncConversationStore.shared.loadSession(id: session.id)
            #expect(loaded?.turns.map(\.content) == ["queued question", "queued answer"])
        }
    }

    /// Storage-only control for the observed completed batch with only its
    /// initial user row on disk. This does not reproduce generation or prove
    /// that ChatSession actually enqueued its final snapshot in that run.
    @Test(arguments: [false, true])
    func completedSnapshotSupersedesInitialAsyncSave(flushPending: Bool) async throws {
        try await withOpenStores {
            let initial = ChatSessionData(
                id: UUID(),
                title: "Batch snapshot storage control",
                updatedAt: Date().addingTimeInterval(-600),
                turns: [ChatTurnData(role: .user, content: "Run two independent jobs")]
            )
            var completed = initial
            completed.updatedAt = initial.updatedAt.addingTimeInterval(120)
            completed.turns.append(contentsOf: [
                ChatTurnData(role: .assistant, content: "Starting both jobs"),
                ChatTurnData(role: .tool, content: String(repeating: "first result α\n", count: 1_024)),
                ChatTurnData(role: .tool, content: String(repeating: "second result β\n", count: 1_024)),
                ChatTurnData(role: .assistant, content: "First job completed; second job did not complete"),
            ])

            ChatSessionStore.saveAsync(initial)
            ChatSessionStore.saveAsync(completed)
            if flushPending { ChatSessionStore.flushPendingSaves() }

            // Read the database directly, not the pending in-memory overlay.
            // Its serial queue drains both writes before this read executes.
            let stored = try #require(SyncConversationStore.shared.loadSession(id: initial.id))
            #expect(stored.turns.map(\.id) == completed.turns.map(\.id))
            #expect(stored.turns.map(\.role) == completed.turns.map(\.role))
            #expect(stored.turns.map(\.content) == completed.turns.map(\.content))
            // The store reports the conversation's last activity, capped at now.
            #expect(stored.updatedAt.timeIntervalSince(completed.updatedAt) > -0.001)
        }
    }

    @Test func deleteDropsQueuedSaveForSession() async throws {
        try await withOpenStores {
            let session = ChatSessionData(
                id: UUID(),
                title: "Cancelled deferred chat",
                turns: [ChatTurnData(role: .user, content: "cancelled before review")]
            )
            ChatSessionStore._enqueuePendingSaveForTesting(session)
            #expect(ChatSessionStore._pendingSaveCountForTesting == 1)

            ChatSessionStore.delete(id: session.id)
            ChatSessionStore.flushPendingSaves()

            #expect(ChatSessionStore._pendingSaveCountForTesting == 0)
            #expect(SyncConversationStore.shared.loadSession(id: session.id) == nil)
        }
    }

    @Test func flushDeletesQueuedDeleteFromDatabase() async throws {
        try await withOpenStores {
            let session = ChatSessionData(
                id: UUID(),
                title: "Persisted before deferred delete",
                turns: [ChatTurnData(role: .user, content: "remove me later")]
            )
            try SyncConversationStore.shared.saveSession(session)
            ChatSessionStore._enqueuePendingDeleteForTesting(session.id)
            #expect(ChatSessionStore._pendingDeleteCountForTesting == 1)

            ChatSessionStore.flushPendingSaves()

            #expect(ChatSessionStore._pendingDeleteCountForTesting == 0)
            #expect(SyncConversationStore.shared.loadSession(id: session.id) == nil)
        }
    }

    @Test func pendingDeleteWinsOverQueuedSaveForSession() async throws {
        try await withOpenStores {
            let session = ChatSessionData(
                id: UUID(),
                title: "Cancelled deferred chat",
                turns: [ChatTurnData(role: .user, content: "do not restore")]
            )
            ChatSessionStore._enqueuePendingSaveForTesting(session)
            ChatSessionStore._enqueuePendingDeleteForTesting(session.id)

            ChatSessionStore.flushPendingSaves()

            #expect(ChatSessionStore._pendingSaveCountForTesting == 0)
            #expect(ChatSessionStore._pendingDeleteCountForTesting == 0)
            #expect(SyncConversationStore.shared.loadSession(id: session.id) == nil)
        }
    }

    @Test func pendingDeleteRejectsDeferredSaveWhileDatabaseClosed() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSessionData(
                id: UUID(),
                title: "Cancelled while closed",
                turns: [ChatTurnData(role: .user, content: "do not queue")]
            )
            ChatSessionStore._resetForTesting()
            defer { ChatSessionStore._resetForTesting() }

            ChatSessionStore._enqueuePendingDeleteForTesting(session.id)
            ChatSessionStore.save(session)

            #expect(ChatSessionStore._pendingSaveCountForTesting == 0)
            #expect(ChatSessionStore._pendingDeleteCountForTesting == 1)
        }
    }

    /// `saveAsync` keeps the session in the pending overlay until the DB
    /// acknowledges the write, and `load(id:)` serves that overlay first. A
    /// targeted metadata update issued while the save is still in flight must
    /// patch the overlay too, or the caller reads back the pre-rename snapshot
    /// (BackgroundTaskManager.renameTask on a dehydrated tab hit exactly this).
    @Test func targetedUpdatesPatchInFlightPendingSnapshot() async throws {
        try await withOpenStores {
            let projectId = UUID()
            let session = ChatSessionData(
                id: UUID(),
                title: "Durable Tabs",
                turns: [ChatTurnData(role: .user, content: "keep this conversation")],
                projectId: projectId
            )
            ChatSessionStore.saveAsync(session)
            // No main-actor hop has run yet, so the acknowledgement that clears
            // the overlay cannot have landed: this is the in-flight window.
            #expect(ChatSessionStore._hasPendingSaveForTesting(session.id))

            ChatSessionStore.renameTitleAsync(id: session.id, title: "Pinned Work")
            ChatSessionStore.setPinnedAsync(id: session.id, pinned: true)
            ChatSessionStore.setArchivedAsync(id: session.id, archived: true)
            ChatSessionStore.setProjectAsync(id: session.id, projectId: nil)

            let loaded = ChatSessionStore.load(id: session.id)
            #expect(loaded?.title == "Pinned Work")
            #expect(loaded?.pinned == true)
            #expect(loaded?.archived == true)
            #expect(loaded?.projectId == nil)
            // The overlay never stands in for the transcript.
            #expect(loaded?.turns.map(\.content) == ["keep this conversation"])
        }
    }

    @Test func clearProjectPatchesInFlightPendingSnapshots() async throws {
        try await withOpenStores {
            let projectId = UUID()
            let inProject = ChatSessionData(
                id: UUID(),
                title: "In project",
                turns: [],
                projectId: projectId
            )
            let elsewhere = ChatSessionData(
                id: UUID(),
                title: "Elsewhere",
                turns: [],
                projectId: UUID()
            )
            ChatSessionStore.saveAsync(inProject)
            ChatSessionStore.saveAsync(elsewhere)

            ChatSessionStore.clearProjectAsync(projectId: projectId)

            #expect(ChatSessionStore.load(id: inProject.id)?.projectId == nil)
            #expect(ChatSessionStore.load(id: elsewhere.id)?.projectId == elsewhere.projectId)
        }
    }

    /// #2736: `ensureOpen` used to set `didOpen = true` *before* `open()`,
    /// so a failed migration left Retry calling `saveSessionAsync` against
    /// a nil connection forever. A failed open must leave `didOpen` false;
    /// the next retry must reopen and commit the pending snapshot.
    @Test func failedOpenDoesNotStickDidOpenAndRetryCommits() async throws {
        try await ChatHistoryTestStorage.run {
            ChatSessionStore._resetForTesting()
            ChatSessionStore._forceNextOpenFailureForTesting = true

            let session = ChatSessionData(
                id: UUID(),
                title: "Unsaved after failed open",
                turns: [
                    ChatTurnData(role: .user, content: "keep me"),
                    ChatTurnData(role: .assistant, content: "and me"),
                ]
            )
            ChatSessionStore.saveAsync(session)

            #expect(ChatSessionStore._didOpenForTesting == false)
            #expect(ChatSessionStore._hasPendingSaveForTesting(session.id))
            #expect(ChatPersistenceStatus.shared.unsaved.contains(session.id))
            #expect(
                SyncConversationStore.shared.loadSession(id: session.id) == nil,
                "failed open must not leave a half-written row"
            )

            ChatSessionStore.retryUnsaved()

            #expect(ChatSessionStore._didOpenForTesting == true)
            let stored = try #require(SyncConversationStore.shared.loadSession(id: session.id))
            #expect(stored.turns.map(\.content) == ["keep me", "and me"])
        }
    }
}
