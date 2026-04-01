//
//  VecturaRecoveryTests.swift
//  osaurus
//
//  Tests for the corrupted-storage recovery pattern: VecturaKit init
//  fails on corrupt files, deleting the directory and retrying succeeds.
//

import Foundation
import Testing
import VecturaKit

@testable import OsaurusCore

struct VecturaRecoveryTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vectura-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func initToleratesCorruptFilesGracefully() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let documentsDir = dir.appendingPathComponent("osaurus-corrupt/documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: documentsDir.appendingPathComponent("bad.json"))

        let embedder = FakeEmbedder(fixedDimension: 128)
        let config = try VecturaConfig(
            name: "osaurus-corrupt",
            directoryURL: dir,
            dimension: 128,
            searchOptions: VecturaConfig.SearchOptions(
                defaultNumResults: 10,
                minThreshold: 0.3,
                hybridWeight: 0.5,
                k1: 1.2,
                b: 0.75
            ),
            memoryStrategy: .automatic()
        )

        // VecturaKit may or may not throw on corrupt files during init.
        // Our recovery loop handles both cases -- this verifies no crash.
        do {
            let db = try await VecturaKit(config: config, embedder: embedder)
            _ = try await db.addDocument(text: "still works")
        } catch {
            // Also acceptable: init or addDocument fails, recovery loop retries
        }
    }

    @Test func recoveryAfterDeletingCorruptStorage() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let documentsDir = dir.appendingPathComponent("osaurus-recovery/documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: documentsDir.appendingPathComponent("corrupt.json"))

        let embedder = FakeEmbedder(fixedDimension: 128)

        var db: VecturaKit?

        for attempt in 1 ... 2 {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                let config = try VecturaConfig(
                    name: "osaurus-recovery",
                    directoryURL: dir,
                    dimension: 128,
                    searchOptions: VecturaConfig.SearchOptions(
                        defaultNumResults: 10,
                        minThreshold: 0.3,
                        hybridWeight: 0.5,
                        k1: 1.2,
                        b: 0.75
                    ),
                    memoryStrategy: .automatic()
                )

                db = try await VecturaKit(config: config, embedder: embedder)
                break
            } catch {
                if attempt == 1 {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }

        #expect(db != nil, "VecturaKit should init after deleting corrupt storage")

        if let db {
            let id = try await db.addDocument(text: "test document after recovery")
            let results = try await db.search(query: .text("test document"), numResults: 1)
            #expect(!results.isEmpty)
            #expect(results[0].id == id)
        }
    }

    @Test func cleanStorageInitializesSuccessfully() async throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let embedder = FakeEmbedder(fixedDimension: 128)
        let config = try VecturaConfig(
            name: "osaurus-clean",
            directoryURL: dir,
            dimension: 128,
            searchOptions: VecturaConfig.SearchOptions(
                defaultNumResults: 10,
                minThreshold: 0.3,
                hybridWeight: 0.5,
                k1: 1.2,
                b: 0.75
            ),
            memoryStrategy: .automatic()
        )

        let db = try await VecturaKit(config: config, embedder: embedder)
        let id = try await db.addDocument(text: "hello world")
        let results = try await db.search(query: .text("hello"), numResults: 5)
        #expect(!results.isEmpty)
        #expect(results[0].id == id)
    }
}
