//
//  FolderSecretScopeTests.swift
//  osaurusTests
//
//  Pins the combined sandbox + host-read secret denylist across ALL three
//  host read tools, not just `file_read`. The denylist is only meaningful
//  if it can't be bypassed by switching tools: `file_search` must not
//  return secret file contents (whole-file or via an explicit `path`), and
//  `file_tree` must not even disclose secret file names. Plain folder mode
//  (no read-only host scope bound) keeps its existing behavior.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FolderSecretScopeTests {

    private func makeRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-secret-scope-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - file_search

    @Test func fileSearchRefusesExplicitSecretFileInCombinedMode() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("API_TOKEN=supersecret", to: root.appendingPathComponent(".env"))

        let tool = FileSearchTool(rootPath: root)
        let envelope = try await ChatExecutionContext.$hostReadOnlyScope.withValue(root) {
            try await tool.execute(argumentsJSON: #"{"pattern":"TOKEN","path":".env"}"#)
        }

        #expect(ToolEnvelope.isError(envelope))
        #expect(EnvelopeAssertions.failureRetryable(envelope) == false)
        let message = EnvelopeAssertions.failureMessage(envelope) ?? ""
        #expect(!message.contains("supersecret"), "secret value leaked in refusal: \(message)")
    }

    @Test func fileSearchSkipsNonHiddenSecretContentsInCombinedMode() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Non-hidden secret: not caught by `.skipsHiddenFiles`.
        try write("-----BEGIN PRIVATE KEY-----\nMARKER_SECRET\n", to: root.appendingPathComponent("server.pem"))
        try write("MARKER_SECRET in a normal file", to: root.appendingPathComponent("notes.txt"))

        let tool = FileSearchTool(rootPath: root)
        let result = try await ChatExecutionContext.$hostReadOnlyScope.withValue(root) {
            try await tool.execute(argumentsJSON: #"{"pattern":"MARKER_SECRET"}"#)
        }

        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("notes.txt"), "expected the ordinary file to match")
        #expect(!text.contains("server.pem"), "secret file contents leaked via file_search: \(text)")
    }

    @Test func fileSearchReturnsSecretContentsInPlainFolderMode() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("API_TOKEN=plainmode", to: root.appendingPathComponent(".env"))

        // No host-read scope bound => plain folder mode => denylist inert.
        let tool = FileSearchTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"pattern":"TOKEN","path":".env"}"#)

        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("plainmode"))
    }

    // MARK: - file_tree

    @Test func fileTreeOmitsSecretNamesInCombinedMode() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("k", to: root.appendingPathComponent("server.pem"))
        try write("k", to: root.appendingPathComponent("id_rsa"))
        try write("hello", to: root.appendingPathComponent("README.md"))

        let tool = FileTreeTool(rootPath: root)
        let result = try await ChatExecutionContext.$hostReadOnlyScope.withValue(root) {
            try await tool.execute(argumentsJSON: #"{"path":"."}"#)
        }

        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("README.md"))
        #expect(!text.contains("server.pem"), "secret filename disclosed in tree: \(text)")
        #expect(!text.contains("id_rsa"), "secret filename disclosed in tree: \(text)")
    }

    @Test func fileTreeListsSecretNamesInPlainFolderMode() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("k", to: root.appendingPathComponent("server.pem"))

        let tool = FileTreeTool(rootPath: root)
        let result = try await tool.execute(argumentsJSON: #"{"path":"."}"#)

        #expect(ToolEnvelope.isSuccess(result))
        let text = EnvelopeAssertions.successText(result) ?? ""
        #expect(text.contains("server.pem"))
    }
}
