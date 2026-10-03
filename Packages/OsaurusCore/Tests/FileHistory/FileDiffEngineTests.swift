//
//  FileDiffEngineTests.swift
//  osaurusTests
//
//  Recorded before/after pairs render as reviewable diffs: collapsed text
//  hunks, structural document diffs (Word paragraphs, spreadsheet cells),
//  images, binaries, and folders.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileDiffEngineTests {

    private let session = "diff-session"

    private func tmpRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write `args` through `file_write` under capture; return the entry for `path`.
    private func writeEntry(
        _ env: FileHistoryTestEnv, root: URL, _ args: [String: Any]
    ) async throws -> FileChangeEntry {
        let result = try await env.run(
            FileWriteTool(rootPath: root), FileHistoryTestEnv.json(args), sessionId: session, folder: root)
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let id = try #require(UUID(uuidString: EnvelopeAssertions.successPayload(result)?["operation_id"] as? String ?? ""))
        let set = try #require(await env.journal.changeSet(id: id, sessionId: session))
        return try #require(set.entries.first { $0.path == args["path"] as? String })
    }

    private func diff(_ env: FileHistoryTestEnv, _ entry: FileChangeEntry) async -> FileDiffContent {
        await FileDiffEngine.diff(key: entry.pathKey, before: entry.before, after: entry.after, journal: env.journal)
    }

    @Test func textDiffCollapsesUnchangedRuns() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = (1...40).map { "line \($0)" }.joined(separator: "\n")
        try original.write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let changed = original.replacingOccurrences(of: "line 20\n", with: "line twenty\n")

        let entry = try await writeEntry(env, root: root, ["path": "a.txt", "content": changed])
        let content = await diff(env, entry)
        guard case .text(let fileDiff) = content.body else {
            Issue.record("expected text, got \(content.body)")
            return
        }
        #expect(fileDiff.addedCount == 1 && fileDiff.removedCount == 1)
        #expect(fileDiff.lines.contains { $0.kind == .meta && $0.text.contains("unchanged lines") })
        #expect(fileDiff.lines.count < 15)
        #expect(content.beforeURL != nil && content.afterURL != nil)
    }

    @Test func newFileDiffsAsAllAdded() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try await writeEntry(env, root: root, ["path": "n.md", "content": "# Title\nBody"])
        let content = await diff(env, entry)
        guard case .text(let fileDiff) = content.body else {
            Issue.record("expected text")
            return
        }
        #expect(fileDiff.addedCount == 2 && fileDiff.removedCount == 0)
        #expect(content.beforeURL == nil)
    }

    @Test func wordDocumentDiffsByParagraph() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await writeEntry(
            env, root: root, ["path": "brief.docx", "content": "# Brief\n\nThe target is 40.\n\nKeep this line."])
        let entry = try await writeEntry(
            env, root: root, ["path": "brief.docx", "content": "# Brief\n\nThe target is 42.\n\nKeep this line."])

        let content = await diff(env, entry)
        #expect(content.caption == "Showing changed paragraphs")
        guard case .text(let fileDiff) = content.body else {
            Issue.record("expected structural text diff, got \(content.body)")
            return
        }
        #expect(fileDiff.lines.contains { $0.kind == .removed && $0.text.contains("40") })
        #expect(fileDiff.lines.contains { $0.kind == .added && $0.text.contains("42") })
        #expect(!fileDiff.lines.contains { $0.kind != .context && $0.text.contains("Keep this line") })
    }

    @Test func spreadsheetDiffsByCell() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await writeEntry(env, root: root, ["path": "q.xlsx", "content": "name,amount\nA,10\nB,20\n"])
        let entry = try await writeEntry(env, root: root, ["path": "q.xlsx", "content": "name,amount\nA,10\nB,25\n"])

        let content = await diff(env, entry)
        #expect(content.caption == "Showing changed cells")
        guard case .text(let fileDiff) = content.body else {
            Issue.record("expected cell diff, got \(content.body)")
            return
        }
        #expect(fileDiff.lines.contains { $0.kind == .removed && $0.text.hasPrefix("B3: 20") })
        #expect(fileDiff.lines.contains { $0.kind == .added && $0.text.hasPrefix("B3: 25") })
        #expect(fileDiff.addedCount == 1 && fileDiff.removedCount == 1)
    }

    @Test func imagesBinariesAndFoldersGetTheirOwnBodies() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let home = env.agentHome
        let token = await env.journal.beginCapture(
            sessionId: session, toolName: "sandbox_exec",
            targets: [.init(kind: .agentHome, rootId: FileHistoryTestEnv.agent, declaredPaths: nil)])
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2]).write(to: home.appendingPathComponent("pic.png"))
        try Data([0, 1, 2, 3, 0xFF]).write(to: home.appendingPathComponent("blob.bin"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let set = try #require(await env.journal.endCapture(token))

        func body(_ path: String) async throws -> FileDiffContent.Body {
            let entry = try #require(set.entries.first { $0.path == path })
            return await diff(env, entry).body
        }
        #expect(try await body("pic.png") == .image)
        #expect(try await body("blob.bin") == .binary)
        #expect(try await body("dir") == .directory)
    }

    @Test func smallDiffsAreNotFolded() {
        let diff = FileDiffEngine.textDiff(old: "x\ny\nw", new: "x\nz\nw", path: "a", existed: true)
        #expect(diff.lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(diff.lines.map(\.text) == ["x", "y", "z", "w"])
        #expect(diff.addedCount == 1 && diff.removedCount == 1 && !diff.truncated)
    }

    /// The tool-result helper capped on total lines, so an edit past line
    /// ~80 of a long file showed "truncated" with no visible change. The
    /// panel diff folds context first and only budgets changed lines.
    @Test func deepEditInLongFileIsVisible() {
        let old = (1...5000).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 4800\n", with: "line 4800 edited\n")
        let diff = FileDiffEngine.textDiff(old: old, new: new, path: "big.txt", existed: true)
        #expect(!diff.truncated)
        #expect(diff.addedCount == 1 && diff.removedCount == 1)
        #expect(diff.lines.contains { $0.kind == .removed && $0.text == "line 4800" })
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "line 4800 edited" })
        #expect(diff.lines.filter { $0.kind == .meta }.count == 2)
        #expect(diff.lines.count < 12)
    }

    @Test func hugeRewriteIsCappedOnChangedLinesOnly() {
        let old = (1...4000).map { "a \($0)" }.joined(separator: "\n")
        let new = (1...4000).map { "b \($0)" }.joined(separator: "\n")
        let diff = FileDiffEngine.textDiff(old: old, new: new, path: "r.txt", existed: true)
        #expect(diff.truncated)
        #expect(diff.addedCount == 4000 && diff.removedCount == 4000)
        #expect(diff.lines.count <= FileDiffEngine.maxChangedLines + 2)
    }

    @Test func movedBlockDiffsMinimally() {
        let old = ["a", "b", "c", "d", "e", "f"].joined(separator: "\n")
        let new = ["a", "c", "d", "e", "b", "f"].joined(separator: "\n")
        let diff = FileDiffEngine.textDiff(old: old, new: new, path: "m.txt", existed: true)
        #expect(diff.addedCount == 1 && diff.removedCount == 1)
    }

    @Test func wordHighlightsMarkOnlyTheChangedWords() {
        let lines = [
            FileDiff.Line(kind: .removed, text: "The target is 40 units."),
            FileDiff.Line(kind: .added, text: "The target is 42 units."),
        ]
        let ranges = FileDiffEngine.wordHighlights(for: lines)
        #expect(ranges[0]?.map { String(lines[0].text[$0]) } == ["40"])
        #expect(ranges[1]?.map { String(lines[1].text[$0]) } == ["42"])

        // Mostly-different lines get no confetti.
        let unrelated = [
            FileDiff.Line(kind: .removed, text: "alpha beta gamma"),
            FileDiff.Line(kind: .added, text: "one two three four"),
        ]
        #expect(FileDiffEngine.wordHighlights(for: unrelated).isEmpty)
    }
}
