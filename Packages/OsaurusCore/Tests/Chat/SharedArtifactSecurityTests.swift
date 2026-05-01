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

    /// Cross-suite serialization gate. Other suites that also touch
    /// `OsaurusPaths.overrideRoot` (e.g. `AttachmentSpilloverTests`)
    /// race with us if they run concurrently — `@Suite(.serialized)`
    /// only guarantees serialization within a single suite. Wrap
    /// every test body with the same lock used by those tests so
    /// the override + the assertions read a consistent root.
    private static func runLocked(_ body: @Sendable (URL) throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-artifact-sec-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = tmp
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: tmp)
            }
            try body(tmp)
        }
    }

    // MARK: - Filename sanitization

    @Test func processToolResult_containsTraversalFilename_whenInline() async throws {
        try await Self.runLocked { _ in
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
    }

    @Test func processToolResult_rejectsFilenameThatReducesToEmpty() async throws {
        try await Self.runLocked { _ in
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
    }

    // MARK: - Host-folder source containment

    @Test func processToolResult_rejectsHostFolderTraversal() async throws {
        try await Self.runLocked { tmp in
            let projectRoot = tmp.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            // A file that is a sibling of the project root — reachable only via `..`.
            let outsideFile = tmp.appendingPathComponent("outside.txt")
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
    }

    // MARK: - Differentiated failure modes

    /// `.fileNotFound` should ride a candidate-paths list so the model
    /// knows where the resolver looked. Without this list the agent
    /// can't tell the difference between "wrong path" and "wrong
    /// directory" — the gpt-5.2 julia_fractal regression.
    @Test func processToolResultDetailed_fileNotFound_carriesAttempted() async throws {
        try await Self.runLocked { tmp in
            let projectRoot = tmp.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let folderCtx = FolderContext(
                rootPath: projectRoot,
                projectType: .unknown,
                tree: "",
                manifest: nil,
                gitStatus: nil,
                isGitRepo: false
            )
            let payload = Self.makeFilePathArtifactTool(
                filename: "missing.png",
                path: "missing.png"
            )

            let outcome = SharedArtifact.processToolResultDetailed(
                payload,
                contextId: UUID().uuidString,
                contextType: .chat,
                executionMode: .hostFolder(folderCtx)
            )

            switch outcome {
            case .failure(.fileNotFound(let path, let attempted)):
                #expect(path == "missing.png")
                #expect(!attempted.isEmpty)
                #expect(attempted.first?.contains("missing.png") == true)
            default:
                Issue.record("expected fileNotFound, got \(outcome)")
            }
        }
    }

    /// Host-folder traversal should surface as `.pathRejected`, not
    /// `.fileNotFound` — the model needs to know the path itself was
    /// the problem, not the existence check.
    @Test func processToolResultDetailed_pathRejected_onTraversal() async throws {
        try await Self.runLocked { tmp in
            let projectRoot = tmp.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let outsideFile = tmp.appendingPathComponent("outside.txt")
            try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)

            let folderCtx = FolderContext(
                rootPath: projectRoot,
                projectType: .unknown,
                tree: "",
                manifest: nil,
                gitStatus: nil,
                isGitRepo: false
            )
            let payload = Self.makeFilePathArtifactTool(
                filename: "sibling.txt",
                path: "../outside.txt"
            )

            let outcome = SharedArtifact.processToolResultDetailed(
                payload,
                contextId: UUID().uuidString,
                contextType: .chat,
                executionMode: .hostFolder(folderCtx)
            )
            switch outcome {
            case .failure(.pathRejected(let path)):
                #expect(path == "../outside.txt")
            default:
                Issue.record("expected pathRejected, got \(outcome)")
            }
        }
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
