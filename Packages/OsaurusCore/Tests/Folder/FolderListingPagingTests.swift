//
//  FolderListingPagingTests.swift
//  osaurusTests
//
//  The Folder-chip counterpart of the knowledge-listing fix (0.24.7 report:
//  a markdown notes folder summarised as "300 files" by a small model). The
//  prompt tree stops at 300 files, so the prompt must SAY so — "300 of 350
//  files shown" — and `file_search` must be able to enumerate the rest with
//  `offset`, reporting `total` / `next_offset` the way `list_knowledge` does.
//  350 is deliberately not a multiple of the page size.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FolderListingPagingTests {

    private func makeRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-folder-paging-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seven subfolders of fifty notes: every directory stays under the
    /// per-level extension-grouping threshold (50), so the tree lists files
    /// by name and hits the 300-file ceiling in the seventh folder — the
    /// truncating shape, not the "350 .md files" summary shape.
    private func seedNotes(under root: URL) throws {
        for d in 0..<7 {
            let dir = root.appendingPathComponent(String(format: "topic-%02d", d))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<50 {
                try "# note \(d)-\(f)\n".write(
                    to: dir.appendingPathComponent(String(format: "note-%03d.md", d * 50 + f)),
                    atomically: true, encoding: .utf8)
            }
        }
    }

    private func payload(_ envelope: String) throws -> [String: Any] {
        try #require(ToolEnvelope.successPayload(envelope) as? [String: Any], "\(envelope.prefix(300))")
    }

    private func paths(_ payload: [String: Any]) -> [String] {
        ((payload["entries"] as? [[String: Any]]) ?? []).compactMap { $0["path"] as? String }
    }

    @MainActor
    @Test func treeTruncationIsStatedAndFileSearchPagesTheRest() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNotes(under: root)

        let context = await FolderContextService.shared.buildContext(from: root)
        #expect(context.treeShownFiles == 300)
        #expect(context.treeTotalFiles == 350)
        #expect(context.treeTruncated)

        let rendered = SystemPromptTemplates.folderContext(from: context)
        #expect(rendered.contains("**Tree truncated:** 300 of 350 files shown (50 not listed)"))
        #expect(rendered.contains("`offset`"))
        // The read-only host-workspace framing carries the same line.
        #expect(SystemPromptTemplates.combinedHostRead(from: context).contains("300 of 350 files shown"))
        #expect(SystemPromptTemplates.leanFolderContext(from: context).contains("300 of 350 files shown"))

        let tool = FileSearchTool(rootPath: root)
        let first = try payload(
            try await tool.execute(
                argumentsJSON: #"{"pattern":"*","target":"files","max_results":300}"#))
        #expect(first["match_count"] as? Int == 300)
        #expect(first["total"] as? Int == 350)
        #expect(first["offset"] as? Int == 0)
        #expect(first["next_offset"] as? Int == 300)
        #expect(first["truncated"] as? Bool == false)

        let second = try payload(
            try await tool.execute(
                argumentsJSON: #"{"pattern":"*","target":"files","max_results":300,"offset":300}"#))
        #expect(second["match_count"] as? Int == 50)
        #expect(second["total"] as? Int == 350)
        #expect(second["offset"] as? Int == 300)
        #expect(second["next_offset"] == nil)

        let union = Set(paths(first)).union(paths(second))
        #expect(union.count == 350, "pages must be disjoint and cover every file")
        #expect(Set(paths(first)).isDisjoint(with: paths(second)))

        // A string offset (quantized models) is coerced too; past the end is
        // an explicit overrun, not "no files matched".
        let overrun = try payload(
            try await tool.execute(
                argumentsJSON: #"{"pattern":"*","target":"files","max_results":"300","offset":"350"}"#))
        #expect(overrun["match_count"] as? Int == 0)
        #expect(overrun["total"] as? Int == 350)
        let overrunEnvelope = try await tool.execute(
            argumentsJSON: #"{"pattern":"*","target":"files","offset":350}"#)
        let overrunObject = try #require(
            try JSONSerialization.jsonObject(with: Data(overrunEnvelope.utf8)) as? [String: Any])
        let warnings = try #require(overrunObject["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("past the last match") })
    }

    /// `{"pattern":"","target":"files"}` is how Raptor enumerates a folder at
    /// temperature 0 (live, build #11): files mode treats an empty pattern as
    /// `*` instead of rejecting it into an invalid_args retry loop. Content
    /// mode keeps requiring search text.
    @MainActor
    @Test func filesModeEmptyPatternEnumeratesEveryFile() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNotes(under: root)

        let tool = FileSearchTool(rootPath: root)
        let page = try payload(
            try await tool.execute(argumentsJSON: #"{"pattern":"","target":"files","max_results":300}"#))
        #expect(page["match_count"] as? Int == 300)
        #expect(page["total"] as? Int == 350)
        #expect(page["next_offset"] as? Int == 300)

        let whitespace = try payload(
            try await tool.execute(argumentsJSON: #"{"pattern":"  ","target":"files","max_results":10}"#))
        #expect(whitespace["match_count"] as? Int == 10)
        #expect(whitespace["total"] as? Int == 350)

        let content = try await tool.execute(argumentsJSON: #"{"pattern":"","target":"content"}"#)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        #expect(object["kind"] as? String == "invalid_args")
    }

    /// Default (content) mode with a glob: page 1 falls back to files mode
    /// and advertises `next_offset: 50`; re-issuing exactly that call with
    /// `offset: 50` must land on files page 2 — not on a content-mode
    /// "earlier pages held every match" overrun (live build #12: Raptor
    /// repeated that call twenty times).
    @MainActor
    @Test func contentModeGlobPagesInFilesModeOnEveryPage() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNotes(under: root)
        let tool = FileSearchTool(rootPath: root)

        let first = try payload(try await tool.execute(argumentsJSON: #"{"path":".","pattern":"*"}"#))
        #expect(first["kind"] as? String == "search")
        #expect(first["match_count"] as? Int == 50)
        #expect(first["total"] as? Int == 350)
        #expect(first["next_offset"] as? Int == 50)

        let second = try payload(
            try await tool.execute(argumentsJSON: #"{"path":".","pattern":"*","offset":"50"}"#))
        #expect(second["kind"] as? String == "search")
        #expect(second["match_count"] as? Int == 50)
        #expect(second["offset"] as? Int == 50)
        #expect(second["next_offset"] as? Int == 100)
        #expect(Set(paths(first)).isDisjoint(with: paths(second)))

        // Past the end in content mode with a files fallback: an explicit
        // overrun steer, still files-mode shaped.
        let overrun = try await tool.execute(argumentsJSON: #"{"path":".","pattern":"*","offset":350}"#)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(overrun.utf8)) as? [String: Any])
        let warnings = try #require(object["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("past the last match") })

        // Real content text past its last page keeps the content overrun message.
        let content = try await tool.execute(argumentsJSON: #"{"pattern":"note 0-1","offset":500}"#)
        #expect(content.contains("earlier pages held every match"))
    }

    /// A folder small enough to list in full states nothing about
    /// truncation.
    @MainActor
    @Test func smallFolderHasNoTruncationLine() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<3 {
            try "x".write(to: root.appendingPathComponent("f\(i).md"), atomically: true, encoding: .utf8)
        }
        let context = await FolderContextService.shared.buildContext(from: root)
        #expect(context.treeShownFiles == 3)
        #expect(context.treeTotalFiles == 3)
        #expect(!context.treeTruncated)
        #expect(!SystemPromptTemplates.folderContext(from: context).contains("Tree truncated"))
    }

    /// Content mode pages by skipping `offset` matches and probing one past
    /// the page for a `next_offset` footer, without reading every file for
    /// a total. 12 matches, pages of 5 → 5, 5, 2.
    @Test func contentSearchPagesWithOffset() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for f in 0..<3 {
            let body = (0..<4).map { "note line \(f)-\($0)" }.joined(separator: "\n")
            try body.write(to: root.appendingPathComponent("n\(f).txt"), atomically: true, encoding: .utf8)
        }
        let tool = FileSearchTool(rootPath: root)
        func text(_ args: String) async throws -> String {
            let envelope = try await tool.execute(argumentsJSON: args)
            let payload = try #require(ToolEnvelope.successPayload(envelope) as? [String: Any])
            return try #require(payload["text"] as? String)
        }
        let page1 = try await text(#"{"pattern":"note line","max_results":5}"#)
        #expect(page1.hasPrefix("Found 5 match(es):"))
        #expect(page1.contains("next_offset=5"))
        #expect(!page1.contains("Results truncated"))

        let page2 = try await text(#"{"pattern":"note line","max_results":5,"offset":5}"#)
        #expect(page2.hasPrefix("Found 5 match(es) (offset 5):"))
        #expect(page2.contains("next_offset=10"))

        let page3 = try await text(#"{"pattern":"note line","max_results":5,"offset":10}"#)
        #expect(page3.hasPrefix("Found 2 match(es) (offset 10):"))
        #expect(!page3.contains("next_offset"))

        let lines = [page1, page2, page3].flatMap { page in
            page.components(separatedBy: "\n").filter { $0.contains("note line") }
        }
        #expect(Set(lines).count == 12, "pages must be disjoint and cover every match: \(lines)")

        let overrun = try await text(#"{"pattern":"note line","max_results":5,"offset":12}"#)
        #expect(overrun.contains("offset 12"))
        #expect(overrun.contains("smaller `offset`"))
    }

    /// Below the page size nothing changes: no footer, exact count.
    @Test func contentSearchUnderPageSizeHasNoFooter() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "alpha\nbeta alpha\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let envelope = try await FileSearchTool(rootPath: root).execute(
            argumentsJSON: #"{"pattern":"alpha","max_results":50}"#)
        let payload = try #require(ToolEnvelope.successPayload(envelope) as? [String: Any])
        let text = try #require(payload["text"] as? String)
        #expect(text.hasPrefix("Found 2 match(es):"))
        #expect(!text.contains("next_offset"))
        #expect(payload["warnings"] == nil)
    }
}
