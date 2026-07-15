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
    func transcriptSearchFallsBackToLooseNaturalRecallTerms() throws {
        let db = try openInMemory()
        defer { db.close() }

        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "c1",
            chunkIndex: 0,
            role: "user",
            content: "Memory fixture exact words: sapphire-memory-8842",
            tokenCount: 8
        )
        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "c2",
            chunkIndex: 0,
            role: "user",
            content: "unrelated deployment note",
            tokenCount: 4
        )

        let hits = try db.searchTranscriptText(
            query: "What exact words did I type for the memory fixture? Reply only the sapphire-memory codeword.",
            agentId: "a",
            days: 365,
            limit: 5
        )

        #expect(hits.first?.content == "Memory fixture exact words: sapphire-memory-8842")
    }

    @Test
    func pinnedFactSearchFallsBackToLooseNaturalRecallTerms() throws {
        let db = try openInMemory()
        defer { db.close() }

        let now = ISO8601DateFormatter().string(from: Date())
        try db.insertPinnedFact(
            PinnedFact(
                agentId: "a",
                content: "The user's sailboat is named Peregrine Dusk.",
                salience: 0.9,
                lastUsed: now,
                createdAt: now
            )
        )
        try db.insertPinnedFact(
            PinnedFact(
                agentId: "a",
                content: "The user has a dermatology appointment on the 14th.",
                salience: 0.9,
                lastUsed: now,
                createdAt: now
            )
        )

        // Full natural-language question: the FTS AND-match finds nothing,
        // so the loose-term pass must surface the boat fact (and only it).
        let hits = try db.searchPinnedFactsText(
            query: "What is the name of my boat?",
            agentId: "a",
            limit: 5
        )
        #expect(hits.count == 1)
        #expect(hits.first?.content.contains("Peregrine Dusk") == true)
    }

    @Test
    func episodeSearchFallsBackToLooseNaturalRecallTerms() throws {
        let db = try openInMemory()
        defer { db.close() }

        let now = ISO8601DateFormatter().string(from: Date())
        _ = try db.insertEpisode(
            Episode(
                agentId: "a",
                conversationId: "c1",
                summary: "Discussed the greenhouse project: cedar frame, $900 budget.",
                topicsCSV: "greenhouse,woodworking",
                entitiesCSV: "greenhouse,cedar",
                salience: 0.9,
                conversationAt: now
            )
        )
        _ = try db.insertEpisode(
            Episode(
                agentId: "a",
                conversationId: "c2",
                summary: "Talked about tax filing deadlines.",
                topicsCSV: "taxes",
                entitiesCSV: "taxes",
                salience: 0.9,
                conversationAt: now
            )
        )

        let hits = try db.searchEpisodesText(
            query: "What did we decide about the greenhouse project last time we talked?",
            agentId: "a",
            limit: 5
        )
        #expect(hits.first?.summary.contains("greenhouse") == true)
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
