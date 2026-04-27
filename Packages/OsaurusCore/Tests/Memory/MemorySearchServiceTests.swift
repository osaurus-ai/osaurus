//
//  MemorySearchServiceTests.swift
//  osaurus
//
//  Tests for MemorySearchService: graceful degradation when VecturaKit is
//  uninitialized, topK guards, and MMR edge cases.
//

import Foundation
import Testing

@testable import OsaurusCore

struct MemorySearchServiceTests {

    // MARK: - Uninitialized behavior

    @Test func searchPinnedFactsReturnsEmptyWhenUninitialized() async {
        let results = await MemorySearchService.shared.searchPinnedFacts(query: "test")
        #expect(results.isEmpty)
    }

    @Test func searchEpisodesReturnsEmptyWhenUninitialized() async {
        let results = await MemorySearchService.shared.searchEpisodes(query: "test")
        #expect(results.isEmpty)
    }

    @Test func searchTranscriptReturnsEmptyWhenUninitialized() async {
        let results = await MemorySearchService.shared.searchTranscript(query: "test")
        #expect(results.isEmpty)
    }

    // MARK: - topK: 0 guard

    @Test func searchPinnedFactsWithTopKZeroReturnsEmpty() async {
        let results = await MemorySearchService.shared.searchPinnedFacts(query: "x", topK: 0)
        #expect(results.isEmpty)
    }

    @Test func searchEpisodesWithTopKZeroReturnsEmpty() async {
        let results = await MemorySearchService.shared.searchEpisodes(query: "x", topK: 0)
        #expect(results.isEmpty)
    }

    @Test func searchTranscriptWithTopKZeroReturnsEmpty() async {
        let results = await MemorySearchService.shared.searchTranscript(query: "x", topK: 0)
        #expect(results.isEmpty)
    }

    // MARK: - No-crash operations when uninitialized

    @Test func indexTranscriptTurnDoesNotCrashWhenUninitialized() async {
        let turn = TranscriptTurn(
            conversationId: "c",
            chunkIndex: 0,
            role: "user",
            content: "x",
            tokenCount: 1
        )
        await MemorySearchService.shared.indexTranscriptTurn(turn)
    }

    @Test func indexEpisodeDoesNotCrashWhenUninitialized() async {
        let ep = Episode(
            agentId: "a",
            conversationId: "c",
            summary: "x",
            conversationAt: "2025-01-01T00:00:00Z"
        )
        await MemorySearchService.shared.indexEpisode(ep)
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
        let reranked = MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 5)
        #expect(reranked.isEmpty)
    }

    @Test func mmrRerankWithSingleElementReturnsThatElement() async {
        let results = [(item: "only", score: 0.9, content: "only item")]
        let reranked = MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 5)
        #expect(reranked.count == 1)
        #expect(reranked[0] == "only")
    }

    @Test func mmrRerankRespectsTopKLimit() async {
        let results = (0 ..< 10).map { i in
            (item: "item-\(i)", score: Double(10 - i) / 10.0, content: "content \(i)")
        }
        let reranked = MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 3)
        #expect(reranked.count == 3)
    }

    @Test func mmrRerankWithIdenticalScoresReturnsAll() async {
        let results = (0 ..< 4).map { i in
            (item: "item-\(i)", score: 0.5, content: "unique content \(i)")
        }
        let reranked = MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 10)
        #expect(reranked.count == 4)
    }

    @Test func mmrRerankWithZeroScoreRange() async {
        let results = [
            (item: "a", score: 0.7, content: "alpha"),
            (item: "b", score: 0.7, content: "beta"),
            (item: "c", score: 0.7, content: "gamma"),
        ]
        let reranked = MemorySearchService.shared.mmrRerank(results: results, lambda: 0.85, topK: 3)
        #expect(reranked.count == 3)
    }
}
