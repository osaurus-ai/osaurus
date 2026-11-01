import Foundation
import Testing
import VecturaKit

@testable import OsaurusCore

private actor KnowledgeStoreEmbedder: VecturaEmbedder {
    var available = false
    private(set) var attempts = 0
    var dimension: Int { get async throws { 128 } }
    func recover() { available = true }
    func embed(texts: [String]) async throws -> [[Float]] {
        attempts += 1
        guard available else { throw CancellationError() }
        return texts.map { _ in [Float](repeating: 1, count: 128) }
    }
}

private actor KnowledgeStoreRetryGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, any Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0; waiting = true }
    }
    func resume() { let pending = continuation; continuation = nil; waiting = false; pending?.resume() }
    func finish() { let pending = continuation; continuation = nil; pending?.resume(throwing: CancellationError()) }
}

struct KnowledgeVectorStoreRecoveryTests {
    @Test func missingEmbedderRecoversIntoTheRealVectorStoreWithoutChangingText() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let embedder = KnowledgeStoreEmbedder(), gate = KnowledgeStoreRetryGate()
        defer { Task { await gate.finish() } }
        let config = try VecturaConfig(name: "knowledge-recovery", directoryURL: folder,
            dimension: 128, searchOptions: .init(defaultNumResults: 10, minThreshold: 0,
                hybridWeight: 1, k1: 1.2, b: 0.75), memoryStrategy: .automatic())
        let vectors = try await VecturaKit(config: config, embedder: embedder)
        let db = KnowledgeDatabase(); try db.openInMemory()
        let id = try db.upsertDocument(collectionId: "collection", relPath: "guide.md", title: "Guide",
            docType: "guide", summary: "", tagsCSV: "", contentHash: "unchanged",
            sizeBytes: 1, modifiedAt: "")
        try db.replaceChunks(documentId: id, chunks: [("Recovery", "The searchable retained knowledge")])
        let vectorID = UUID()
        let worker = KnowledgeVectorIndexer(
            load: { try db.pendingVectorChunks(collectionId: $0, limit: $1) },
            complete: { try db.markVectorIndexed($0) },
            embed: { hit in _ = try await vectors.addDocument(text: hit.content, id: vectorID) },
            enabled: { _ in true }, allowed: { true }, sleep: { _ in try await gate.wait() })
        await worker.request(collectionId: "collection")
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.waiting) {
            guard ContinuousClock.now < firstDeadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try db.pendingVectorChunks(collectionId: "collection").count == 1)
        await embedder.recover(); await gate.resume()
        let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try !db.pendingVectorChunks(collectionId: "collection").isEmpty {
            guard ContinuousClock.now < recoveryDeadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
        let matches = try await vectors.search(query: .text("retained knowledge"), numResults: 10)
        #expect(matches.count == 1)
        #expect(matches.first?.id == vectorID)
        #expect(matches.first?.text == "The searchable retained knowledge")
        #expect(try db.documentHashes(collectionId: "collection")["guide.md"] == "unchanged")
    }
}
