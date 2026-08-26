//
//  FileReadNotFoundRecoveryTests.swift
//  osaurusTests
//
//  A wrong path guess on `file_read` should quote the real relative
//  paths of basename matches, so the model's next call is correct
//  instead of spending turns on `file_search`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileReadNotFoundRecoveryTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-read-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func failureMessage(_ output: String) -> String {
        // `ToolEnvelope.failure` writes `message` at the TOP level of the
        // envelope, not nested under an `error` object.
        guard let data = output.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        return dict["message"] as? String ?? ""
    }

    @Test func wrongPathGuess_quotesRealRelativePath() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "content".write(
            to: nested.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        // Model guessed the root when the file lives in docs/.
        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"note.txt"}"#
        )
        #expect(ToolEnvelope.successPayload(output) == nil)
        #expect(failureMessage(output).contains("docs/note.txt"))
    }

    @Test func caseInsensitiveBasename_matches() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(
            to: root.appendingPathComponent("Note.TXT"), atomically: true, encoding: .utf8)

        let output = try await FileReadTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"missing/note.txt"}"#
        )
        #expect(failureMessage(output).contains("Note.TXT"))
    }

    @Test func noMatch_keepsPlainNotFound() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(
            to: root.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)

        // No basename match: the original thrown not-found path is kept.
        await #expect(throws: FolderToolError.self) {
            _ = try await FileReadTool(rootPath: root).execute(
                argumentsJSON: #"{"path":"note.txt"}"#
            )
        }
    }
}
