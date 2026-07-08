//
//  ChatContentSearchTests.swift
//  osaurusTests
//
//  Verifies the sidebar full-text search primitive: session-id lookup by
//  message-body substring over `turns.content`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChatContentSearchTests {

    private func openInMemory() throws -> ChatHistoryDatabase {
        let db = ChatHistoryDatabase()
        try db.openInMemory()
        return db
    }

    private func makeSession(title: String, contents: [String]) -> ChatSessionData {
        ChatSessionData(
            id: UUID(),
            title: title,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            selectedModel: "m",
            turns: contents.enumerated().map { index, content in
                ChatTurnData(role: index.isMultiple(of: 2) ? .user : .assistant, content: content)
            },
            agentId: nil,
            source: .chat,
            sourcePluginId: nil,
            externalSessionKey: nil,
            dispatchTaskId: nil
        )
    }

    @Test
    func findsSessionsByMessageBodySubstring() throws {
        let db = try openInMemory()
        defer { db.close() }

        let matching = makeSession(
            title: "Untitled",
            contents: ["how do I configure the notch overlay?", "You can adjust it in Settings."]
        )
        let other = makeSession(
            title: "Untitled",
            contents: ["what's the weather like?", "Sunny."]
        )
        try db.saveSession(matching)
        try db.saveSession(other)

        let ids = db.sessionIds(withContentContaining: "notch overlay")
        #expect(ids == [matching.id])
    }

    @Test
    func matchIsCaseInsensitive() throws {
        let db = try openInMemory()
        defer { db.close() }

        let session = makeSession(title: "T", contents: ["Deploy the Firecrawl plugin"])
        try db.saveSession(session)

        #expect(db.sessionIds(withContentContaining: "firecrawl") == [session.id])
        #expect(db.sessionIds(withContentContaining: "FIRECRAWL") == [session.id])
    }

    @Test
    func likeWildcardsInQueryAreLiteral() throws {
        let db = try openInMemory()
        defer { db.close() }

        let literal = makeSession(title: "T", contents: ["progress is at 100% done"])
        let decoy = makeSession(title: "T", contents: ["progress is at 100 percent done"])
        try db.saveSession(literal)
        try db.saveSession(decoy)

        // "%" must match only the literal percent sign, not act as a wildcard.
        #expect(db.sessionIds(withContentContaining: "100% done") == [literal.id])
        // "_" must not act as a single-character wildcard.
        #expect(db.sessionIds(withContentContaining: "100_done").isEmpty)
    }

    @Test
    func blankQueryReturnsNothing() throws {
        let db = try openInMemory()
        defer { db.close() }

        let session = makeSession(title: "T", contents: ["anything"])
        try db.saveSession(session)

        #expect(db.sessionIds(withContentContaining: "").isEmpty)
        #expect(db.sessionIds(withContentContaining: "   ").isEmpty)
    }

    @Test
    func sessionIsReportedOncePerMultipleMatchingTurns() throws {
        let db = try openInMemory()
        defer { db.close() }

        let session = makeSession(
            title: "T",
            contents: ["tell me about dinosaurs", "dinosaurs were reptiles", "more dinosaurs please"]
        )
        try db.saveSession(session)

        #expect(db.sessionIds(withContentContaining: "dinosaurs") == [session.id])
    }
}
