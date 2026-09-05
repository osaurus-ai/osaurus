//
//  KnowledgeDatabaseTests.swift
//  osaurusTests
//
//  In-memory round-trip tests for the knowledge index: upsert/replace,
//  FTS search with collection scoping, facet listing, and pruning.
//

import Foundation
import Testing

@testable import OsaurusCore

struct KnowledgeDatabaseTests {

    private func makeDB() throws -> KnowledgeDatabase {
        let db = KnowledgeDatabase()
        try db.openInMemory()
        return db
    }

    @discardableResult
    private func seedDocument(
        _ db: KnowledgeDatabase,
        collectionId: String,
        relPath: String,
        title: String = "Doc",
        docType: String = "guide",
        inferredType: String = "",
        tagsCSV: String = "wordpress,php",
        chunks: [(headingPath: String, content: String)]
    ) throws -> Int {
        let documentId = try db.upsertDocument(
            collectionId: collectionId,
            relPath: relPath,
            title: title,
            docType: docType,
            inferredType: inferredType,
            summary: "",
            tagsCSV: tagsCSV,
            contentHash: "hash-\(relPath)",
            sizeBytes: 100,
            modifiedAt: "2026-07-02T00:00:00Z"
        )
        try db.replaceChunks(documentId: documentId, chunks: chunks)
        return documentId
    }

