//
//  LeanFolderContextTests.swift
//  osaurusTests
//
//  The custom-agent working-directory section: one batch-read line always,
//  and lines that name an optional tool only when that tool is callable.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct LeanFolderContextTests {

    private func folder(manifest: String? = nil) async throws -> (URL, FolderContext) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-lean-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "April total 120\n".write(
            to: root.appendingPathComponent("april.txt"), atomically: true, encoding: .utf8)
        if let manifest {
            try "".write(to: root.appendingPathComponent(manifest), atomically: true, encoding: .utf8)
        }
        return (root, await FolderContextService.shared.buildContext(from: root))
    }

    @Test func documentFolderSkipsCodeCheckAndOptionalToolLines() async throws {
        let (root, context) = try await folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let section = SystemPromptTemplates.leanFolderContext(from: context, toolNames: ["file_read"])
        #expect(section.contains(SystemPromptTemplates.batchReadLine))
        #expect(!section.contains(SystemPromptTemplates.runnableCodeCheckLine))
        #expect(!section.contains("share_artifact"))
        #expect(!section.contains("redact_file"))
        #expect(!section.contains("mode append"))
    }

    @MainActor
    @Test func codeProjectKeepsTheCheckLine() async throws {
        let (root, context) = try await folder(manifest: "Package.swift")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(context.projectType != .unknown)
        let section = SystemPromptTemplates.leanFolderContext(
            from: context, toolNames: ToolRegistry.coreWorkspaceToolNames)
        #expect(section.contains(SystemPromptTemplates.runnableCodeCheckLine))
        #expect(section.contains(SystemPromptTemplates.folderDocumentFormatsLine))
        #expect(section.contains("Writes are confined"))
    }

    /// A read-only folder (Keeper on Downloads) keeps `file_read` and
    /// `file_search` only, so nothing may send it to write or run.
    @Test func readOnlyFolderNamesNoWriteOrRunTool() async throws {
        let (root, context) = try await folder(manifest: "Package.swift")
        defer { try? FileManager.default.removeItem(at: root) }

        let section = SystemPromptTemplates.leanFolderContext(
            from: context, toolNames: ["file_read", "file_search"])
        #expect(section.contains(SystemPromptTemplates.folderDocumentReadFormatsLine))
        #expect(section.contains("read-only"))
        for absent in ["file_write", "file_edit", "shell_run", "Writes are confined", "run an available"] {
            #expect(!section.contains(absent), "\(absent)")
        }
    }

    @Test func optionalToolLinesFollowTheSchema() async throws {
        let (root, context) = try await folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let section = SystemPromptTemplates.leanFolderContext(
            from: context,
            toolNames: ["file_read", "share_artifact", "redact_file", "detect_pii"]
        )
        #expect(section.contains(SystemPromptTemplates.folderShareArtifactLine))
        #expect(section.contains(SystemPromptTemplates.folderRedactionLine))
    }
}
