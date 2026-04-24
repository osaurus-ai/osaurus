//
//  SharedArtifactSecurityTests.swift
//  osaurusTests
//
//  Pins the trust boundary around `SharedArtifact.processToolResult` so an
//  agent-controlled filename or path cannot escape the per-context artifacts
//  directory, the sandbox agent dir, or the user-picked host folder. The
//  regression these guard against is a share_artifact call carrying a
//  filename like `../../secrets.md` or a host-mode path like `../outside.txt`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("SharedArtifact trust-boundary hardening", .serialized)
struct SharedArtifactSecurityTests {

    private let tmpRoot: URL
    private let previousOverrideRoot: URL?

    init() throws {
        previousOverrideRoot = OsaurusPaths.overrideRoot
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-artifact-sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = tmpRoot
    }

    // Restore the shared-state override so unrelated tests that run after
    // these don't inherit our temp root. `init`/deinit pair is enforced
    // by the repo PR template checklist.
    //
    // Swift Testing runs `deinit` after each test; the serialized suite
    // keeps concurrent writers off `overrideRoot` during the suite.
    // Using a non-throwing cleanup keeps the compiler happy.
    //
    // swiftlint:disable:next no_direct_standard_out_logs
    func teardown() {
        OsaurusPaths.overrideRoot = previousOverrideRoot
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: - Filename sanitization

    @Test func processToolResult_containsTraversalFilename_whenInline() throws {
        defer { teardown() }

        let contextId = UUID().uuidString
        let payload = Self.makeInlineArtifactTool(
            filename: "../../../etc/passwd",
            body: "should-stay-inside"
        )

        let result = SharedArtifact.processToolResult(
            payload,
            contextId: contextId,
            contextType: .chat,
            executionMode: .none
        )

        let contextDir = OsaurusPaths.contextArtifactsDir(contextId: contextId)
        guard let processed = result else {
            Issue.record("processToolResult unexpectedly returned nil")
            return
        }

        #expect(processed.artifact.filename == "passwd")
        #expect(processed.artifact.hostPath.hasPrefix(contextDir.path + "/"))
        #expect(processed.artifact.hostPath.hasSuffix("/passwd"))
        // The sanitised name must also be reflected in the rewritten tool-result
        // metadata so downstream consumers (plugins, UI) don't see the original
        // traversal string.
        #expect(processed.enrichedToolResult.contains("\"filename\":\"passwd\""))
        #expect(processed.enrichedToolResult.contains("../../../etc/passwd") == false)
    }

    @Test func processToolResult_rejectsFilenameThatReducesToEmpty() throws {
        defer { teardown() }

        let contextId = UUID().uuidString
        let payload = Self.makeInlineArtifactTool(filename: "..", body: "x")

        let result = SharedArtifact.processToolResult(
            payload,
            contextId: contextId,
            contextType: .chat,
            executionMode: .none
        )
        // `..` collapses to a non-usable basename; sanitizer falls back to
        // `artifact` and the file lands safely inside the context dir.
        guard let processed = result else {
            Issue.record("expected fallback filename, got nil")
            return
        }
        let contextDir = OsaurusPaths.contextArtifactsDir(contextId: contextId)
        #expect(processed.artifact.filename == "artifact")
        #expect(processed.artifact.hostPath.hasPrefix(contextDir.path + "/"))
    }

    // MARK: - Host-folder source containment

    @Test func processToolResult_rejectsHostFolderTraversal() throws {
        defer { teardown() }

        let projectRoot = tmpRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        // A file that is a sibling of the project root — reachable only via `..`.
        let outsideFile = tmpRoot.appendingPathComponent("outside.txt")
        try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        let folderCtx = FolderContext(
            rootPath: projectRoot,
            projectType: .unknown,
            tree: "",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false
        )
        let mode: ExecutionMode = .hostFolder(folderCtx)

        let payload = Self.makeFilePathArtifactTool(
            filename: "sibling.txt",
            path: "../outside.txt"
        )

        let result = SharedArtifact.processToolResult(
            payload,
            contextId: UUID().uuidString,
            contextType: .chat,
            executionMode: mode
        )
        #expect(result == nil)
    }

    // MARK: - Helpers

    private static func makeInlineArtifactTool(filename: String, body: String) -> String {
        let metadata: [String: Any] = [
            "filename": filename,
            "mime_type": "text/markdown",
            "has_content": true,
        ]
        let metaData = try! JSONSerialization.data(withJSONObject: metadata)
        let metaLine = String(data: metaData, encoding: .utf8)!
        return """
            \(SharedArtifact.startMarker)\(metaLine)
            \(body)\(SharedArtifact.endMarker)
            """
    }

    private static func makeFilePathArtifactTool(filename: String, path: String) -> String {
        let metadata: [String: Any] = [
            "filename": filename,
            "mime_type": "text/plain",
            "has_content": false,
            "path": path,
        ]
        let metaData = try! JSONSerialization.data(withJSONObject: metadata)
        let metaLine = String(data: metaData, encoding: .utf8)!
        return """
            \(SharedArtifact.startMarker)\(metaLine)\(SharedArtifact.endMarker)
            """
    }
}
