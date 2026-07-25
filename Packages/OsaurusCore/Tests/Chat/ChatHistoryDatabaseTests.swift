//
//  ChatHistoryDatabaseTests.swift
//  osaurusTests
//
//  Verifies the SQLite-backed chat history database: schema migration,
//  session + turn roundtrip, agent / source / external-key lookups,
//  and cascade delete.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChatHistoryDatabaseTests {

    // MARK: - Helpers

    private func openInMemory() throws -> ChatHistoryDatabase {
        let db = ChatHistoryDatabase()
        try db.openInMemory()
        return db
    }

    private func makeSession(
        id: UUID = UUID(),
        title: String = "Test",
        agentId: UUID? = nil,
        source: SessionSource = .chat,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil,
        dispatchTaskId: UUID? = nil,
        turnCount: Int = 0
    ) -> ChatSessionData {
        ChatSessionData(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            selectedModel: "test-model",
            turns: (0 ..< turnCount).map { i in
                ChatTurnData(role: i % 2 == 0 ? .user : .assistant, content: "turn \(i)")
            },
            agentId: agentId,
            source: source,
            sourcePluginId: sourcePluginId,
            externalSessionKey: externalSessionKey,
            dispatchTaskId: dispatchTaskId
        )
    }

    // MARK: - Tests

    @Test
    func saveAndLoadSession_roundtripsAllFields() throws {
        let db = try openInMemory()
        let agentId = UUID()
        var session = makeSession(
            agentId: agentId,
            source: .plugin,
            sourcePluginId: "com.example.telegram",
            externalSessionKey: "telegram-chat-42",
            dispatchTaskId: UUID(),
            turnCount: 3
        )
        session.turns[1].terminalStopReason = "length"
        try db.saveSession(session)

        let loaded = db.loadSession(id: session.id)
        #expect(loaded != nil)
        #expect(loaded?.id == session.id)
        #expect(loaded?.title == session.title)
        #expect(loaded?.selectedModel == "test-model")
        #expect(loaded?.agentId == agentId)
        #expect(loaded?.source == .plugin)
        #expect(loaded?.sourcePluginId == "com.example.telegram")
        #expect(loaded?.externalSessionKey == "telegram-chat-42")
        #expect(loaded?.dispatchTaskId == session.dispatchTaskId)
        #expect(loaded?.turns.count == 3)
        #expect(loaded?.turns[0].role == .user)
        #expect(loaded?.turns[0].content == "turn 0")
        #expect(loaded?.turns[1].role == .assistant)
        #expect(loaded?.turns[1].terminalStopReason == "length")
        #expect(loaded?.turns[2].content == "turn 2")
    }

    @Test
    func terminalStopReasonUpdateInvalidatesContentHash() throws {
        let db = try openInMemory()
        let id = UUID()
        var session = makeSession(id: id, turnCount: 2)
        try db.saveSession(session)

        session.turns[1].terminalStopReason = "length"
        try db.saveSession(session)

        #expect(db.loadSession(id: id)?.turns[1].terminalStopReason == "length")
    }

    @Test
    func saveSession_replacesTurnsOnReSave() throws {
        let db = try openInMemory()
        let id = UUID()
        try db.saveSession(makeSession(id: id, turnCount: 5))
        try db.saveSession(makeSession(id: id, turnCount: 2))

        let loaded = db.loadSession(id: id)
        #expect(loaded?.turns.count == 2)
    }

    @Test
    func appendTurn_growsTurnCountAndOrdersBySeq() throws {
        let db = try openInMemory()
        let session = makeSession(turnCount: 0)
        try db.saveSession(session)

        try db.appendTurn(sessionId: session.id, turn: ChatTurnData(role: .user, content: "first"))
        try db.appendTurn(sessionId: session.id, turn: ChatTurnData(role: .assistant, content: "second"))
        try db.appendTurn(sessionId: session.id, turn: ChatTurnData(role: .user, content: "third"))

        let loaded = db.loadSession(id: session.id)
        #expect(loaded?.turns.count == 3)
        #expect(loaded?.turns.map(\.content) == ["first", "second", "third"])
    }

    @Test
    func loadAllMetadata_sortsByUpdatedAtDescAndStripsTurns() throws {
        let db = try openInMemory()
        let older = ChatSessionData(
            id: UUID(),
            title: "older",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            turns: [ChatTurnData(role: .user, content: "ignored in metadata")]
        )
        let newer = ChatSessionData(
            id: UUID(),
            title: "newer",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        try db.saveSession(older)
        try db.saveSession(newer)

        let metadata = db.loadAllMetadata()
        #expect(metadata.count == 2)
        #expect(metadata[0].title == "newer")
        #expect(metadata[1].title == "older")
        #expect(metadata.allSatisfy { $0.turns.isEmpty })
    }

    @Test
    func loadMetadata_filtersByAgentAndSource() throws {
        let db = try openInMemory()
        let agentA = UUID()
        let agentB = UUID()
        try db.saveSession(makeSession(title: "a-chat", agentId: agentA, source: .chat))
        try db.saveSession(makeSession(title: "a-plugin", agentId: agentA, source: .plugin, sourcePluginId: "p1"))
        try db.saveSession(makeSession(title: "b-chat", agentId: agentB, source: .chat))
        try db.saveSession(makeSession(title: "b-http", agentId: agentB, source: .http))

        #expect(db.loadMetadata(forAgent: agentA, source: nil).count == 2)
        #expect(db.loadMetadata(forAgent: agentA, source: .plugin).count == 1)
        #expect(db.loadMetadata(forAgent: nil, source: .http).count == 1)
        #expect(db.loadMetadata(forAgent: agentB, source: .plugin).count == 0)
    }

    @Test
    func findSession_byPluginAndExternalKey_returnsMostRecentMatch() throws {
        let db = try openInMemory()
        let pluginId = "com.example.telegram"
        let key = "chat-99"

        let older = ChatSessionData(
            id: UUID(),
            title: "older",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            source: .plugin,
            sourcePluginId: pluginId,
            externalSessionKey: key
        )
        let newer = ChatSessionData(
            id: UUID(),
            title: "newer",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            source: .plugin,
            sourcePluginId: pluginId,
            externalSessionKey: key
        )
        try db.saveSession(older)
        try db.saveSession(newer)

        let hit = db.findSession(pluginId: pluginId, externalKey: key, agentId: nil)
        #expect(hit?.id == newer.id)

        // Different external key should miss.
        #expect(db.findSession(pluginId: pluginId, externalKey: "chat-other", agentId: nil) == nil)
    }

    @Test
    func findSession_bySourceAndExternalKey_returnsMostRecentMatch() throws {
        // Used by the HTTP / schedule / watcher reattach path where there's
        // no plugin id to scope by — only `source` + `external_session_key`.
        let db = try openInMemory()
        let key = "session-key-7"

        let httpOlder = ChatSessionData(
            id: UUID(),
            title: "older",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            source: .http,
            externalSessionKey: key
        )
        let httpNewer = ChatSessionData(
            id: UUID(),
            title: "newer",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            source: .http,
            externalSessionKey: key
        )
        // A plugin row with the same external key must NOT be returned when
        // looking up by source `.http` — sources are namespaced.
        let pluginCollision = ChatSessionData(
            id: UUID(),
            title: "plugin-collision",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_500),
            source: .plugin,
            sourcePluginId: "com.example",
            externalSessionKey: key
        )
        try db.saveSession(httpOlder)
        try db.saveSession(httpNewer)
        try db.saveSession(pluginCollision)

        let hit = db.findSession(source: .http, externalKey: key, agentId: nil)
        #expect(hit?.id == httpNewer.id)
        #expect(hit?.source == .http)

        // Wrong source returns nothing.
        #expect(db.findSession(source: .schedule, externalKey: key, agentId: nil) == nil)

        // Wrong external key returns nothing even with the right source.
        #expect(db.findSession(source: .http, externalKey: "other", agentId: nil) == nil)
    }

    @Test
    func findSession_bySourceAndExternalKey_respectsAgentScope() throws {
        let db = try openInMemory()
        let agentA = UUID()
        let agentB = UUID()
        let key = "k"

        try db.saveSession(makeSession(id: UUID(), agentId: agentA, source: .schedule, externalSessionKey: key))
        try db.saveSession(makeSession(id: UUID(), agentId: agentB, source: .schedule, externalSessionKey: key))

        #expect(db.findSession(source: .schedule, externalKey: key, agentId: agentA)?.agentId == agentA)
        #expect(db.findSession(source: .schedule, externalKey: key, agentId: agentB)?.agentId == agentB)
        // nil agent scope only matches rows where agent_id IS NULL.
        #expect(db.findSession(source: .schedule, externalKey: key, agentId: nil) == nil)
    }

    @Test
    func deleteSession_cascadesToTurns() throws {
        let db = try openInMemory()
        let session = makeSession(turnCount: 3)
        try db.saveSession(session)
        #expect(db.loadSession(id: session.id)?.turns.count == 3)

        try db.deleteSession(id: session.id)
        #expect(db.loadSession(id: session.id) == nil)

        // Re-saving with the same id should start with no turns from the cascade.
        try db.saveSession(makeSession(id: session.id, turnCount: 0))
        #expect(db.loadSession(id: session.id)?.turns.count == 0)
    }

    // MARK: - Sandbox changes (v9)

    private func makeSandboxChange(
        sessionId: String,
        relativePath: String = "notes/todo.md",
        kind: SandboxChangeKind = .modified
    ) -> SandboxWorkspaceChange {
        SandboxWorkspaceChange(
            sessionId: sessionId,
            agentName: "tester",
            root: .agentHome,
            relativePath: relativePath,
            entryType: .file,
            kind: kind,
            state: .pending,
            baselineSignature: "sha256:aaaa",
            currentSignature: "sha256:bbbb",
            sourceTool: "sandbox_write_file",
            firstChangedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastChangedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    @Test
    func sandboxChanges_roundtripAllFields() throws {
        let db = try openInMemory()
        let sessionId = UUID().uuidString
        let change = makeSandboxChange(sessionId: sessionId)
        try db.upsertSandboxChange(change)

        let loaded = db.loadSandboxChanges(sessionId: sessionId)
        #expect(loaded.count == 1)
        #expect(loaded.first == change)
    }

    @Test
    func sandboxChanges_upsertCoalescesByPathKey() throws {
        let db = try openInMemory()
        let sessionId = UUID().uuidString
        try db.upsertSandboxChange(makeSandboxChange(sessionId: sessionId))

        // Same (session, agent, root, path) with a NEW row id must replace,
        // not duplicate — the unique path key wins over the id.
        var replacement = makeSandboxChange(sessionId: sessionId, kind: .deleted)
        replacement.currentSignature = nil
        try db.upsertSandboxChange(replacement)

        let loaded = db.loadSandboxChanges(sessionId: sessionId)
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == replacement.id)
        #expect(loaded.first?.kind == .deleted)
        #expect(loaded.first?.currentSignature == nil)
    }

    @Test
    func sandboxChanges_deleteByIdAndBySession() throws {
        let db = try openInMemory()
        let sessionId = UUID().uuidString
        let a = makeSandboxChange(sessionId: sessionId, relativePath: "a.txt")
        let b = makeSandboxChange(sessionId: sessionId, relativePath: "b.txt")
        try db.upsertSandboxChange(a)
        try db.upsertSandboxChange(b)

        try db.deleteSandboxChange(id: a.id)
        #expect(db.loadSandboxChanges(sessionId: sessionId).map(\.relativePath) == ["b.txt"])

        try db.deleteSandboxChanges(sessionId: sessionId)
        #expect(db.loadSandboxChanges(sessionId: sessionId).isEmpty)
    }

    @Test
    func deleteSession_cascadesToSandboxChanges() throws {
        let db = try openInMemory()
        let session = makeSession(turnCount: 1)
        try db.saveSession(session)
        try db.upsertSandboxChange(makeSandboxChange(sessionId: session.id.uuidString))
        let other = makeSession(turnCount: 0)
        try db.saveSession(other)
        try db.upsertSandboxChange(makeSandboxChange(sessionId: other.id.uuidString))

        try db.deleteSession(id: session.id)
        #expect(db.loadSandboxChanges(sessionId: session.id.uuidString).isEmpty)
        // Other sessions' rows are untouched.
        #expect(db.loadSandboxChanges(sessionId: other.id.uuidString).count == 1)
    }
}
