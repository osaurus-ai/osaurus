//
//  MemorySearchServiceTests.swift
//  osaurus
//
//  Tests for MemorySearchService: verifies graceful degradation when
//  VecturaKit is uninitialized and validates topK guards + MMR edge cases.
//

import Foundation
import Testing

@testable import OsaurusCore

struct MemorySearchServiceTests {

    // MARK: - Uninitialized behavior

    @Test func searchMemoryEntriesReturnsEmptyWhenUninitialized() async {
        let results = await MemorySearchService.shared.searchMemoryEntries(query: "test query")
        #expect(results.isEmpty)
    }

    @Test func searchConversationsReturnsEmptyWhenUninitialized() async {
        let results = await MemorySearchService.shared.searchConversations(query: "test query")
        #expect(results.isEmpty)
    }

    @Test func searchSummariesReturnsEmptyWhenUninitialized() async {
        let results = await MemorySearchService.shared.searchSummaries(query: "test query")
        #expect(results.isEmpty)
    }

    @Test func searchMemoryEntriesWithScoresReturnsEmptyWhenUninitialized() async {
        let results = await MemorySearchService.shared.searchMemoryEntriesWithScores(query: "test query")
        #expect(results.isEmpty)
    }

    // MARK: - topK: 0 guard

    @Test func searchMemoryEntriesWithTopKZeroReturnsEmpty() async {
        let results = await MemorySearchService.shared.searchMemoryEntries(query: "anything", topK: 0)
        #expect(results.isEmpty)
    }

    @Test func searchConversationsWithTopKZeroReturnsEmpty() async {
        let results = await MemorySearchService.shared.searchConversations(query: "anything", topK: 0)
        #expect(results.isEmpty)
    }

    @Test func searchSummariesWithTopKZeroReturnsEmpty() async {
        let results = await MemorySearchService.shared.searchSummaries(query: "anything", topK: 0)
        #expect(results.isEmpty)
    }

    @Test func searchWithScoresTopKZeroReturnsEmpty() async {
        let results = await MemorySearchService.shared.searchMemoryEntriesWithScores(query: "anything", topK: 0)
        #expect(results.isEmpty)
    }

    // MARK: - No-crash operations when uninitialized

    @Test func indexConversationChunkDoesNotCrashWhenUninitialized() async {
        let chunk = ConversationChunk(
            conversationId: "conv-1",
            chunkIndex: 0,
            role: "user",
            content: "test content",
            tokenCount: 4
        )
        await MemorySearchService.shared.indexConversationChunk(chunk)
    }

    @Test func rebuildIndexDoesNotCrashWhenUninitialized() async {
        await MemorySearchService.shared.rebuildIndex()
    }

    @Test func isVecturaAvailableReturnsFalseWhenUninitialized() async {
        let available = await MemorySearchService.shared.isVecturaAvailable
        #expect(!available)
    }

    // MARK: - MMR Reranking

    @Test func mmrRerankWithEmptyArrayReturnsEmpty() async {
        let results: [(item: String, score: Double, content: String)] = []
        let reranked = await MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 5)
        #expect(reranked.isEmpty)
    }

    @Test func mmrRerankWithSingleElementReturnsThatElement() async {
        let results = [(item: "only", score: 0.9, content: "only item")]
        let reranked = await MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 5)
        #expect(reranked.count == 1)
        #expect(reranked[0] == "only")
    }

    @Test func mmrRerankRespectsTopKLimit() async {
        let results = (0 ..< 10).map { i in
            (item: "item-\(i)", score: Double(10 - i) / 10.0, content: "content \(i)")
        }
        let reranked = await MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 3)
        #expect(reranked.count == 3)
    }

    @Test func mmrRerankWithIdenticalScoresReturnsAll() async {
        let results = (0 ..< 4).map { i in
            (item: "item-\(i)", score: 0.5, content: "unique content \(i)")
        }
        let reranked = await MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 10)
        #expect(reranked.count == 4)
    }

    @Test func mmrRerankWithZeroScoreRange() async {
        let results = [
            (item: "a", score: 0.7, content: "alpha"),
            (item: "b", score: 0.7, content: "beta"),
            (item: "c", score: 0.7, content: "gamma"),
        ]
        let reranked = await MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 3)
        #expect(reranked.count == 3)
    }
}
