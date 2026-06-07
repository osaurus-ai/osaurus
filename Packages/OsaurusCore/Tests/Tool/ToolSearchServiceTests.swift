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

@Suite(.serialized)
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

    @Test @MainActor
    func capabilitySearchAcceptsGrantedBM25OnlyToolWhenEmbeddingIndexUnavailable() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tool-exposure-\(UUID().uuidString)",
                isDirectory: true
            )
            let previousOverride = ToolConfigurationStore.overrideDirectory
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { ToolConfigurationStore.overrideDirectory = previousOverride }

            let dbWasOpen = ToolDatabase.shared.isOpen
            if !dbWasOpen {
                try ToolDatabase.shared.openInMemory()
            }
            defer {
                try? ToolDatabase.shared.deleteEntry(id: SearchExposureFixtureTool.nameStatic)
                if !dbWasOpen {
                    ToolDatabase.shared.close()
                }
            }

            let fixture = SearchExposureFixtureTool()
            ToolRegistry.shared.registerPluginTool(fixture)
            ToolRegistry.shared.setEnabled(true, for: fixture.name)
            defer { ToolRegistry.shared.unregister(names: [fixture.name]) }

            await ToolIndexService.shared.onToolRegistered(
                name: fixture.name,
                description: fixture.description,
                runtime: .native,
                tokenCount: fixture.description.count / 4,
                parameters: fixture.parameters
            )

            let bm25 = try ToolDatabase.shared.searchBM25(
                query: "current headline web search",
                topK: 5
            )
            #expect(
                bm25.contains { $0.id == fixture.name },
                "Fixture must be present in the SQL/BM25 tool index before capability search runs"
            )

            let (hybrid, diagnostic) = await ToolSearchService.shared.searchHybridWithDiagnostic(
                query: "current headline web search",
                topK: 5,
                minFusedScore: CapabilitySearch.minimumFusedScore
            )

            #expect(hybrid.contains { $0.entry.name == fixture.name })
            #expect(diagnostic.requestedMinFusedScore == CapabilitySearch.minimumFusedScore)
            #expect(diagnostic.minFusedScore < diagnostic.requestedMinFusedScore)
            let fixtureHit = diagnostic.acceptedHits.first { $0.name == fixture.name }
            #expect(fixtureHit?.bm25Score != nil)
            #expect(fixtureHit?.embedScore == nil)

            let results = await CapabilitySearch.search(
                query: "current headline web search",
                topK: (methods: 0, tools: 5, skills: 0)
            )
            #expect(
                results.tools.contains { $0.entry.name == fixture.name },
                "capabilities_discover must expose an indexed, enabled tool even while the embedding index is unavailable"
            )
        }
    }

    @Test @MainActor
    func hybridSearchFallsBackToRegistryWhenToolDatabaseIsClosed() async throws {
        await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tool-registry-fallback-\(UUID().uuidString)",
                isDirectory: true
            )
            let previousOverride = ToolConfigurationStore.overrideDirectory
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { ToolConfigurationStore.overrideDirectory = previousOverride }

            ToolDatabase.shared.close()
            defer { ToolDatabase.shared.close() }

            let fixture = SearchExposureFixtureTool()
            ToolRegistry.shared.registerPluginTool(fixture)
            ToolRegistry.shared.setEnabled(true, for: fixture.name)
            defer { ToolRegistry.shared.unregister(names: [fixture.name]) }

            let (results, diagnostic) = await ToolSearchService.shared.searchHybridWithDiagnostic(
                query: "current headline web search",
                topK: 5,
                minFusedScore: CapabilitySearch.minimumFusedScore
            )

            #expect(results.contains { $0.entry.name == fixture.name })
            #expect(diagnostic.acceptedHits.contains { $0.name == fixture.name })
            #expect(diagnostic.acceptedHits.first { $0.name == fixture.name }?.bm25Score == nil)
            #expect(diagnostic.acceptedHits.first { $0.name == fixture.name }?.embedScore == nil)

            let capabilityResults = await CapabilitySearch.search(
                query: "current headline web search",
                topK: (methods: 0, tools: 5, skills: 0)
            )
            #expect(
                capabilityResults.tools.contains { $0.entry.name == fixture.name },
                "capabilities_discover must still expose live registered tools when encrypted ToolDatabase is closed"
            )

            let compactIndex = try? await ToolIndexService.shared.buildCompactIndex()
            #expect(compactIndex?.contains(fixture.name) == true)
            #expect(compactIndex?.contains(fixture.description) == true)
        }
    }
}

private struct SearchExposureFixtureTool: OsaurusTool {
    static let nameStatic = "lane_b_search_fixture"

    let name = Self.nameStatic
    let description = "Search the web for current headline news and online results"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Search query for current web results"),
            ])
        ]),
        "required": .array([.string("query")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        argumentsJSON
    }
}