    @Test
    func upsertIsIdempotentByCollectionAndPath() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        let first = try seedDocument(
            db, collectionId: "c1", relPath: "a.md",
            chunks: [("", "alpha")]
        )
        let second = try db.upsertDocument(
            collectionId: "c1",
            relPath: "a.md",
            title: "Updated",
            docType: "runbook",
            summary: "",
            tagsCSV: "",
            contentHash: "new-hash",
            sizeBytes: 1,
            modifiedAt: ""
        )
        #expect(first == second)
        let doc = try db.getDocument(collectionId: "c1", relPath: "a.md")
        #expect(doc?.title == "Updated")
        #expect(doc?.docType == "runbook")
        #expect(doc?.contentHash == "new-hash")
    }

    @Test
    func replaceChunksReturnsPreviousCount() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        let id = try seedDocument(
            db, collectionId: "c1", relPath: "a.md",
            chunks: [("", "one"), ("", "two"), ("", "three")]
        )
        let removed = try db.replaceChunks(documentId: id, chunks: [("", "only")])
        #expect(removed == 3)
    }

    @Test
    func ftsSearchFindsChunkAndRespectsCollectionScope() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        try seedDocument(
            db, collectionId: "granted", relPath: "wp.md",
            chunks: [("Plugins", "WordPress plugin development requires a master template")]
        )
        try seedDocument(
            db, collectionId: "other", relPath: "secret.md",
            chunks: [("", "WordPress secrets that must not leak across collections")]
        )

        let hits = try db.searchChunksText(query: "wordpress template", collectionIds: ["granted"], limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.relPath == "wp.md")
        #expect(hits.first?.headingPath == "Plugins")

        // Scoping is structural: the other collection's content is invisible.
        let leaked = try db.searchChunksText(query: "secrets", collectionIds: ["granted"], limit: 10)
        #expect(leaked.isEmpty)

        // Empty scope returns nothing, never everything.
        let unscoped = try db.searchChunksText(query: "wordpress", collectionIds: [], limit: 10)
        #expect(unscoped.isEmpty)
    }

    @Test
    func ftsSearchMatchesMultiWordQuerySplitAcrossChunks() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        // A heading-split policy doc: no single chunk holds every query
        // word. Implicit-AND (whitespace-joined) MATCH found nothing here;
        // OR-joined terms must still surface the document.
        try seedDocument(
            db, collectionId: "granted", relPath: "refund-policy.md",
            chunks: [
                ("Refund Policy", "This is the single source of truth for billing."),
                ("Eligibility window", "Customers may request a full refund within 30 days."),
            ]
        )

        let hits = try db.searchChunksText(
            query: "refund policy window customer request",
            collectionIds: ["granted"], limit: 10
        )
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.relPath == "refund-policy.md" })
    }

    @Test
    func ftsSearchPrefixMatchesPluralForms() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        try seedDocument(
            db, collectionId: "granted", relPath: "p.md",
            chunks: [("", "Customers may request refunds anytime.")]
        )
        // Singular query terms must reach plural document tokens under the
        // non-stemming unicode61 tokenizer, via prefix matching.
        let hits = try db.searchChunksText(query: "customer refund", collectionIds: ["granted"], limit: 10)
        #expect(hits.contains { $0.relPath == "p.md" })
    }

    @Test
    func listDocumentsFiltersByTypeAndTag() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        try seedDocument(
            db, collectionId: "c1", relPath: "guide.md", docType: "guide",
            tagsCSV: "wordpress,php", chunks: [("", "g")]
        )
        try seedDocument(
            db, collectionId: "c1", relPath: "runbook.md", docType: "runbook",
            tagsCSV: "ops", chunks: [("", "r")]
        )

        let guides = try db.listDocuments(collectionIds: ["c1"], docType: "guide")
        #expect(guides.map(\.relPath) == ["guide.md"])

        let tagged = try db.listDocuments(collectionIds: ["c1"], tag: "ops")
        #expect(tagged.map(\.relPath) == ["runbook.md"])

        // Tag match is exact against the normalized list, not substring.
        let partial = try db.listDocuments(collectionIds: ["c1"], tag: "op")
        #expect(partial.isEmpty)
    }

    @Test
    func typeFilterMatchesInferredTypeAndExplicitTypeWins() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        // No explicit type — inferred from folder.
        try seedDocument(
            db, collectionId: "c1", relPath: "recipes/pasta.md",
            docType: "", inferredType: "recipes", chunks: [("", "p")]
        )
        // Explicit type present — a stale inferred value must not leak.
        try seedDocument(
            db, collectionId: "c1", relPath: "recipes/notes.md",
            docType: "guide", inferredType: "recipes", chunks: [("", "n")]
        )

        let recipes = try db.listDocuments(collectionIds: ["c1"], docType: "recipes")
        #expect(recipes.map(\.relPath) == ["recipes/pasta.md"])
        #expect(recipes.first?.effectiveType == "recipes")
        #expect(recipes.first?.isTypeInferred == true)

        let guides = try db.listDocuments(collectionIds: ["c1"], docType: "guide")
        #expect(guides.map(\.relPath) == ["recipes/notes.md"])
        #expect(guides.first?.isTypeInferred == false)
    }

    @Test
    func deleteDocumentReturnsChunkCountAndRemovesRows() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        try seedDocument(
            db, collectionId: "c1", relPath: "a.md",
            chunks: [("", "one"), ("", "two")]
        )
        let removed = try db.deleteDocument(collectionId: "c1", relPath: "a.md")
        #expect(removed == 2)
        #expect(try db.getDocument(collectionId: "c1", relPath: "a.md") == nil)
        #expect(try db.searchChunksText(query: "one", collectionIds: ["c1"], limit: 10).isEmpty)
    }

    @Test
    func deleteCollectionPurgesEverything() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        try seedDocument(db, collectionId: "c1", relPath: "a.md", chunks: [("", "alpha")])
        try seedDocument(db, collectionId: "c1", relPath: "b.md", chunks: [("", "beta")])
        try db.deleteCollection(collectionId: "c1")
        #expect(try db.documentHashes(collectionId: "c1").isEmpty)
        #expect(try db.allChunks(collectionId: "c1").isEmpty)
    }

    @Test
    func documentHashesDriveIncrementalSkip() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        try seedDocument(db, collectionId: "c1", relPath: "a.md", chunks: [("", "alpha")])
        let hashes = try db.documentHashes(collectionId: "c1")
        #expect(hashes == ["a.md": "hash-a.md"])
    }

    @Test
    func loadChunksByCompositeKeysRoundTrips() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        try seedDocument(
            db, collectionId: "c1", relPath: "a.md",
            chunks: [("H", "first"), ("H", "second")]
        )
        let hits = try db.loadChunksByCompositeKeys([
            (collectionId: "c1", relPath: "a.md", chunkIndex: 1)
        ])
        #expect(hits.count == 1)
        #expect(hits.first?.content == "second")
        #expect(hits.first?.compositeKey == "c1:a.md:1")
    }

    /// The read path resolves "is the writer open / in-memory" from a
    /// lock-free mirror instead of hopping onto the writer queue, so a
    /// read-only query can never park behind the indexer's write backlog
    /// (osaurus#2439: a 5m56s `list_knowledge` during an initial index).
    /// If the mirror is not published on open, an in-memory DB reports
    /// "not open", the reader is skipped, and every read still works via the
    /// write-connection fallback — silently restoring the old behaviour.
    /// These assertions fail loudly instead.
    @Test func inMemoryDatabaseKeepsReadsOnTheWriteConnection() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        let snapshot = db.writerStateSnapshotForTesting
        #expect(snapshot.isOpen)
        #expect(snapshot.isInMemory)
        // A `:memory:` DB is private to its connection, so the reader must
        // stay unopened — otherwise reads would query an empty database.
        #expect(db.hasOpenReadConnectionForTesting == false)
    }

    /// Reads must still return rows with the reader suppressed.
    @Test func readsSucceedThroughTheWriteConnectionFallback() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        try seedDocument(
            db, collectionId: "c1", relPath: "a.md",
            chunks: [("H", "first")]
        )
        let documents = try db.listDocuments(collectionIds: ["c1"], limit: 10)
        #expect(documents.count == 1)
        #expect(db.hasOpenReadConnectionForTesting == false)
    }

    /// Closing must retract the mirror, or a reader could be opened against
    /// a closed database on the next read.
    @Test func closingRetractsThePublishedWriterState() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        #expect(db.writerStateSnapshotForTesting.isOpen)
        db.close()
        let snapshot = db.writerStateSnapshotForTesting
        #expect(!snapshot.isOpen)
        #expect(!snapshot.isInMemory)
    }

    /// SQLCipher's in-memory open is plaintext and should always work;
    /// treat a failure as an environment problem, not a test failure.
    /// Paging must cover every row exactly once, including a last page that
    /// does not divide evenly by the page size (7 rows, pages of 3).
    @Test func listDocumentsPagesWithOffsetAndCountAgrees() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        for i in 0..<7 {
            try seedDocument(
                db, collectionId: "c1", relPath: "n\(i).md",
                docType: i % 2 == 0 ? "guide" : "note",
                tagsCSV: i < 5 ? "ops" : "misc",
                chunks: [("", "body \(i)")]
            )
        }
        #expect(try db.countDocuments(collectionIds: ["c1"]) == 7)
        #expect(try db.countDocuments(collectionIds: ["c1", "absent"]) == 7)
        #expect(try db.countDocuments(collectionIds: ["absent"]) == 0)
        #expect(try db.countDocuments(collectionIds: []) == 0)

        var seen: [String] = []
        var offset = 0
        while true {
            let page = try db.listDocuments(collectionIds: ["c1"], limit: 3, offset: offset)
            if page.isEmpty { break }
            seen += page.map(\.relPath)
            offset += page.count
        }
        #expect(seen == ["n0.md", "n1.md", "n2.md", "n3.md", "n4.md", "n5.md", "n6.md"])
        #expect(offset == 7)
        // Past the end: empty, not an error.
        #expect(try db.listDocuments(collectionIds: ["c1"], limit: 3, offset: 7).isEmpty)
        // A negative offset is treated as 0.
        #expect(try db.listDocuments(collectionIds: ["c1"], limit: 3, offset: -4).count == 3)
    }

    /// The total honours the same type/tag filters as the page.
    @Test func countDocumentsHonoursFilters() throws {
        let db = makeDBOrSkip()
        guard let db else { return }
        for i in 0..<7 {
            try seedDocument(
                db, collectionId: "c1", relPath: "n\(i).md",
                docType: i % 2 == 0 ? "guide" : "note",
                tagsCSV: i < 5 ? "ops" : "misc",
                chunks: [("", "body \(i)")]
            )
        }
        #expect(try db.countDocuments(collectionIds: ["c1"], docType: "guide") == 4)
        #expect(try db.countDocuments(collectionIds: ["c1"], docType: "GUIDE") == 4)
        #expect(try db.countDocuments(collectionIds: ["c1"], tag: "ops") == 5)
        #expect(try db.countDocuments(collectionIds: ["c1"], docType: "note", tag: "ops") == 2)
        let page = try db.listDocuments(collectionIds: ["c1"], docType: "note", tag: "ops", limit: 1, offset: 1)
        #expect(page.map(\.relPath) == ["n3.md"])
    }

    private func makeDBOrSkip() -> KnowledgeDatabase? {
        do {
            return try makeDB()
        } catch {
            Issue.record("Could not open in-memory knowledge database: \(error)")
            return nil
        }
    }
}
