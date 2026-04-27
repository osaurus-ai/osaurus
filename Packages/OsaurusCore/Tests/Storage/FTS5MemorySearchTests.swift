//
//  FTS5MemorySearchTests.swift
//  osaurusTests
//
//  Confirms the v6 FTS5 indexes return relevant rows for memory
//  text searches and that the FTS query sanitizer doesn't pass
//  raw SQL operators through.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FTS5MemorySearchTests {

    private func openInMemory() throws -> MemoryDatabase {
        let db = MemoryDatabase()
        try db.openInMemory()
        return db
    }

    @Test
    func transcriptSearchFindsKeywordsViaFTS() throws {
        let db = try openInMemory()
        defer { db.close() }

        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "c1",
            chunkIndex: 0,
            role: "user",
            content: "the quick brown fox jumps over the lazy dog",
            tokenCount: 10
        )
        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "c1",
            chunkIndex: 1,
            role: "assistant",
            content: "I do not see any cat here, only the brown fox",
            tokenCount: 12
        )

        let hits = try db.searchTranscriptText(query: "quick fox", agentId: "a", days: 365, limit: 5)
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.content.contains("quick brown fox") })
    }

    @Test
    func emptyQueryReturnsNoHits() throws {
        let db = try openInMemory()
        defer { db.close() }
        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "c1",
            chunkIndex: 0,
            role: "user",
            content: "anything at all",
            tokenCount: 3
        )

        let hits = try db.searchTranscriptText(query: "   ", agentId: "a", days: 365, limit: 5)
        #expect(hits.isEmpty)
    }

    @Test
    func querySanitizerStripsSQLOperators() {
        // Single-word queries get quoted; multi-word with operator-ish
        // characters should still produce safe quoted tokens.
        #expect(MemoryDatabase.ftsMatchQuery("foo AND bar OR baz") == "\"foo\" \"AND\" \"bar\" \"OR\" \"baz\"")
        #expect(MemoryDatabase.ftsMatchQuery("(rm -rf /)") == "\"rm\" \"-rf\"")
        #expect(MemoryDatabase.ftsMatchQuery("\u{0}\"NEAR\"") == "\"NEAR\"")
        #expect(MemoryDatabase.ftsMatchQuery("   ") == nil)
    }
}
