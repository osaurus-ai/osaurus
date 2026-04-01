//
//  VecturaTopKGuardTests.swift
//  osaurus
//
//  Documents that VecturaKit rejects numResults: 0, which is why all
//  search services need the `guard topK > 0` early return.
//

import Foundation
import Testing
import VecturaKit

struct VecturaTopKGuardTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vectura-topk-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func searchWithNumResultsZeroThrows() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let embedder = FakeEmbedder(fixedDimension: 128)
        let config = try VecturaConfig(
            name: "osaurus-topk",
            directoryURL: dir,
            dimension: 128,
            searchOptions: VecturaConfig.SearchOptions(
                defaultNumResults: 10,
                minThreshold: 0.0,
                hybridWeight: 0.5,
                k1: 1.2,
                b: 0.75
            ),
            memoryStrategy: .automatic()
        )

        let db = try await VecturaKit(config: config, embedder: embedder)
        _ = try await db.addDocument(text: "test document")

        do {
            _ = try await db.search(query: .text("test"), numResults: 0)
            Issue.record("Expected VecturaError.invalidInput for numResults: 0")
        } catch {
            // Expected: VecturaKit rejects numResults <= 0
        }
    }

    @Test func searchWithNumResultsOneSucceeds() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let embedder = FakeEmbedder(fixedDimension: 128)
        let config = try VecturaConfig(
            name: "osaurus-topk-ok",
            directoryURL: dir,
            dimension: 128,
            searchOptions: VecturaConfig.SearchOptions(
                defaultNumResults: 10,
                minThreshold: 0.0,
                hybridWeight: 0.5,
                k1: 1.2,
                b: 0.75
            ),
            memoryStrategy: .automatic()
        )

        let db = try await VecturaKit(config: config, embedder: embedder)
        _ = try await db.addDocument(text: "test document")

        let results = try await db.search(query: .text("test"), numResults: 1)
        #expect(results.count <= 1)
    }
}
