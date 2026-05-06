//
//  ToolSearchServiceTests.swift
//  osaurus
//
//  Tests for ToolSearchService: verifies graceful degradation when
//  VecturaKit is uninitialized. Full search quality is validated empirically.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolSearchServiceTests {

    @Test func searchReturnsEmptyWhenUninitialized() async {
        let results = await ToolSearchService.shared.search(query: "search github repos")
        #expect(results.isEmpty)
    }

    @Test func searchWithTopKZeroReturnsEmpty() async {
        let results = await ToolSearchService.shared.search(query: "anything", topK: 0)
        #expect(results.isEmpty)
    }

    @Test func indexEntryDoesNotCrashWhenUninitialized() async {
        let entry = ToolIndexEntry(
            id: "test-tool",
            name: "test-tool",
            description: "A test tool",
            runtime: .builtin,
            toolsJSON: "{}",
            source: .system,
            tokenCount: 50
        )
        await ToolSearchService.shared.indexEntry(entry)
    }

    @Test func removeEntryDoesNotCrashWhenUninitialized() async {
        await ToolSearchService.shared.removeEntry(id: "nonexistent")
    }

    @Test func rebuildIndexDoesNotCrashWhenUninitialized() async {
        await ToolSearchService.shared.rebuildIndex()
    }

    @Test func toolSearchResultCarriesScore() {
        let entry = ToolIndexEntry(
            id: "test-tool",
            name: "test-tool",
            description: "A test tool",
            runtime: .builtin,
            toolsJSON: "{}",
            source: .system,
            tokenCount: 50
        )
        let result = ToolSearchResult(entry: entry, searchScore: 0.72)
        #expect(result.searchScore == 0.72)
        #expect(result.entry.name == "test-tool")
    }

    /// Pins the documented BM25-degrade contract: when the FTS5
    /// sanitiser produces no usable tokens (e.g. an all-punctuation
    /// query), the diagnostic surfaces `bm25Available == false` AND
    /// the hybrid's accepted name set equals what the embedding-only
    /// `search()` returns at the same K. Two assertions, not one — the
    /// result-set check alone wouldn't prove BM25 actually opted out
    /// vs happened to converge with embed at the same names.
    @Test func hybridDegradesToEmbeddingWhenBM25Empty() async {
        // Pick a query the sanitiser rejects: only punctuation and
        // separators, zero alphanumerics. `sanitizeFTS5Query` must
        // return nil for this and `searchBM25` must short-circuit
        // to `[]`, both of which are exercised in
        // `ToolDatabaseTests.searchBM25EmptyQueryReturnsEmpty`.
        let query = "!@#$%^&*()"

        let (results, diagnostic) = await ToolSearchService.shared.searchHybridWithDiagnostic(
            query: query,
            topK: 5,
            minFusedScore: 0.0
        )
        let embedOnly = await ToolSearchService.shared.search(
            query: query,
            topK: 5,
            threshold: 0.0
        )

        // Contract 1: BM25 deliberately stayed silent.
        #expect(diagnostic.bm25Available == false)
        // No diagnostic Hit can carry BM25 data for a sanitiser-
        // rejected query — the only contributor was the embed side.
        for hit in diagnostic.acceptedHits {
            #expect(hit.bm25Rank == nil)
            #expect(hit.bm25Score == nil)
        }
        // Contract 2: result name set matches embed-only.
        #expect(Set(results.map(\.entry.name)) == Set(embedOnly.map(\.entry.name)))
    }
}
