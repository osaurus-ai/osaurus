// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// Quit-time durability for the async config writer: `applicationWillTerminate`
/// ends with `_exit(0)`, which skips pending background writes unless
/// `flushPendingWrites` drains the queue first.
@Suite("ConfigDiskWriter flush")
struct ConfigDiskWriterFlushTests {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-disk-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("flush lands every asynchronous write enqueued before it")
    func flushDrainsPendingWrites() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var urls: [URL] = []
        for index in 0..<20 {
            let url = directory.appendingPathComponent("config-\(index).json")
            urls.append(url)
            ConfigDiskWriter.write(Data("{\"index\":\(index)}".utf8), to: url, synchronous: false)
        }

        ConfigDiskWriter.flushPendingWrites()

        for (index, url) in urls.enumerated() {
            let data = try Data(contentsOf: url)
            #expect(String(data: data, encoding: .utf8) == "{\"index\":\(index)}")
        }
    }

    @Test("last write wins for repeated writes to the same file")
    func lastWriteWins() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("remote.json")

        for revision in 0..<50 {
            ConfigDiskWriter.write(Data("rev-\(revision)".utf8), to: url, synchronous: false)
        }
        ConfigDiskWriter.flushPendingWrites()

        let data = try Data(contentsOf: url)
        #expect(String(data: data, encoding: .utf8) == "rev-49")
    }

    @Test("flush reports errors to the caller instead of dropping them")
    func writeErrorsReachOnError() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let url = missingDirectory.appendingPathComponent("config.json")

        final class ErrorBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _error: Error?
            var error: Error? {
                get { lock.withLock { _error } }
                set { lock.withLock { _error = newValue } }
            }
        }
        let box = ErrorBox()
        ConfigDiskWriter.write(Data("x".utf8), to: url, synchronous: false) { box.error = $0 }
        ConfigDiskWriter.flushPendingWrites()

        #expect(box.error != nil)
    }

    @Test("flush with an idle queue returns promptly")
    func idleFlushIsCheap() {
        let start = Date()
        ConfigDiskWriter.flushPendingWrites(timeout: 1.0)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }
}
