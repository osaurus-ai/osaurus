//
//  SyncLegacyImporterTests.swift
//  OsaurusCoreTests
//
//  The pre-sync chat history copied into the sync store: once, resumably,
//  without bringing back a chat deleted since, rebuilding chats whose turn
//  rows are gone from their Memory transcript, and leaving the old
//  database as it was.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncLegacyImporterTests {
    private func withLegacy(_ body: @MainActor @Sendable (ChatHistoryDatabase, SyncConversationStore) async throws -> Void)
        async throws
    {
        try await ChatHistoryTestStorage.run {
            _ = try SyncService.shared.open()
            let legacy = ChatHistoryDatabase()
            try legacy.openInMemory()
            defer { legacy.close() }
            try await body(legacy, SyncConversationStore.shared)
        }
    }

    private func openMemory() throws -> MemoryDatabase {
        let memory = MemoryDatabase()
        try memory.openInMemory()
        return memory
    }

    private func transcript(_ memory: MemoryDatabase, _ sessionId: UUID, _ turns: [(role: String, content: String, at: String)])
        throws
    {
        for (index, turn) in turns.enumerated() {
            try memory.insertTranscriptTurn(
                agentId: Agent.defaultId.uuidString,
                conversationId: sessionId.uuidString,
                chunkIndex: index,
                role: turn.role,
                content: turn.content,
                tokenCount: 4,
                createdAt: turn.at
            )
        }
    }

    private func session(_ title: String, source: SessionSource = .chat, turns: Int = 2, daysAgo: Double) -> ChatSessionData {
        let created = Date(timeIntervalSince1970: 1_767_225_600 - daysAgo * 86_400)
        return ChatSessionData(
            id: UUID(),
            title: title,
            createdAt: created,
            updatedAt: created.addingTimeInterval(60),
            turns: (0..<turns).map { index in
                ChatTurnData(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "\(title) \(index)",
                    createdAt: created.addingTimeInterval(Double(index))
                )
            },
            source: source
        )
    }

    @Test
    func importsEveryConversationOnceAndLeavesTheOldDatabaseAlone() async throws {
        try await withLegacy { legacy, store in
            let chat = session("Trip", daysAgo: 1)
            let api = session("API run", source: .http, daysAgo: 2)
            let empty = session("Blank", turns: 0, daysAgo: 3)
            for item in [chat, api, empty] { try legacy.seedForTesting(item) }

            let outcome = await SyncLegacyImporter.importAll(legacy: legacy, store: store, memory: MemoryDatabase())
            #expect(outcome == .init(imported: 2, failed: 0))
            #expect(store.loadSession(id: chat.id)?.turns.map(\.content) == ["Trip 0", "Trip 1"])
            #expect(store.loadSession(id: chat.id)?.createdAt == chat.createdAt)
            #expect(store.loadSession(id: api.id)?.source == .http)
            let core = try #require(SyncService.shared.core)
            let apiScope = try #require(store.scope(forSession: api.id))
            #expect(try core.conversation(scope: apiScope)?.replication == .deviceLocal)
            #expect(store.loadSession(id: empty.id) == nil)
            #expect(legacy.loadAllMetadata().count == 3)
            #expect(SyncLegacyImporter.Ledger.load().done)

            let again = await SyncLegacyImporter.importAll(legacy: legacy, store: store, memory: MemoryDatabase())
            #expect(again == .init(imported: 0, failed: 0))
            #expect(store.loadAllMetadata().count == 2)
        }
    }

    @Test
    func importedChatsKeepTheirTimesAndOrder() async throws {
        try await withLegacy { legacy, store in
            let chats = [session("Old", daysAgo: 30), session("Newest", daysAgo: 1), session("Middle", daysAgo: 7)]
            for item in chats { try legacy.seedForTesting(item) }

            let outcome = await SyncLegacyImporter.importAll(legacy: legacy, store: store, memory: MemoryDatabase())
            #expect(outcome == .init(imported: 3, failed: 0))
            store.invalidateCaches()
            let imported = store.loadAllMetadata()
            #expect(imported.map(\.title) == ["Newest", "Middle", "Old"])
            for chat in chats {
                let updated = try #require(imported.first { $0.id == chat.id }?.updatedAt)
                #expect(abs(updated.timeIntervalSince(chat.updatedAt)) < 0.001, "\(chat.title)")
            }
        }
    }

    @Test
    func aResumedImportSkipsWhatItDidAndWhatWasDeletedSince() async throws {
        try await withLegacy { legacy, store in
            let first = session("First", daysAgo: 1)
            let second = session("Second", daysAgo: 2)
            for item in [first, second] { try legacy.seedForTesting(item) }

            // An earlier launch imported `first`, then the user deleted it.
            var ledger = SyncLegacyImporter.Ledger()
            ledger.imported = [first.id]
            ledger.save()

            let outcome = await SyncLegacyImporter.importAll(legacy: legacy, store: store, memory: MemoryDatabase())
            #expect(outcome == .init(imported: 1, failed: 0))
            #expect(store.loadSession(id: first.id) == nil)
            #expect(store.loadSession(id: second.id) != nil)
        }
    }

    @Test
    func anImportInterruptedBeforeItsLedgerWriteDoesNotDuplicate() async throws {
        try await withLegacy { legacy, store in
            let chat = session("Trip", daysAgo: 1)
            try legacy.seedForTesting(chat)
            try store.saveSession(chat)

            let outcome = await SyncLegacyImporter.importAll(legacy: legacy, store: store, memory: MemoryDatabase())
            #expect(outcome == .init(imported: 0, failed: 0))
            #expect(store.loadAllMetadata().count == 1)
        }
    }

    @Test
    func aChatWithoutTurnRowsIsImportedFromItsMemoryTranscript() async throws {
        try await withLegacy { legacy, store in
            let orphan = session("Orphan", turns: 0, daysAgo: 1)
            try legacy.seedForTesting(orphan)
            let memory = try openMemory()
            defer { memory.close() }
            try transcript(
                memory, orphan.id,
                [
                    ("user", "Can you recover this?", "2026-06-28T12:00:00.123Z"),
                    ("assistant", "Yes, from the transcript.", "2026-06-28 12:00:05"),
                ])

            let outcome = await SyncLegacyImporter.importAll(legacy: legacy, store: store, memory: memory)
            #expect(outcome == .init(imported: 1, failed: 0))
            let imported = try #require(store.loadSession(id: orphan.id))
            #expect(imported.turns.map(\.role) == [.user, .assistant])
            #expect(imported.turns.map(\.content) == ["Can you recover this?", "Yes, from the transcript."])
            #expect(imported.turns.allSatisfy { $0.createdAt != nil })
            #expect(legacy.loadSession(id: orphan.id)?.turns.isEmpty == true)
        }
    }

    @Test
    func savedTurnsWinOverTheTranscriptAndBlankOrUnknownTranscriptTurnsAreDropped() async throws {
        try await withLegacy { legacy, store in
            let chat = session("Kept", turns: 1, daysAgo: 1)
            let blank = session("Blank", turns: 0, daysAgo: 2)
            for item in [chat, blank] { try legacy.seedForTesting(item) }
            let memory = try openMemory()
            defer { memory.close() }
            try transcript(memory, chat.id, [("user", "transcript should not replace this", "")])
            try transcript(memory, blank.id, [("developer", "unsupported role", ""), ("assistant", "   ", "")])

            let outcome = await SyncLegacyImporter.importAll(legacy: legacy, store: store, memory: memory)
            #expect(outcome == .init(imported: 1, failed: 0))
            #expect(store.loadSession(id: chat.id)?.turns.map(\.content) == ["Kept 0"])
            #expect(store.loadSession(id: blank.id) == nil)
            #expect(SyncLegacyImporter.Ledger.load().isFinished)
        }
    }

    @Test
    func aFinishedFirstVersionLedgerRechecksOnlyTheChatsItSkippedAsEmpty() async throws {
        try await withLegacy { legacy, store in
            let deleted = session("Deleted since", daysAgo: 1)
            let orphan = session("Orphan", turns: 0, daysAgo: 2)
            for item in [deleted, orphan] { try legacy.seedForTesting(item) }
            let memory = try openMemory()
            defer { memory.close() }
            try transcript(memory, orphan.id, [("user", "still here", "")])

            let firstVersion = #"{"done":true,"imported":["\#(deleted.id.uuidString)","\#(orphan.id.uuidString)"]}"#
            try FileManager.default.createDirectory(at: OsaurusPaths.syncLocalState(), withIntermediateDirectories: true)
            try Data(firstVersion.utf8).write(to: SyncLegacyImporter.Ledger.url)
            #expect(!SyncLegacyImporter.Ledger.load().isFinished)

            let outcome = await SyncLegacyImporter.importAll(legacy: legacy, store: store, memory: memory)
            #expect(outcome == .init(imported: 1, failed: 0))
            #expect(store.loadSession(id: orphan.id)?.turns.map(\.content) == ["still here"])
            #expect(store.loadSession(id: deleted.id) == nil)
            let ledger = SyncLegacyImporter.Ledger.load()
            #expect(ledger.isFinished)
            #expect(ledger.version == SyncLegacyImporter.Ledger.currentVersion)
        }
    }
}
