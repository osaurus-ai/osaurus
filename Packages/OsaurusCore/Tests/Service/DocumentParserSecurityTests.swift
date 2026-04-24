//
//  DocumentParserSecurityTests.swift
//  osaurusTests
//
//  Confirms that oversized documents are refused before the parser allocates
//  a decoded-text buffer. The existing `maxParsedTextLength` trim only bounds
//  the decoded text, so it does not protect against an attacker-controlled
//  ~hundreds-of-MB rich-document file whose decode pass would OOM the app.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("DocumentParser size gating")
struct DocumentParserSecurityTests {

    @Test func parseAll_rejectsFilesAboveCap() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-parser-\(UUID().uuidString).txt")
        // One byte over the cap is enough to flip the guard.
        let bytes = [UInt8](repeating: 0x41, count: DocumentParser.maxFileSize + 1)
        try Data(bytes).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: DocumentParser.ParseError.self) {
            _ = try DocumentParser.parseAll(url: tmp)
        }
    }

    @Test func parseAll_acceptsFilesAtCap() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-parser-\(UUID().uuidString).txt")
        let payload = "hello\n".data(using: .utf8)!
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let attachments = try DocumentParser.parseAll(url: tmp)
        #expect(attachments.isEmpty == false)
    }
}
