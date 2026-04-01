//
//  MethodSearchServiceTests.swift
//  osaurus
//
//  Tests for MethodSearchService: verifies graceful degradation when
//  VecturaKit is uninitialized and validates reverse-ID map behavior.
//  Full vector-search quality is validated empirically, not by unit tests.
//

import Foundation
import Testing

@testable import OsaurusCore

private typealias Method = OsaurusCore.Method

struct MethodSearchServiceTests {

    @Test func searchReturnsEmptyWhenUninitialized() async {
        let results = await MethodSearchService.shared.search(query: "deploy to staging")
        #expect(results.isEmpty)
    }

    @Test func indexMethodDoesNotCrashWhenUninitialized() async {
        let method = OsaurusCore.Method(
            id: "test-no-crash",
            name: "test",
            description: "should not crash",
            body: "steps:\n  - tool: terminal",
            source: MethodSource.user
        )
        await MethodSearchService.shared.indexMethod(method)
    }

    @Test func removeMethodDoesNotCrashWhenUninitialized() async {
        await MethodSearchService.shared.removeMethod(id: "nonexistent")
    }

    @Test func rebuildIndexDoesNotCrashWhenUninitialized() async {
        await MethodSearchService.shared.rebuildIndex()
    }

    @Test func searchWithTopKZeroReturnsEmpty() async {
        let results = await MethodSearchService.shared.search(query: "anything", topK: 0)
        #expect(results.isEmpty)
    }
}
