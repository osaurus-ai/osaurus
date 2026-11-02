import Foundation
import Testing

@testable import OsaurusCore

private actor KnowledgeRetryClock {
    private(set) var delays: [Duration] = []
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    func sleep(_ delay: Duration) async throws {
        delays.append(delay)
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func advance() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    func finish() {
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }
}

private actor KnowledgeEmbeddingProbe {
    var available = false
    var permitted = true
    var enabled = true
    private(set) var attempts: [String] = []
    func setAvailable() { available = true }
    func setPermitted(_ value: Bool) { permitted = value }
    func embed(_ hit: KnowledgeChunkHit) throws {
        attempts.append(hit.compositeKey)
        if !available { throw CancellationError() }
    }
}

struct KnowledgeVectorRecoveryTests {
    private func database(chunks: Int = 2) throws -> KnowledgeDatabase {
        let db = KnowledgeDatabase(); try db.openInMemory()
        let id = try db.upsertDocument(
            collectionId: "collection",
            relPath: "guide.md",
            title: "Guide",
            docType: "guide",
            summary: "",
            tagsCSV: "",
            contentHash: "unchanged",
            sizeBytes: 10,
            modifiedAt: ""
        )
        try db.replaceChunks(documentId: id, chunks: (0 ..< chunks).map { ("Heading", "searchable evidence \($0)") })
        return db
    }

    private func worker(
        _ db: KnowledgeDatabase,
        _ probe: KnowledgeEmbeddingProbe,
        _ clock: KnowledgeRetryClock
    ) -> KnowledgeVectorIndexer {
        KnowledgeVectorIndexer(
            load: { try db.pendingVectorChunks(collectionId: $0, limit: $1) },
            complete: { try db.markVectorIndexed($0) },
            embed: { try await probe.embed($0) },
            enabled: { _ in await probe.enabled },
            allowed: { await probe.permitted },
            sleep: { try await clock.sleep($0) }
        )
    }

    private func waitFor(_ predicate: @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(try await predicate()) {
            if ContinuousClock.now >= deadline { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func failedEmbeddingsRecoverWithoutEditingOrReparsingTheDocument() async throws {
        let db = try database(), probe = KnowledgeEmbeddingProbe(), clock = KnowledgeRetryClock()
        defer { Task { await clock.finish() } }
        let indexer = worker(db, probe, clock)
        await indexer.request(collectionId: "collection")
        try await waitFor { await clock.delays.count == 1 }
        for _ in 0 ..< 30 { await indexer.request(collectionId: "collection") }
        #expect(await probe.attempts.count == 1)
        #expect(try db.pendingVectorChunks(collectionId: "collection").count == 2)
        #expect(try db.documentHashes(collectionId: "collection")["guide.md"] == "unchanged")
        #expect(try !db.searchChunksText(query: "evidence", collectionIds: ["collection"]).isEmpty)
        await probe.setAvailable(); await clock.advance()
        try await waitFor { try db.pendingVectorChunks(collectionId: "collection").isEmpty }
        #expect(await probe.attempts.count == 3)
        #expect(try db.documentHashes(collectionId: "collection")["guide.md"] == "unchanged")
    }

    @Test func restartingWorkerOnlyResumesMissingChunksAndDrainsMultipleBatches() async throws {
        let db = try database(chunks: 40)
        let first = try #require(db.pendingVectorChunks(collectionId: "collection").first)
        try db.markVectorIndexed(first)
        let probe = KnowledgeEmbeddingProbe(), clock = KnowledgeRetryClock()
        defer { Task { await clock.finish() } }
        await probe.setAvailable()
        let indexer = worker(db, probe, clock)
        await indexer.request(collectionId: "collection")
        try await waitFor { try db.pendingVectorChunks(collectionId: "collection").isEmpty }
        #expect(await probe.attempts.count == 39)
        #expect(await probe.attempts.allSatisfy { $0 != first.compositeKey })
    }

    @Test func residentInferenceDefersVectorsButNotTextAndRecoversWhenIdle() async throws {
        let db = try database(), probe = KnowledgeEmbeddingProbe(), clock = KnowledgeRetryClock()
        defer { Task { await clock.finish() } }
        await probe.setAvailable(); await probe.setPermitted(false)
        let indexer = worker(db, probe, clock)
        await indexer.request(collectionId: "collection")
        try await waitFor { await clock.delays.count == 1 }
        #expect(await probe.attempts.isEmpty)
        #expect(try !db.searchChunksText(query: "evidence", collectionIds: ["collection"]).isEmpty)
        await probe.setPermitted(true); await clock.advance()
        try await waitFor { try db.pendingVectorChunks(collectionId: "collection").isEmpty }
    }

    @Test func oldCompletionCannotAcknowledgeEditedChunks() throws {
        let db = try database()
        let old = try #require(db.pendingVectorChunks(collectionId: "collection").first)
        try db.replaceChunks(documentId: old.documentId, chunks: [("Heading", "replacement body")])
        try db.markVectorIndexed(old)
        let pending = try db.pendingVectorChunks(collectionId: "collection")
        #expect(pending.count == 1)
        #expect(pending.first?.content == "replacement body")
        try db.markVectorIndexed(try #require(pending.first))
        #expect(try db.pendingVectorChunks(collectionId: "collection").isEmpty)
    }

    @Test func deletedDocumentsStayDeletedAndResetOnlyTouchesTheChosenCollection() throws {
        let db = try database()
        let hits = try db.pendingVectorChunks(collectionId: "collection")
        for hit in hits { try db.markVectorIndexed(hit) }
        try db.invalidateChunkVectors(collectionId: "different-collection")
        #expect(try db.pendingVectorChunks(collectionId: "collection").isEmpty)
        try db.invalidateChunkVectors(collectionId: "collection")
        #expect(try db.pendingVectorChunks(collectionId: "collection").count == 2)
        _ = try db.deleteDocument(collectionId: "collection", relPath: "guide.md")
        for hit in hits { try db.markVectorIndexed(hit) }
        #expect(try db.allChunks(collectionId: "collection").isEmpty)
        #expect(try db.pendingVectorChunks(collectionId: "collection").isEmpty)
    }

    @Test func repeatedFailureBacksOffAndDeletionCancelsTheRetry() async throws {
        let db = try database(), probe = KnowledgeEmbeddingProbe(), clock = KnowledgeRetryClock()
        defer { Task { await clock.finish() } }
        let indexer = worker(db, probe, clock)
        await indexer.request(collectionId: "collection")
        try await waitFor { await clock.delays.count == 1 }
        for count in 2 ... 7 {
            await clock.advance()
            try await waitFor { await clock.delays.count == count }
        }
        #expect(
            await clock.delays == [
                .seconds(1), .seconds(2), .seconds(4), .seconds(8),
                .seconds(16), .seconds(30), .seconds(30),
            ]
        )
        await indexer.cancel(collectionId: "collection")
        _ = try db.deleteDocument(collectionId: "collection", relPath: "guide.md")
        await clock.advance()
        #expect(await probe.attempts.count == 7)
        #expect(try db.pendingVectorChunks(collectionId: "collection").isEmpty)
    }
}
