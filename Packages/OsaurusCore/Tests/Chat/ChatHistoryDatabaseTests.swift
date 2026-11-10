//
//  ChatHistoryDatabaseTests.swift
//  osaurusTests
//
//  The pre-sync chat-history database as the importer reads it: rows written
//  the way older builds wrote them decode with every field, metadata lists
//  most recent first, and deleting a chat removes its turns and legacy
//  sandbox rows.
//

import Foundation
import OsaurusSQLCipher
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
    func loadSession_decodesEveryField() throws {
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
        let artifacts = [
            SharedArtifact(
                contextId: session.id.uuidString,
                contextType: .chat,
                filename: "generated-image.png",
                mimeType: "image/png",
                fileSize: 123,
                hostPath: "/tmp/generated-image.png",
                description: "Generated image"
            )
        ]
        session.turns[1].terminalStopReason = "length"
        session.turns[1].modelContextExcluded = true
        session.turns[1].sharedArtifacts = artifacts
        try db.seedForTesting(session)

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
        #expect(loaded?.turns[1].modelContextExcluded == true)
        #expect(loaded?.turns[1].sharedArtifacts == artifacts)
        #expect(loaded?.turns[2].content == "turn 2")
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
        try db.seedForTesting(older)
        try db.seedForTesting(newer)

        let metadata = db.loadAllMetadata()
        #expect(metadata.count == 2)
        #expect(metadata[0].title == "newer")
        #expect(metadata[1].title == "older")
        #expect(metadata.allSatisfy { $0.turns.isEmpty })
    }

    @Test
    func deleteSession_cascadesToTurns() throws {
        let db = try openInMemory()
        let session = makeSession(turnCount: 3)
        try db.seedForTesting(session)
        #expect(db.loadSession(id: session.id)?.turns.count == 3)

        try db.deleteSession(id: session.id)
        #expect(db.loadSession(id: session.id) == nil)
        try db.queueRunForTest { connection in
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(connection, "SELECT COUNT(*) FROM turns", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            sqlite3_step(stmt)
            #expect(sqlite3_column_int(stmt, 0) == 0)
        }
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
        try db.seedSandboxChangeForTesting(change)

        let loaded = db.loadSandboxChanges(sessionId: sessionId)
        #expect(loaded.count == 1)
        #expect(loaded.first == change)
        #expect(db.sandboxChangeSessionIds() == [sessionId])
    }

    @Test
    func sandboxChanges_deleteBySession() throws {
        let db = try openInMemory()
        let sessionId = UUID().uuidString
        try db.seedSandboxChangeForTesting(makeSandboxChange(sessionId: sessionId, relativePath: "a.txt"))
        try db.seedSandboxChangeForTesting(makeSandboxChange(sessionId: sessionId, relativePath: "b.txt"))
        #expect(db.loadSandboxChanges(sessionId: sessionId).count == 2)

        try db.deleteSandboxChanges(sessionId: sessionId)
        #expect(db.loadSandboxChanges(sessionId: sessionId).isEmpty)
    }

    @Test
    func deleteSession_cascadesToSandboxChanges() throws {
        let db = try openInMemory()
        let session = makeSession(turnCount: 1)
        try db.seedForTesting(session)
        try db.seedSandboxChangeForTesting(makeSandboxChange(sessionId: session.id.uuidString))
        let other = makeSession(turnCount: 0)
        try db.seedForTesting(other)
        try db.seedSandboxChangeForTesting(makeSandboxChange(sessionId: other.id.uuidString))

        try db.deleteSession(id: session.id)
        #expect(db.loadSandboxChanges(sessionId: session.id.uuidString).isEmpty)
        // Other sessions' rows are untouched.
        #expect(db.loadSandboxChanges(sessionId: other.id.uuidString).count == 1)
    }
}
