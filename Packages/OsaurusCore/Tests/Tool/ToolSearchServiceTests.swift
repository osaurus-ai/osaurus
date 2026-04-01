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
}
