import Foundation
import Testing
import VecturaKit

@testable import OsaurusCore

private actor RecoverableIndexEmbedder: VecturaEmbedder {
    var unavailable = true
    private(set) var attempts = 0
    var dimension: Int { get async throws { 128 } }

    func setAvailable() { unavailable = false }

    func embed(texts: [String]) async throws -> [[Float]] {
        attempts += 1
        if unavailable { throw VMLXModel2VecEmbedderError.modelNotFound("fixture") }
        return texts.map { _ in [Float](repeating: 1, count: 128) }
    }
}

private actor IndexRetrySleeper {
    private(set) var delays: [Duration] = []
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    func sleep(for delay: Duration) async throws {
        delays.append(delay)
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

@Suite(.serialized)
struct ToolSearchRetryTests {
    private enum WaitFailure: Error { case timedOut }

    private func waitFor(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw WaitFailure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func entry(_ id: String, description: String = "Queued tool") -> ToolIndexEntry {
        ToolIndexEntry(id: id, name: id, description: description, runtime: .builtin,
            toolsJSON: "{}", source: .system, tokenCount: 10)
    }

    private func database(at directory: URL, embedder: RecoverableIndexEmbedder) async throws -> VecturaKit {
        let config = try VecturaConfig(name: "retry-fixture", directoryURL: directory,
            dimension: 128, searchOptions: .init(defaultNumResults: 30,
                minThreshold: 0, hybridWeight: 1, k1: 1.2, b: 0.75), memoryStrategy: .automatic())
        return try await VecturaKit(config: config, embedder: embedder)
    }

    @Test func failedRegistrationBurstRecoversWithoutAnotherRegistration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let embedder = RecoverableIndexEmbedder()
        let sleeper = IndexRetrySleeper()
        let db = try await database(at: directory, embedder: embedder)
        let service = ToolSearchService(vectorDB: db, retrySleep: { try await sleeper.sleep(for: $0) })
        await service.indexEntry(entry("first"))
        try await waitFor { await sleeper.delays.count == 1 }
        for index in 0..<20 { await service.indexEntry(entry("tool-\(index)")) }
        await service.indexEntry(entry("first", description: "Newest registration survives"))
        #expect(await embedder.attempts == 1)
        #expect(await service.pendingIndexEntryCount == 21)
        await embedder.setAvailable()
        await sleeper.release()
        try await waitFor { await service.pendingIndexEntryCount == 0 }
        let matches = try await db.search(query: .text("queued tool"), numResults: 30)
        #expect(matches.count == 21)
        #expect(matches.contains { $0.text.contains("Newest registration survives") })
    }

    @Test func removedEntriesDoNotReturnFromACancelledRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let embedder = RecoverableIndexEmbedder()
        let sleeper = IndexRetrySleeper()
        let db = try await database(at: directory, embedder: embedder)
        let service = ToolSearchService(vectorDB: db, retrySleep: { try await sleeper.sleep(for: $0) })
        await service.indexEntry(entry("removed"))
        try await waitFor { await sleeper.delays.count == 1 }
        await service.removeEntry(id: "removed")
        await sleeper.release()
        await embedder.setAvailable()
        await service.indexEntry(entry("replacement"))
        try await waitFor { await service.pendingIndexEntryCount == 0 }
        let matches = try await db.search(query: .text("queued tool"), numResults: 30)
        #expect(matches.count == 1)
        #expect(matches.allSatisfy { !$0.text.contains("removed") })
    }

    @Test func repeatedFailuresBackOffWithoutRegistrationAndRemainCancellable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let embedder = RecoverableIndexEmbedder()
        let sleeper = IndexRetrySleeper()
        let db = try await database(at: directory, embedder: embedder)
        let service = ToolSearchService(vectorDB: db, retrySleep: { try await sleeper.sleep(for: $0) })
        await service.indexEntry(entry("unavailable"))
        try await waitFor { await sleeper.delays.count == 1 }
        for count in 2...7 {
            await sleeper.release()
            try await waitFor { await sleeper.delays.count == count }
        }
        #expect(await sleeper.delays == [.seconds(1), .seconds(2), .seconds(4),
            .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
        #expect(await embedder.attempts == 7)
        #expect(await service.hasPendingIndexEntry(id: "unavailable"))
        await service.removeEntry(id: "unavailable")
        await sleeper.release()
        #expect(await service.pendingIndexEntryCount == 0)
    }

}
