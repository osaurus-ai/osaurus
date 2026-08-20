//
//  KnowledgeWriteLogTests.swift
//  OsaurusCoreTests — Knowledge
//
//  The durable write log behind knowledge direct write. Call-time approval
//  trades considered review for immediate action, and revert is what makes
//  that trade safe, so the log's guarantees are the load-bearing part:
//  a record survives the chat that made it, it carries enough to restore the
//  prior document exactly, and reverting can never quietly discard content
//  that arrived after the agent's write.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct KnowledgeWriteLogTests {

    private func makeDB() -> KnowledgeWriteLogDatabase? {
        let db = KnowledgeWriteLogDatabase()
        do {
            try db.openInMemory()
            return db
        } catch {
            Issue.record("Could not open in-memory knowledge write log: \(error)")
            return nil
        }
    }

    @discardableResult
    private func log(
        _ db: KnowledgeWriteLogDatabase,
        collectionId: String = "c1",
        relPath: String = "a.md",
        operation: KnowledgeWriteOperation = .replace,
        priorContent: String = "before",
        resultContent: String = "after",
        runId: String = "run-1",
        rationale: String = "because"
    ) throws -> Int {
        try db.insert(
            collectionId: collectionId,
            relPath: relPath,
            operation: operation,
            priorContent: priorContent,
            priorContentHash: priorContent.isEmpty
                ? "" : KnowledgeWriteService.sha256Hex(priorContent),
            resultContentHash: resultContent.isEmpty
                ? "" : KnowledgeWriteService.sha256Hex(resultContent),
            runId: runId,
            createdBy: "agent-1",
            rationale: rationale,
            createdAt: "2026-08-20T10:00:00Z"
        )
    }

    // MARK: - Round trip

    @Test func recordRoundTripsEveryField() throws {
        guard let db = makeDB() else { return }
        let id = try log(db, priorContent: "old body", resultContent: "new body")
        let record = try #require(db.record(id: id))

        #expect(record.collectionId == "c1")
        #expect(record.relPath == "a.md")
        #expect(record.operation == .replace)
        // The WHOLE prior document, not a diff: a revert must not depend on
        // the current file still being what the agent left behind.
        #expect(record.priorContent == "old body")
        #expect(record.priorContentHash == KnowledgeWriteService.sha256Hex("old body"))
        #expect(record.resultContentHash == KnowledgeWriteService.sha256Hex("new body"))
        #expect(record.runId == "run-1")
        #expect(record.createdBy == "agent-1")
        #expect(record.rationale == "because")
        #expect(record.revertedAt == nil)
        #expect(!record.isReverted)
    }

    @Test func createRecordsNoPriorContent() throws {
        guard let db = makeDB() else { return }
        let id = try log(db, operation: .create, priorContent: "", resultContent: "fresh")
        let record = try #require(db.record(id: id))
        #expect(record.operation == .create)
        #expect(record.priorContent.isEmpty)
        #expect(record.priorContentHash.isEmpty)
        #expect(record.resultContentHash == KnowledgeWriteService.sha256Hex("fresh"))
    }

    /// A delete leaves nothing on disk, so its result hash is the same ""
    /// an absent file produces. That is what lets the revert guard compare
    /// uniformly across all three operations.
    @Test func deleteRecordsEmptyResultHash() throws {
        guard let db = makeDB() else { return }
        let id = try log(db, operation: .delete, priorContent: "doomed", resultContent: "")
        let record = try #require(db.record(id: id))
        #expect(record.operation == .delete)
        #expect(record.priorContent == "doomed")
        #expect(record.resultContentHash.isEmpty)
    }

    // MARK: - Listing

    @Test func collectionHistoryIsNewestFirstAndScoped() throws {
        guard let db = makeDB() else { return }
        let first = try log(db, collectionId: "c1", relPath: "one.md")
        let second = try log(db, collectionId: "c1", relPath: "two.md")
        try log(db, collectionId: "other", relPath: "hidden.md")

        let history = try db.records(collectionId: "c1")
        #expect(history.map(\.id) == [second, first])
        // Scoping is structural, like every other knowledge read.
        #expect(!history.contains { $0.relPath == "hidden.md" })
    }

    /// The run query drives "revert everything this import did", so it must
    /// return newest first. Reverting in reverse application order is the only
    /// sequence that restores correctly when one run wrote a path twice.
    @Test func runHistoryIsNewestFirstForReverseReplay() throws {
        guard let db = makeDB() else { return }
        let first = try log(db, relPath: "a.md", runId: "import")
        let second = try log(db, relPath: "a.md", runId: "import")
        let third = try log(db, relPath: "b.md", runId: "import")
        try log(db, relPath: "c.md", runId: "unrelated")

        let run = try db.records(runId: "import")
        #expect(run.map(\.id) == [third, second, first])
    }

    @Test func revertedRecordsLeaveTheRunQueueButStayInHistory() throws {
        guard let db = makeDB() else { return }
        let id = try log(db, runId: "import")
        try db.markReverted(id: id, revertedAt: "2026-08-20T11:00:00Z")

        // A reverted write must not be reverted twice by a later batch call.
        #expect(try db.records(runId: "import").isEmpty)

        // But history stays readable rather than silently shrinking.
        let history = try db.records(collectionId: "c1")
        #expect(history.count == 1)
        #expect(history[0].isReverted)
        #expect(history[0].revertedAt == "2026-08-20T11:00:00Z")

        let filtered = try db.records(collectionId: "c1", includeReverted: false)
        #expect(filtered.isEmpty)
    }

    // MARK: - Retention
    //
    // The log stores WHOLE prior documents, so an unbounded history of a
    // frequently rewritten collection would grow without limit. Pruning has to
    // protect the undo that still matters, not just the newest rows.

    /// Reverted rows are pure history — their content was already restored —
    /// so they are discarded before any un-reverted row, whatever their age.
    @Test func pruningDiscardsRevertedHistoryBeforeLiveUndo() throws {
        guard let db = makeDB() else { return }
        let limit = KnowledgeWriteLogDatabase.retentionLimitPerCollection

        // Oldest rows, all reverted: pure history.
        var revertedIds: [Int] = []
        for index in 0 ..< 10 {
            let id = try log(db, relPath: "reverted-\(index).md")
            try db.markReverted(id: id, revertedAt: "2026-08-20T11:00:00Z")
            revertedIds.append(id)
        }
        // Then fill exactly to the limit with live, revertable writes.
        var liveIds: [Int] = []
        for index in 0 ..< limit {
            liveIds.append(try log(db, relPath: "live-\(index).md"))
        }

        let kept = Set(try db.records(collectionId: "c1", limit: limit * 2).map(\.id))
        // Every live undo survived...
        #expect(liveIds.allSatisfy { kept.contains($0) })
        // ...and the reverted history was what got dropped.
        #expect(revertedIds.allSatisfy { !kept.contains($0) })
    }

    /// Under the limit nothing is pruned at all.
    @Test func pruningLeavesSmallHistoriesAlone() throws {
        guard let db = makeDB() else { return }
        var ids: [Int] = []
        for index in 0 ..< 20 {
            ids.append(try log(db, relPath: "doc-\(index).md"))
        }
        let kept = Set(try db.records(collectionId: "c1").map(\.id))
        #expect(ids.allSatisfy { kept.contains($0) })
    }

    /// Pruning is scoped per collection, so a busy collection cannot evict a
    /// quiet one's undo history.
    @Test func pruningIsScopedPerCollection() throws {
        guard let db = makeDB() else { return }
        let quiet = try log(db, collectionId: "quiet", relPath: "rare.md")
        for index in 0 ..< (KnowledgeWriteLogDatabase.retentionLimitPerCollection + 50) {
            try log(db, collectionId: "busy", relPath: "doc-\(index).md")
        }
        let quietHistory = try db.records(collectionId: "quiet")
        #expect(quietHistory.map(\.id) == [quiet])
    }

    /// Deleting a collection discards its history: nothing can be reverted
    /// into a collection that no longer exists.
    @Test func deletingACollectionDropsItsHistory() throws {
        guard let db = makeDB() else { return }
        try log(db, collectionId: "gone", relPath: "a.md")
        let keep = try log(db, collectionId: "stays", relPath: "b.md")

        try db.deleteRecords(collectionId: "gone")
        #expect(try db.records(collectionId: "gone").isEmpty)
        #expect(try db.records(collectionId: "stays").map(\.id) == [keep])
    }

    // MARK: - Path confinement
    //
    // Re-checked in the service because that is the code that actually
    // writes; the tool layer is not trusted to have done it.

    @Test func pathsEscapingTheCollectionAreRejected() throws {
        let collection = KnowledgeCollection(
            name: "packaging",
            folderPath: "/tmp/osaurus-knowledge-test/packaging"
        )
        let escapes = [
            "../outside.md",
            "nested/../../outside.md",
            "/etc/passwd.md",
            "~/notes.md",
            "",
        ]
        for path in escapes {
            #expect(throws: KnowledgeWriteError.self) {
                _ = try KnowledgeWriteService.resolvedURL(collection: collection, relPath: path)
            }
        }
    }

    /// A sibling folder whose name merely starts with the collection's path
    /// must not pass the prefix check.
    @Test func siblingFolderWithSharedPrefixIsRejected() throws {
        let collection = KnowledgeCollection(
            name: "docs",
            folderPath: "/tmp/osaurus-knowledge-test/docs"
        )
        #expect(throws: KnowledgeWriteError.self) {
            _ = try KnowledgeWriteService.resolvedURL(
                collection: collection,
                relPath: "../docs-evil/leak.md"
            )
        }
    }

    /// Writing plain text onto an adapter-extracted format would destroy the
    /// binary source of truth.
    @Test func nonMarkdownTargetsAreRejected() throws {
        let collection = KnowledgeCollection(
            name: "docs",
            folderPath: "/tmp/osaurus-knowledge-test/docs"
        )
        for path in ["manual.pdf", "sheet.xlsx", "report.docx", "notes.txt"] {
            #expect(throws: KnowledgeWriteError.self) {
                _ = try KnowledgeWriteService.resolvedURL(collection: collection, relPath: path)
            }
        }
    }

    @Test func ordinaryMarkdownPathsResolveInsideTheFolder() throws {
        let collection = KnowledgeCollection(
            name: "docs",
            folderPath: "/tmp/osaurus-knowledge-test/docs"
        )
        let url = try KnowledgeWriteService.resolvedURL(
            collection: collection,
            relPath: "usage/how-to-deploy.md"
        )
        #expect(url.path.hasSuffix("/docs/usage/how-to-deploy.md"))
    }
}
