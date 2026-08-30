//
//  FileReadPagingWarningTests.swift
//  osaurusTests
//
//  Continuation reads (start_line > 1) of a file above the absolute
//  read ceiling must carry the anti-paging warning; first reads and
//  small files must not.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileReadPagingWarningTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-paging-warning-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(chars: Int, root: URL) throws {
        let line = "item 0123456789 abcdefghijklmnopqrstuvwxyz\n"
        let content = String(repeating: line, count: chars / line.count + 1)
        try content.write(
            to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
    }

    @Test func continuationRead_ofHugeFile_warnsAgainstPaging() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFile(chars: ToolOutputCaps.fileReadMax * 3, root: root)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"big.txt","start_line":400}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        let warning = payload["paging_warning"] as? String
        #expect(warning?.contains("redact_file") == true)
    }

    @Test func firstRead_ofHugeFile_noPagingWarning() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFile(chars: ToolOutputCaps.fileReadMax * 3, root: root)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"big.txt"}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["paging_warning"] == nil)
    }

    @Test func rangeRead_ofSmallFile_noPagingWarning() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFile(chars: 5_000, root: root)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"big.txt","start_line":10,"end_line":20}"#
        )
        let payload = try #require(ToolEnvelope.successPayload(output) as? [String: Any])
        #expect(payload["paging_warning"] == nil)
    }
}
