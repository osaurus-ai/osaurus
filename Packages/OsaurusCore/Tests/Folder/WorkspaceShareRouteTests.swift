//
//  WorkspaceShareRouteTests.swift
//
//  `/workspace/...` sandbox paths for documents and images are served by
//  the host side of the VirtioFS share (`OsaurusPaths.containerWorkspace()`),
//  so `file_read` / `file_write` (and the `sandbox_*` twins) get the same
//  format coverage in the VM as in a trusted folder. Containment must hold
//  (no `..` escape), plain text must stay on the bridge, and a generated
//  document written to the share must be recorded in the agent's file
//  history so `file_undo` can revert it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct WorkspaceShareRouteTests {

    private static let agentName = "share-route-test-\(UUID().uuidString.prefix(8))"
    private static var home: String { OsaurusPaths.inContainerAgentHome(agentName) }
    private static var hostHome: URL { OsaurusPaths.containerAgentDir(agentName) }

    /// Run `body` against a private storage root so `WorkspaceShareRoute.shareRoot`
    /// is deterministic and cannot race other suites that move
    /// `OsaurusPaths.overrideRoot` (ModelManagerTests et al.). The agent's
    /// host home under that share is created for the body and removed after.
    private func withHome<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T {
        try await StoragePathsTestLock.shared.run {
            let previousRoot = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("share-route-root-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }
            let host = Self.hostHome
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
            return try await body(host)
        }
    }

    private func json(_ args: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test func extensionPolicyDecidesWhatTheShareServes() {
        #expect(WorkspaceShareRoute.servesRead(extension: "pdf"))
        #expect(WorkspaceShareRoute.servesRead(extension: "docx"))
        #expect(WorkspaceShareRoute.servesRead(extension: "xlsx"))
        #expect(WorkspaceShareRoute.servesRead(extension: "png"))
        // Recognised-but-unsupported documents are served so the model gets
        // the honest format envelope rather than raw bytes.
        #expect(WorkspaceShareRoute.servesRead(extension: "xls"))
        #expect(!WorkspaceShareRoute.servesRead(extension: "txt"))
        #expect(!WorkspaceShareRoute.servesRead(extension: "py"))
        #expect(!WorkspaceShareRoute.servesRead(extension: "csv"))

        #expect(WorkspaceShareRoute.servesWrite(extension: "xlsx"))
        #expect(WorkspaceShareRoute.servesWrite(extension: "docx"))
        #expect(WorkspaceShareRoute.servesWrite(extension: "pdf"))
        #expect(WorkspaceShareRoute.servesWrite(extension: "pptx"))
        #expect(!WorkspaceShareRoute.servesWrite(extension: "md"))
    }

    @Test func hostURLStaysInsideTheShare() async throws {
        try await withHome { _ in
            let root = WorkspaceShareRoute.shareRoot.standardizedFileURL.path
            let ok = try WorkspaceShareRoute.hostURL(forSandboxPath: "/workspace/agents/x/report.pdf")
            #expect(ok.standardizedFileURL.path.hasPrefix(root))
            #expect(ok.lastPathComponent == "report.pdf")

            #expect(throws: (any Error).self) {
                _ = try WorkspaceShareRoute.hostURL(forSandboxPath: "/workspace/../../etc/passwd")
            }
            #expect(throws: (any Error).self) {
                _ = try WorkspaceShareRoute.hostURL(forSandboxPath: "/workspace")
            }
            #expect(throws: (any Error).self) {
                _ = try WorkspaceShareRoute.hostURL(forSandboxPath: "/etc/passwd")
            }
            #expect(WorkspaceShareRoute.shareRelativePath(forSandboxPath: "/workspaces/x") == nil)
            #expect(
                WorkspaceShareRoute.shareRelativePath(forSandboxPath: "/workspace/shared/a.pdf") == "shared/a.pdf"
            )
        }
    }

    @Test func resolveForReadHonorsSanitizerAndExtension() async throws {
        try await withHome { _ in
            let home = Self.home
            // Relative to the agent home.
            let relative = WorkspaceShareRoute.resolveForRead(path: "docs/brief.pdf", home: home)
            #expect(relative?.sandboxPath == "\(home)/docs/brief.pdf")
            #expect(relative?.shareRelativePath == "agents/\(Self.agentName)/docs/brief.pdf")
            // Absolute under /workspace/shared.
            let shared = WorkspaceShareRoute.resolveForRead(path: "/workspace/shared/deck.pptx", home: home)
            #expect(shared?.shareRelativePath == "shared/deck.pptx")
            // Text is the bridge's job.
            #expect(WorkspaceShareRoute.resolveForRead(path: "notes.txt", home: home) == nil)
            // Outside the allowed roots: nil (bridge reports the rejection).
            #expect(WorkspaceShareRoute.resolveForRead(path: "/tmp/x.pdf", home: home) == nil)
            #expect(WorkspaceShareRoute.resolveForRead(path: "../../other/x.pdf", home: home) == nil)
        }
    }

    /// A generated document whose sandbox path the host cannot serve must
    /// be refused, never handed to the text bridge (which would write
    /// Markdown bytes into a `.docx`).
    @Test func unreachableDocumentWriteIsRefusedNotBridged() async throws {
        try await withHome { host in
            let result = try await FileWriteTool.writeDocumentToWorkspaceShare(
                path: "../../outside/escape.docx",
                home: Self.home,
                content: "# Nope",
                mode: "overwrite",
                dryRun: false
            )
            let envelope = try #require(result)
            #expect(ToolEnvelope.isError(envelope))
            #expect(EnvelopeAssertions.failureKind(envelope) == "rejected")
            #expect(EnvelopeAssertions.failureField(envelope) == "path")
            #expect(ToolEnvelope.failureMessage(envelope).contains("generated host-side"))
            #expect(!FileManager.default.fileExists(atPath: host.appendingPathComponent("escape.docx").path))
        }
    }

    /// A formatted workbook under `/workspace` is edited in place (the share is a host directory), and
    /// replacing it with `content` is refused, so the sandbox route has no dead end between the two.
    @Test func formattedWorkbookUnderTheShareIsEditedInPlaceNotRegenerated() async throws {
        try await withHome { host in
            let written = try await FileWriteTool.writeDocumentToWorkspaceShare(
                path: "ops.xlsx", home: Self.home, content: "Item,Amount\nRent,1200\n", mode: "overwrite", dryRun: false)
            #expect(ToolEnvelope.isSuccess(try #require(written)))
            let url = host.appendingPathComponent("ops.xlsx")
            let package = try OOXMLPackage(data: try Data(contentsOf: url))
            let sheet = String(decoding: try package.data("xl/worksheets/sheet1.xml"), as: UTF8.self)
            package.setData(
                "xl/worksheets/sheet1.xml",
                Data(sheet.replacingOccurrences(
                    of: "<sheetData", with: #"<cols><col min="1" max="1" width="22" customWidth="1"/></cols><sheetData"#).utf8))
            let formatted = try package.serialize()
            try formatted.write(to: url)

            let tool = SandboxWriteFileTool(agentName: Self.agentName, home: Self.home)
            let refused = try await tool.execute(argumentsJSON: try json(["path": "ops.xlsx", "content": "Item,Amount\nRent,1500\n"]))
            #expect(ToolEnvelope.isError(refused))
            #expect(EnvelopeAssertions.failureKind(refused) == "invalid_args", "a correction, not a turn-ending refusal")
            let message = ToolEnvelope.failureMessage(refused)
            #expect(message.contains("column widths") && message.contains("`sandbox_write_file` `operations`"), Comment(rawValue: message))
            #expect(try Data(contentsOf: url) == formatted, "file untouched")

            let edited = try await tool.execute(argumentsJSON: try json([
                "path": "ops.xlsx", "operations": [["op": "set_cells", "cells": ["B2": 1500, "C2": "=B2*2"]]],
            ]))
            #expect(ToolEnvelope.isSuccess(edited), "sandbox edit failed: \(edited)")
            let after = try Data(contentsOf: url)
            #expect(XLSXPreservation.featuresLostByRegeneration(after) == ["column widths"], "layout kept")
            let afterSheet = String(decoding: try OOXMLPackage(data: after).data("xl/worksheets/sheet1.xml"), as: UTF8.self)
            #expect(afterSheet.contains("<f>B2*2</f>") && afterSheet.contains("1500"), Comment(rawValue: afterSheet))

            // file_edit's share route (combined mode) uses the same editor.
            let viaFileEdit = try await FileEditTool.editDocumentInWorkspaceShare(
                path: "\(Self.home)/ops.xlsx", home: Self.home,
                args: ["operations": [["op": "set_cells", "cells": ["B2": 1600]]]],
                ext: "xlsx", dryRun: false, replaceAll: false, tool: "file_edit")
            #expect(ToolEnvelope.isSuccess(viaFileEdit), "file_edit share edit failed: \(viaFileEdit)")
            #expect(XLSXPreservation.featuresLostByRegeneration(try Data(contentsOf: url)) == ["column widths"])

            let escape = try await FileEditTool.editDocumentInWorkspaceShare(
                path: "../../outside/ops.xlsx", home: Self.home,
                args: ["operations": [["op": "set_cells", "cells": ["B2": 1]]]],
                ext: "xlsx", dryRun: false, replaceAll: false, tool: "file_edit")
            #expect(EnvelopeAssertions.failureKind(escape) == "rejected")
        }
    }

    @Test func documentUnderTheShareIsReadHostSide() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        try await withHome { host in
            // Generate a real .docx in the agent home via the share writer.
            let written = try await FileWriteTool.writeDocumentToWorkspaceShare(
                path: "brief.docx",
                home: Self.home,
                content: "# Brief\n\nThe quarterly target is 42 units.\n",
                mode: "overwrite",
                dryRun: false
            )
            let writeEnvelope = try #require(written)
            #expect(ToolEnvelope.isSuccess(writeEnvelope), "share write failed: \(writeEnvelope)")
            let writePayload = try #require(EnvelopeAssertions.successPayload(writeEnvelope))
            #expect(writePayload["kind"] as? String == "document_write_result")
            #expect(writePayload["path"] as? String == "\(Self.home)/brief.docx")
            #expect(writePayload["area"] as? String == "sandbox")
            #expect(FileManager.default.fileExists(atPath: host.appendingPathComponent("brief.docx").path))

            // Read it back through the share route with a relative path.
            let read = try await FileReadTool.readFromWorkspaceShare(
                path: "brief.docx",
                home: Self.home,
                args: ["path": "brief.docx"]
            )
            let readEnvelope = try #require(read)
            #expect(ToolEnvelope.isSuccess(readEnvelope), "share read failed: \(readEnvelope)")
            let payload = try #require(EnvelopeAssertions.successPayload(readEnvelope))
            #expect(payload["format"] as? String == "docx")
            #expect(payload["source"] as? String == "extracted_text")
            #expect(payload["path"] as? String == "\(Self.home)/brief.docx")
            #expect((payload["text"] as? String ?? "").contains("quarterly target is 42"))

            // Text file: not served here (nil -> bridge).
            try "hello".write(to: host.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let text = try await FileReadTool.readFromWorkspaceShare(
                path: "a.txt",
                home: Self.home,
                args: ["path": "a.txt"]
            )
            #expect(text == nil)
            // Missing document: nil -> bridge reports not-found.
            let missing = try await FileReadTool.readFromWorkspaceShare(
                path: "nope.pdf",
                home: Self.home,
                args: ["path": "nope.pdf"]
            )
            #expect(missing == nil)
        }
    }

    @Test func shareDocumentWriteIsRecordedInAgentHomeAndUndoable() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let sessionId = "share-route-undo-\(UUID().uuidString)"
        try await withHome { host in
            let env = try FileHistoryTestEnv.make { name, kind in
                kind == .agentHome
                    ? OsaurusPaths.containerAgentDir(name) : WorkspaceShareRoute.shareRoot
            }
            defer { env.cleanup() }
            let original = Data("not a real xlsx".utf8)
            let target = host.appendingPathComponent("data.xlsx")
            try original.write(to: target)

            let token = await env.journal.beginCapture(
                sessionId: sessionId, toolName: "file_write",
                targets: [.init(kind: .agentHome, rootId: Self.agentName, declaredPaths: ["data.xlsx"])])
            #expect(token.isFullyTracked)
            let written = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                try await ChatExecutionContext.$currentChangeSetId.withValue(token.setId) {
                    try await FileWriteTool.writeDocumentToWorkspaceShare(
                        path: "/workspace/agents/\(Self.agentName)/data.xlsx",
                        home: Self.home,
                        content: "a,b\n1,2\n",
                        mode: "overwrite",
                        dryRun: false
                    )
                }
            }
            _ = await env.journal.endCapture(token)
            let envelope = try #require(written)
            #expect(ToolEnvelope.isSuccess(envelope), "\(envelope)")
            let payload = try #require(EnvelopeAssertions.successPayload(envelope))
            #expect(payload["operation_id"] as? String == token.setId.uuidString)
            #expect(try Data(contentsOf: target) != original)

            let set = try #require(await env.journal.changeSet(id: token.setId, sessionId: sessionId))
            #expect(set.entries.map(\.path) == ["data.xlsx"])
            #expect(set.entries.first?.rootKind == .agentHome)

            let summary = await env.journal.revert(.set(token.setId), sessionId: sessionId)
            #expect(summary.isClean, "\(summary)")
            #expect(try Data(contentsOf: target) == original)
        }
    }

    @Test func shareDryRunAndAppendFollowDocumentSemantics() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        try await withHome { host in
            let preview = try await FileWriteTool.writeDocumentToWorkspaceShare(
                path: "out.pdf",
                home: Self.home,
                content: "# T\n\nbody",
                mode: "overwrite",
                dryRun: true
            )
            let previewEnvelope = try #require(preview)
            let payload = try #require(EnvelopeAssertions.successPayload(previewEnvelope))
            #expect(payload["kind"] as? String == "document_write_preview")
            #expect(!FileManager.default.fileExists(atPath: host.appendingPathComponent("out.pdf").path))

            let append = try await FileWriteTool.writeDocumentToWorkspaceShare(
                path: "out.pdf",
                home: Self.home,
                content: "more",
                mode: "append",
                dryRun: false
            )
            let appendEnvelope = try #require(append)
            #expect(ToolEnvelope.isError(appendEnvelope))
            #expect(EnvelopeAssertions.failureField(appendEnvelope) == "mode")

            // Non-document extension: nil so the caller uses the text bridge.
            let text = try await FileWriteTool.writeDocumentToWorkspaceShare(
                path: "out.md",
                home: Self.home,
                content: "x",
                mode: "overwrite",
                dryRun: false
            )
            #expect(text == nil)
        }
    }
}
