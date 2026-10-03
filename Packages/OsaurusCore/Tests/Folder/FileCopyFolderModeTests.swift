//
//  FileCopyFolderModeTests.swift
//
//  `file_copy` in plain folder mode: a byte-exact host→host duplicate
//  that the file history journal records as one change set (surfaced as
//  `operation_id`) and restores overwritten bytes (any encoding) on undo.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileCopyFolderModeTests {

    private func tmpRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-file-copy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func copy(_ root: URL, _ args: [String: Any]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        let json = try #require(String(data: data, encoding: .utf8))
        return try await FileCopyTool(rootPath: root).execute(argumentsJSON: json)
    }

    @Test func copiesBinaryBytesWithoutASandbox() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0 ..< 4096).map { UInt8($0 % 251) })  // includes NUL and non-UTF-8
        try bytes.write(to: root.appendingPathComponent("blob.bin"))

        let result = try await copy(root, ["source": "blob.bin", "destination": "backup/blob-copy.bin"])
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["kind"] as? String == "file_copy_result")
        #expect(payload["source_area"] as? String == "workspace")
        #expect(payload["destination_area"] as? String == "workspace")
        #expect(payload["overwrote"] as? Bool == false)
        #expect(payload["operation_id"] == nil)  // no capture bound -> no change set
        #expect(try Data(contentsOf: root.appendingPathComponent("backup/blob-copy.bin")) == bytes)
    }

    @Test func overwriteIsRecordedAndUndoRestoresPreviousBytes() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "file-copy-undo-\(UUID().uuidString)"
        let source = Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0x00, 0x10])
        let previous = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFE])
        try source.write(to: root.appendingPathComponent("new.docx"))
        try previous.write(to: root.appendingPathComponent("old.docx"))

        let refused = try await env.run(
            FileCopyTool(rootPath: root),
            FileHistoryTestEnv.json(["source": "new.docx", "destination": "old.docx"]),
            sessionId: sessionId, folder: root)
        #expect(ToolEnvelope.isError(refused))
        #expect(EnvelopeAssertions.failureField(refused) == "overwrite")
        #expect(await env.journal.changeSets(for: sessionId).isEmpty)

        let result = try await env.run(
            FileCopyTool(rootPath: root),
            FileHistoryTestEnv.json(["source": "new.docx", "destination": "old.docx", "overwrite": true]),
            sessionId: sessionId, folder: root)
        #expect(ToolEnvelope.isSuccess(result), "\(result)")
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        #expect(payload["overwrote"] as? Bool == true)
        let opId = try #require(UUID(uuidString: payload["operation_id"] as? String ?? ""))
        #expect(try Data(contentsOf: root.appendingPathComponent("old.docx")) == source)

        let set = try #require(await env.journal.changeSet(id: opId, sessionId: sessionId))
        #expect(set.toolName == "file_copy")
        #expect(set.entries.map(\.path) == ["old.docx"])
        #expect(set.entries.first?.kind == .modified)

        let summary = await env.journal.revert(.set(opId), sessionId: sessionId)
        #expect(summary.isClean, "\(summary)")
        #expect(try Data(contentsOf: root.appendingPathComponent("old.docx")) == previous)
        #expect(try Data(contentsOf: root.appendingPathComponent("new.docx")) == source)
    }

    @Test func undoOfFreshCopyRemovesTheDestination() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "file-copy-fresh-\(UUID().uuidString)"
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let result = try await env.run(
            FileCopyTool(rootPath: root),
            FileHistoryTestEnv.json(["source": "a.txt", "destination": "b.txt"]),
            sessionId: sessionId, folder: root)
        let payload = try #require(EnvelopeAssertions.successPayload(result))
        let opId = try #require(UUID(uuidString: payload["operation_id"] as? String ?? ""))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        let summary = await env.journal.revert(.set(opId), sessionId: sessionId)
        #expect(summary.isClean, "\(summary)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    @Test func rejectsDirectoriesAndSelfCopies() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dir"),
            withIntermediateDirectories: true
        )
        try "x".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let dir = try await copy(root, ["source": "dir", "destination": "dir2"])
        #expect(EnvelopeAssertions.failureField(dir) == "source")
        let same = try await copy(root, ["source": "f.txt", "destination": "./f.txt"])
        #expect(EnvelopeAssertions.failureField(same) == "destination")
        let intoDir = try await copy(root, ["source": "f.txt", "destination": "dir"])
        #expect(EnvelopeAssertions.failureField(intoDir) == "destination")
    }

    @MainActor
    @Test func folderModeExposesFileCopyWithCompactSpec() {
        #expect(ToolRegistry.hostWorkspaceOnlyToolNames.contains("file_copy"))
        #expect(ToolRegistry.compactWorkspaceSpecToolNames.contains("file_copy"))
        #expect(!ToolRegistry.coreWorkspaceToolNames.contains("file_copy"))
        let tool = FileCopyTool()
        #expect(!tool.description.contains("/workspace/"))
        #expect(tool.description.contains("binary-safe"))
    }
}
