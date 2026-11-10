import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct WorkspaceWriteLineCountTests {
    struct Fixture: Sendable {
        let name: String
        let content: String
        let lines: Int
        let terminated: Bool
    }

    static let fixtures: [Fixture] = [
        .init(name: "empty", content: "", lines: 1, terminated: false),
        .init(name: "unterminated", content: "alpha", lines: 1, terminated: false),
        .init(name: "lf", content: "alpha\nbeta\n", lines: 2, terminated: true),
        .init(name: "no-final-lf", content: "alpha\nbeta", lines: 2, terminated: false),
        .init(name: "blank", content: "\n", lines: 1, terminated: true),
        .init(name: "two-blank", content: "\n\n", lines: 2, terminated: true),
        .init(name: "real-final-blank", content: "alpha\n\n", lines: 2, terminated: true),
        .init(name: "crlf", content: "alpha\r\nbeta\r\n", lines: 2, terminated: true),
        .init(name: "crlf-blank", content: "alpha\r\n\r\nbeta\r\n", lines: 3, terminated: true),
        .init(name: "crlf-unterminated", content: "alpha\r\nbeta", lines: 2, terminated: false),
        .init(name: "cr", content: "alpha\rbeta\r", lines: 2, terminated: true),
        .init(name: "nel", content: "alpha\u{0085}beta\u{0085}", lines: 2, terminated: true),
        .init(name: "unicode-line", content: "alpha\u{2028}beta\u{2028}", lines: 2, terminated: true),
        .init(name: "unicode-paragraph", content: "alpha\u{2029}beta\u{2029}", lines: 2, terminated: true),
        .init(name: "unicode-text", content: "α\n🦖\n", lines: 2, terminated: true),
    ]

    private func root() throws -> URL {
        let result = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-line-count-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func arguments(_ values: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    }

    private func payload(_ response: String) throws -> [String: Any] {
        try #require(ToolEnvelope.successPayload(response) as? [String: Any])
    }

    private func expectMutation(_ result: [String: Any], fixture: Fixture, dryRun: Bool) {
        #expect(result["line_count"] as? Int == fixture.lines)
        #expect(result["dry_run"] as? Bool == dryRun)
        #expect(result["applied"] as? Bool == !dryRun)
        #expect((result["text"] as? String)?.contains("\(fixture.lines) lines") == true)
    }

    private func expectRead(_ result: [String: Any], fixture: Fixture) {
        #expect(result["total_lines"] as? Int == fixture.lines)
        #expect(result["total_lines_exact"] as? Bool == true)
        #expect(result["end_line"] as? Int == fixture.lines)
        #expect(result["ends_with_newline"] as? Bool == fixture.terminated)
    }

    @Test(arguments: fixtures)
    func createPreviewWriteAndReadAgree(_ fixture: Fixture) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("lines.txt")
        let writer = FileWriteTool(rootPath: directory)
        let preview = try payload(
            await writer.execute(
                argumentsJSON: arguments([
                    "path": "lines.txt", "content": fixture.content, "dry_run": true,
                ])
            )
        )
        expectMutation(preview, fixture: fixture, dryRun: true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let written = try payload(
            await writer.execute(
                argumentsJSON: arguments([
                    "path": "lines.txt", "content": fixture.content,
                ])
            )
        )
        expectMutation(written, fixture: fixture, dryRun: false)
        #expect(try Data(contentsOf: file) == Data(fixture.content.utf8))
        let read = try payload(
            await FileReadTool(rootPath: directory).execute(
                argumentsJSON: #"{"path":"lines.txt"}"#
            )
        )
        expectRead(read, fixture: fixture)
    }

    @Test(arguments: fixtures)
    func overwritePreviewKeepsOriginalBytes(_ fixture: Fixture) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("lines.txt")
        let original = Data("original\r\nunchanged\r\n".utf8)
        try original.write(to: file)
        let response = try await FileWriteTool(rootPath: directory).execute(
            argumentsJSON: arguments(["path": "lines.txt", "content": fixture.content, "dry_run": true])
        )
        expectMutation(try payload(response), fixture: fixture, dryRun: true)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test(arguments: fixtures)
    func editPreviewThenApplyAndReadAgree(_ fixture: Fixture) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("lines.txt")
        // The original carries the same newline style as the requested text,
        // so existing edit matching/preservation semantics remain in force.
        let original = "anchor:" + fixture.content
        _ = try payload(
            await FileWriteTool(rootPath: directory).execute(
                argumentsJSON: arguments(["path": "lines.txt", "content": original])
            )
        )
        let editor = FileEditTool(rootPath: directory)
        let preview = try payload(
            await editor.execute(
                argumentsJSON: arguments([
                    "path": "lines.txt", "old_string": original, "new_string": fixture.content, "dry_run": true,
                ])
            )
        )
        expectMutation(preview, fixture: fixture, dryRun: true)
        #expect(try Data(contentsOf: file) == Data(original.utf8))
        let applied = try payload(
            await editor.execute(
                argumentsJSON: arguments([
                    "path": "lines.txt", "old_string": original, "new_string": fixture.content,
                ])
            )
        )
        expectMutation(applied, fixture: fixture, dryRun: false)
        #expect(try Data(contentsOf: file) == Data(fixture.content.utf8))
        let read = try payload(
            await FileReadTool(rootPath: directory).execute(
                argumentsJSON: #"{"path":"lines.txt"}"#
            )
        )
        expectRead(read, fixture: fixture)
    }
}
