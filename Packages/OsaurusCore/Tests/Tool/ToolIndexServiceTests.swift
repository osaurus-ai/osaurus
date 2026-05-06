//
//  ToolIndexServiceTests.swift
//  osaurus
//
//  Unit tests for ToolDatabase (CRUD, upsert, runtime field) and
//  ToolIndexService's buildCompactIndex logic.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolDatabaseTests {

    private func makeTempDB() throws -> ToolDatabase {
        let db = ToolDatabase()
        try db.openInMemory()
        return db
    }

    private func sampleEntry(
        id: String = "test-tool",
        name: String = "test-tool",
        description: String = "A test tool",
        runtime: ToolRuntime = .builtin
    ) -> ToolIndexEntry {
        ToolIndexEntry(
            id: id,
            name: name,
            description: description,
            runtime: runtime,
            toolsJSON: "{}",
            source: .system,
            tokenCount: 50
        )
    }

    // MARK: - Insert and Query

    @Test func upsertAndLoadEntryRoundtrip() throws {
        let db = try makeTempDB()
        let entry = sampleEntry()
        try db.upsertEntry(entry)

        let loaded = try db.loadEntry(id: entry.id)
        #expect(loaded != nil)
        #expect(loaded?.id == entry.id)
        #expect(loaded?.name == entry.name)
        #expect(loaded?.description == entry.description)
        #expect(loaded?.runtime == .builtin)
        #expect(loaded?.tokenCount == 50)
    }

    @Test func upsertOverwritesExisting() throws {
        let db = try makeTempDB()
        try db.upsertEntry(sampleEntry(description: "Version 1"))
        try db.upsertEntry(sampleEntry(description: "Version 2"))

        let loaded = try db.loadEntry(id: "test-tool")
        #expect(loaded?.description == "Version 2")

        let count = try db.entryCount()
        #expect(count == 1)
    }

    @Test func deleteEntryRemovesFromDB() throws {
        let db = try makeTempDB()
        try db.upsertEntry(sampleEntry())
        #expect(try db.loadEntry(id: "test-tool") != nil)

        try db.deleteEntry(id: "test-tool")
        #expect(try db.loadEntry(id: "test-tool") == nil)
    }

    @Test func loadAllEntriesReturnsAll() throws {
        let db = try makeTempDB()
        try db.upsertEntry(sampleEntry(id: "a", name: "alpha"))
        try db.upsertEntry(sampleEntry(id: "b", name: "beta"))
        try db.upsertEntry(sampleEntry(id: "c", name: "gamma"))

        let all = try db.loadAllEntries()
        #expect(all.count == 3)
    }

    @Test func entryCountIsAccurate() throws {
        let db = try makeTempDB()
        #expect(try db.entryCount() == 0)

        try db.upsertEntry(sampleEntry(id: "a", name: "alpha"))
        try db.upsertEntry(sampleEntry(id: "b", name: "beta"))
        #expect(try db.entryCount() == 2)
    }

    // MARK: - FTS5 mirror

    @Test func fts5MirrorReflectsInsert() throws {
        let db = try makeTempDB()
        try db.upsertEntry(
            sampleEntry(
                id: "fts-ins",
                name: "kestrel",
                description: "Manage zorglax fields in the cluster"
            )
        )
        // Unique tokens so only this row matches.
        let kestrel = try db.searchBM25(query: "kestrel", topK: 10)
        #expect(kestrel.map(\.id) == ["fts-ins"])
        let zorglax = try db.searchBM25(query: "zorglax", topK: 10)
        #expect(zorglax.map(\.id) == ["fts-ins"])
    }

    @Test func fts5MirrorReflectsUpdate() throws {
        let db = try makeTempDB()
        try db.upsertEntry(
            sampleEntry(
                id: "fts-upd",
                name: "kestrel",
                description: "Manage zorglax fields"
            )
        )
        // Overwrite description: the old token should disappear from
        // the FTS5 mirror, the new token should appear.
        try db.upsertEntry(
            sampleEntry(
                id: "fts-upd",
                name: "kestrel",
                description: "Sync wibblefoo records"
            )
        )
        let zorglaxAfter = try db.searchBM25(query: "zorglax", topK: 10)
        #expect(zorglaxAfter.isEmpty)
        let wibblefoo = try db.searchBM25(query: "wibblefoo", topK: 10)
        #expect(wibblefoo.map(\.id) == ["fts-upd"])
    }

    @Test func fts5MirrorReflectsDelete() throws {
        let db = try makeTempDB()
        try db.upsertEntry(
            sampleEntry(
                id: "fts-del",
                name: "kestrel",
                description: "Manage zorglax fields"
            )
        )
        try db.deleteEntry(id: "fts-del")
        let after = try db.searchBM25(query: "zorglax", topK: 10)
        #expect(after.isEmpty)
    }

    @Test func searchBM25EmptyQueryReturnsEmpty() throws {
        let db = try makeTempDB()
        try db.upsertEntry(sampleEntry(id: "any", name: "anything", description: "anything"))
        // All-punctuation collapses to zero usable tokens; the
        // sanitiser returns nil and searchBM25 short-circuits to [].
        #expect(try db.searchBM25(query: "!@#$%^&*()", topK: 10).isEmpty)
        #expect(try db.searchBM25(query: "   ", topK: 10).isEmpty)
        #expect(try db.searchBM25(query: "", topK: 10).isEmpty)
    }

    @Test func searchBM25KeepsShortTechnicalTokens() throws {
        // Confirms the sanitiser does NOT impose a minimum token
        // length — `go`, `ai`, `ui` etc. are real technical tokens.
        let db = try makeTempDB()
        try db.upsertEntry(
            sampleEntry(
                id: "short-tok",
                name: "wibblefoo",
                description: "Useful for go projects"
            )
        )
        let results = try db.searchBM25(query: "go", topK: 10)
        #expect(results.map(\.id) == ["short-tok"])
    }

    @Test func loadAllEntryNamesFiltersBySource() throws {
        let db = try makeTempDB()
        try db.upsertEntry(sampleEntry(id: "sys-a", name: "alpha"))
        try db.upsertEntry(sampleEntry(id: "sys-b", name: "beta"))
        try db.upsertEntry(
            ToolIndexEntry(
                id: "manual-x",
                name: "xenon",
                description: "manual entry",
                runtime: .native,
                toolsJSON: "{}",
                source: .manual,
                tokenCount: 0
            )
        )

        let systemNames = try db.loadAllEntryNames(source: .system)
        #expect(systemNames.sorted() == ["sys-a", "sys-b"])

        let manualNames = try db.loadAllEntryNames(source: .manual)
        #expect(manualNames == ["manual-x"])
    }

    /// Smoke test for the `CapabilitySearchHealth` full-mode budget.
    /// Asserts the median wall-clock of `loadAllEntryNames(source:)` over
    /// 5 runs against a 100-entry index is ≤ 5ms — well below the 50ms
    /// runtime ceiling that trips `diffSkippedDueToBudget`. The 10× gap
    /// is intentional: a 5ms test catches a 10× regression while sitting
    /// above CI-runner / Intel-Mac noise. A 50ms test would silently let
    /// a 10× slowdown ship.
    @Test func loadAllEntryNamesIsFastOn100Entries() throws {
        let db = try makeTempDB()
        for i in 0 ..< 100 {
            try db.upsertEntry(sampleEntry(id: "tool-\(i)", name: "tool-\(i)"))
        }

        var samplesMs: [Double] = []
        for _ in 0 ..< 5 {
            let started = Date()
            let names = try db.loadAllEntryNames(source: .system)
            let elapsedMs = Date().timeIntervalSince(started) * 1000
            #expect(names.count == 100)
            samplesMs.append(elapsedMs)
        }
        let median = samplesMs.sorted()[samplesMs.count / 2]
        #expect(median <= 5.0, "loadAllEntryNames median \(median)ms exceeded 5ms budget on 100-entry index")
    }

    @Test func deleteAllClearsTable() throws {
        let db = try makeTempDB()
        try db.upsertEntry(sampleEntry(id: "a", name: "alpha"))
        try db.upsertEntry(sampleEntry(id: "b", name: "beta"))
        #expect(try db.entryCount() == 2)

        try db.deleteAll()
        #expect(try db.entryCount() == 0)
    }

    @Test func loadEntryNotFoundReturnsNil() throws {
        let db = try makeTempDB()
        #expect(try db.loadEntry(id: "nonexistent") == nil)
    }

    // MARK: - Runtime Field

    @Test func runtimeFieldStoredCorrectly() throws {
        let db = try makeTempDB()
        try db.upsertEntry(sampleEntry(id: "native-tool", runtime: .native))
        try db.upsertEntry(sampleEntry(id: "sandbox-tool", runtime: .sandbox))
        try db.upsertEntry(sampleEntry(id: "builtin-tool", runtime: .builtin))
        try db.upsertEntry(sampleEntry(id: "mcp-tool", runtime: .mcp))

        #expect(try db.loadEntry(id: "native-tool")?.runtime == .native)
        #expect(try db.loadEntry(id: "sandbox-tool")?.runtime == .sandbox)
        #expect(try db.loadEntry(id: "builtin-tool")?.runtime == .builtin)
        #expect(try db.loadEntry(id: "mcp-tool")?.runtime == .mcp)
    }

    @Test func mcpRuntimePersistsAndRoundtrips() throws {
        let db = try makeTempDB()
        let entry = ToolIndexEntry(
            id: "github_search",
            name: "github_search",
            description: "Search GitHub repositories via MCP",
            runtime: .mcp,
            toolsJSON: "{}",
            source: .system,
            tokenCount: 40
        )
        try db.upsertEntry(entry)

        let loaded = try db.loadEntry(id: "github_search")
        #expect(loaded != nil)
        #expect(loaded?.runtime == .mcp)
        #expect(loaded?.name == "github_search")
        #expect(loaded?.description == "Search GitHub repositories via MCP")
    }

    // MARK: - Migrations

    @Test func openInMemoryCreatesSchema() throws {
        let db = try makeTempDB()
        try db.upsertEntry(sampleEntry())
        let entries = try db.loadAllEntries()
        #expect(entries.count == 1)
    }

    // MARK: - Source Field

    @Test func sourceFieldPersists() throws {
        let db = try makeTempDB()
        let entry = ToolIndexEntry(
            id: "manual-tool",
            name: "manual-tool",
            description: "Manually added",
            runtime: .native,
            source: .manual,
            tokenCount: 25
        )
        try db.upsertEntry(entry)

        let loaded = try db.loadEntry(id: "manual-tool")
        #expect(loaded?.source == .manual)
    }

    @Test func communitySourceFieldPersists() throws {
        let db = try makeTempDB()
        let entry = ToolIndexEntry(
            id: "community-tool",
            name: "community-tool",
            description: "From community",
            runtime: .native,
            source: .community,
            tokenCount: 30
        )
        try db.upsertEntry(entry)

        let loaded = try db.loadEntry(id: "community-tool")
        #expect(loaded?.source == .community)
    }

    @Test func allSourceTypesDistinct() throws {
        let db = try makeTempDB()
        try db.upsertEntry(
            ToolIndexEntry(
                id: "sys",
                name: "sys",
                description: "system",
                runtime: .builtin,
                source: .system
            )
        )
        try db.upsertEntry(
            ToolIndexEntry(
                id: "man",
                name: "man",
                description: "manual",
                runtime: .native,
                source: .manual
            )
        )
        try db.upsertEntry(
            ToolIndexEntry(
                id: "comm",
                name: "comm",
                description: "community",
                runtime: .native,
                source: .community
            )
        )

        #expect(try db.loadEntry(id: "sys")?.source == .system)
        #expect(try db.loadEntry(id: "man")?.source == .manual)
        #expect(try db.loadEntry(id: "comm")?.source == .community)
        #expect(try db.entryCount() == 3)
    }

}
