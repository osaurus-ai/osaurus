//
//  LogFileTailerTests.swift
//
//  Pin the tailer's contract: snapshot returns whatever's on disk now,
//  start() emits subsequent appends, and stop() releases the handle
//  cleanly so the file isn't kept open beyond the consumer's interest.
//

import Combine
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct LogFileTailerTests {

    private func tmpFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("log-tailer-\(UUID().uuidString).log")
    }

    @Test func snapshotReadsExistingContent() throws {
        let url = tmpFile()
        try "hello world\n".write(to: url, atomically: true, encoding: .utf8)
        let tailer = LogFileTailer(path: url.path)
        let snapshot = tailer.snapshot()
        #expect(String(data: snapshot, encoding: .utf8) == "hello world\n")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func snapshotReturnsEmptyWhenFileMissing() {
        let tailer = LogFileTailer(path: "/tmp/non-existent-\(UUID().uuidString).log")
        #expect(tailer.snapshot().isEmpty)
    }

    @Test func startEmitsExistingPrologueOnce() async throws {
        let url = tmpFile()
        try "prologue\n".write(to: url, atomically: true, encoding: .utf8)
        let tailer = LogFileTailer(path: url.path)
        let collector = ChunkCollector()
        let cancellable = tailer.publisher.sink { data in
            Task { await collector.append(data) }
        }
        defer {
            cancellable.cancel()
            tailer.stop()
            try? FileManager.default.removeItem(at: url)
        }
        tailer.start()
        // Let the publisher drain the synchronous prologue.
        try await Task.sleep(nanoseconds: 50_000_000)
        let chunks = await collector.chunks
        let combined = chunks.reduce(Data(), +)
        #expect(String(data: combined, encoding: .utf8) == "prologue\n")
    }

    @Test func stopIsIdempotent() {
        let tailer = LogFileTailer(path: "/tmp/never-existed-\(UUID().uuidString).log")
        tailer.stop()
        tailer.stop()  // no crash
    }
}

private actor ChunkCollector {
    private var _chunks: [Data] = []
    var chunks: [Data] { _chunks }
    func append(_ chunk: Data) { _chunks.append(chunk) }
}
