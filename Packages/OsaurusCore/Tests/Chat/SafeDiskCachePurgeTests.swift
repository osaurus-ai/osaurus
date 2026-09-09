import Foundation
import SQLite3
import Testing
@testable import OsaurusCore

@Suite struct SafeDiskCachePurgeTests {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("safe-cache-purge-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func index(_ root: URL, hash: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache_index.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(
            sqlite3_exec(
                db,
                "CREATE TABLE cache_entries(hash TEXT PRIMARY KEY); INSERT INTO cache_entries VALUES('\(hash)');",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
    }

    @Test func onlyOwnedFilesAreRemoved() throws {
        try withRoot { root in
            let hash = String(repeating: "a", count: 32)
            try index(root, hash: hash)
            let owned = root.appendingPathComponent(hash + ".safetensors")
            let unrelated = root.appendingPathComponent("model.safetensors")
            try Data([1, 2, 3]).write(to: owned)
            try Data([4, 5]).write(to: unrelated)
            let result = SafeDiskCachePurge.clear(directory: root)
            #expect(result.error == nil)
            #expect(result.reclaimedBytes == 3 && result.removedFiles == 1)
            #expect(!FileManager.default.fileExists(atPath: owned.path))
            #expect(try Data(contentsOf: unrelated) == Data([4, 5]))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache_index.db").path))
        }
    }

    @Test func linkedPayloadAndModelDirectoryRefuseWithoutDeletion() throws {
        try withRoot { root in
            let hash = String(repeating: "b", count: 32)
            try index(root, hash: hash)
            let target = root.appendingPathComponent("preserve.bin")
            try Data([7]).write(to: target)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(hash + ".safetensors"),
                withDestinationURL: target
            )
            #expect(SafeDiskCachePurge.clear(directory: root).error != nil)
            #expect(try Data(contentsOf: target) == Data([7]))
            try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
            #expect(SafeDiskCachePurge.clear(directory: root).error != nil)
        }
    }

    @Test func missingIndexNeverSweepsUnknownFiles() throws {
        try withRoot { root in
            let file = root.appendingPathComponent("model.safetensors")
            try Data([9]).write(to: file)
            #expect(SafeDiskCachePurge.clear(directory: root).error != nil)
            #expect(try Data(contentsOf: file) == Data([9]))
        }
    }

    @Test func invalidIndexPathAndBusyWriterRefuse() throws {
        try withRoot { root in
            try index(root, hash: "../model")
            #expect(SafeDiskCachePurge.clear(directory: root).error != nil)
        }
        try withRoot { root in
            try index(root, hash: String(repeating: "c", count: 32))
            var db: OpaquePointer?
            #expect(sqlite3_open(root.appendingPathComponent("cache_index.db").path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
            #expect(SafeDiskCachePurge.clear(directory: root).error?.contains("busy") == true)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    @Test func unknownDisabledAndBelowQuotaDoNotWarn() {
        #expect(!DiskCacheUsage(usedBytes: 100, maxBytes: 0).shouldWarn)
        #expect(!DiskCacheUsage(usedBytes: 100, maxBytes: 100, isDisabled: true).shouldWarn)
        #expect(!DiskCacheUsage(usedBytes: 74, maxBytes: 100).shouldWarn)
        #expect(DiskCacheUsage(usedBytes: 75, maxBytes: 100).shouldWarn)
        #expect(DiskCacheUsage(usedBytes: 100, maxBytes: 100).shouldWarn)
        #expect(!DiskCacheUsage(usedBytes: Int.max, maxBytes: 1).warningText.isEmpty)
        #expect(!DiskCacheUsage(usedBytes: 80, maxBytes: 100).warningText.contains("has been removed"))
        #expect(DiskCacheUsage(usedBytes: 80, maxBytes: 100, evictions: 1).warningText.contains("has been removed"))
    }
}
