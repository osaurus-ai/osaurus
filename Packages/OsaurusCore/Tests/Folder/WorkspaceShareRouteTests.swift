//
//  WorkspaceShareRouteTests.swift
//
//  `/workspace/...` sandbox paths for documents and images are served by
//  the host side of the VirtioFS share (`OsaurusPaths.containerWorkspace()`),
//  so `file_read` / `file_write` (and the `sandbox_*` twins) get the same
//  format coverage in the VM as in a trusted folder. Containment must hold
//  (no `..` escape), plain text must stay on the bridge, and a generated
//  document written to the share must be logged relative to the share root
//  so `file_undo` can revert it.
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
        #expect(!WorkspaceShareRoute.servesWrite(extension: "pptx"))
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

    @Test func shareDocumentWriteIsLoggedRelativeToShareRootAndUndoable() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let sessionId = "share-route-undo-\(UUID().uuidString)"
        try await withHome { host in
            try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                let original = Data("not a real xlsx".utf8)
                let target = host.appendingPathComponent("data.xlsx")
                try original.write(to: target)

                let written = try await FileWriteTool.writeDocumentToWorkspaceShare(
                    path: "/workspace/agents/\(Self.agentName)/data.xlsx",
                    home: Self.home,
                    content: "a,b\n1,2\n",
                    mode: "overwrite",
                    dryRun: false
                )
                let envelope = try #require(written)
                #expect(ToolEnvelope.isSuccess(envelope), "\(envelope)")
                let payload = try #require(EnvelopeAssertions.successPayload(envelope))
                let opId = try #require(UUID(uuidString: payload["operation_id"] as? String ?? ""))
                #expect(try Data(contentsOf: target) != original)

                let ops = await FileOperationLog.shared.operations(for: sessionId)
                let entry = try #require(ops.first { $0.id == opId })
                #expect(entry.path == "agents/\(Self.agentName)/data.xlsx")
                #expect(entry.rootPath == WorkspaceShareRoute.shareRoot.standardizedFileURL.path)
                #expect(entry.previousContentEncoding == .utf8)

                _ = try await FileOperationLog.shared.undo(sessionId: sessionId, operationId: opId)
                #expect(try Data(contentsOf: target) == original)
            }
        }
        await FileOperationLog.shared.clear(sessionId: sessionId)
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
