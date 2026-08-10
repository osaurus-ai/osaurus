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

    /// SQLCipher's in-memory open is plaintext and should always work;
    /// treat a failure as an environment problem, not a test failure.
    private func makeDBOrSkip() -> KnowledgeDatabase? {
        do {
            return try makeDB()
        } catch {
            Issue.record("Could not open in-memory knowledge database: \(error)")
            return nil
        }
    }
}
