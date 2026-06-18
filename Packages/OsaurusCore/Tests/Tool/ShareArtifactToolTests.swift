//
//  ShareArtifactToolTests.swift
//  osaurusTests
//
//  Pins `share_artifact`'s contract:
//   - the schema root stays a plain object with no top-level combinator
//     (issue #1560 — OpenAI/Anthropic 400 on a top-level anyOf/oneOf/etc.),
//   - the path-vs-content argument rules are enforced in `execute()`, and
//   - path mode wins when a model mirrors the file path into `content` (the
//     original regression: the literal path string was written as the
//     artifact body, shipping a broken file instead of copying the real one).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("share_artifact tool", .serialized)
struct ShareArtifactToolTests {

    private static func runLocked(_ body: @Sendable (URL) async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-share-artifact-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = tmp
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: tmp)
            }
            try await body(tmp)
        }
    }

    /// When both `path` and `content` are supplied, path mode must win:
    /// the marker carries `path` (and no `has_content`) and the real file is
    /// copied byte-for-byte rather than the path string being written inline.
    @Test func bothFields_copiesRealFile_notPathString() async throws {
        try await Self.runLocked { tmp in
            let projectRoot = tmp.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

            // Real "image" payload — 512 bytes, far larger than the 8-byte
            // `real.png` path string the buggy path would have written.
            let sourceBytes = Data(repeating: 0xAB, count: 512)
            let sourceURL = projectRoot.appendingPathComponent("real.png")
            try sourceBytes.write(to: sourceURL)

            // Mimic the failing model call: content mirrors the path.
            let args: [String: Any] = [
                "path": "real.png",
                "content": "real.png",
                "description": "a real image",
            ]
            let argsJSON = String(
                data: try JSONSerialization.data(withJSONObject: args),
                encoding: .utf8
            )!

            let envelope = try await ShareArtifactTool().execute(argumentsJSON: argsJSON)
            let payload = try #require(ToolEnvelope.successPayload(envelope) as? [String: Any])
            let markerText = try #require(payload["text"] as? String)

            // Path mode wins: no inline-content flag, path is carried through.
            #expect(markerText.contains("\"has_content\"") == false)
            #expect(markerText.contains("\"path\":\"real.png\""))

            let folderCtx = FolderContext(
                rootPath: projectRoot,
                projectType: .unknown,
                tree: "",
                manifest: nil,
                gitStatus: nil,
                isGitRepo: false
            )
            let outcome = SharedArtifact.processToolResultDetailed(
                markerText,
                contextId: UUID().uuidString,
                contextType: .chat,
                executionMode: .hostFolder(folderCtx)
            )

            switch outcome {
            case .success(let processed):
                // The artifact must be the real file, not the 8-byte path string.
                #expect(processed.artifact.fileSize == sourceBytes.count)
                #expect(processed.artifact.content == nil)
                let copied = try Data(contentsOf: URL(fileURLWithPath: processed.artifact.hostPath))
                #expect(copied == sourceBytes)
            case .failure(let reason):
                Issue.record("expected success, got failure: \(reason)")
            }
        }
    }

    /// Regression for issue #1560: the schema root must stay a plain object.
    /// OpenAI and Anthropic 400 on a top-level `anyOf`/`oneOf`/`allOf`/`enum`/
    /// `not` in a tool's `parameters`/`input_schema`, so the path-vs-content
    /// contract is enforced in `execute()` instead of via a top-level
    /// combinator. This pins the root shape so a future edit can't reintroduce
    /// the provider-breaking schema.
    @Test func schemaRoot_hasNoTopLevelCombinator() {
        guard case .object(let params)? = ShareArtifactTool().parameters else {
            Issue.record("share_artifact parameters missing or not an object")
            return
        }
        #expect(params["type"] == .string("object"))
        for forbidden in ["anyOf", "oneOf", "allOf", "not", "enum", "const"] {
            #expect(
                params[forbidden] == nil,
                "top-level `\(forbidden)` must not appear in share_artifact's schema"
            )
        }
    }

    /// With the top-level `anyOf` removed, a bare `{}` no longer fails schema
    /// preflight — `execute()` must still reject it with an `invalid_args`
    /// envelope so the model gets the same actionable signal.
    @Test func execute_emptyArgs_returnsInvalidArgs() async throws {
        let envelope = try await ShareArtifactTool().execute(argumentsJSON: "{}")
        #expect(EnvelopeAssertions.failureKind(envelope) == "invalid_args")
    }

    /// `content` without `filename` is enforced in the body, not the schema,
    /// and must surface the same `invalid_args` envelope.
    @Test func execute_contentWithoutFilename_returnsInvalidArgs() async throws {
        let envelope = try await ShareArtifactTool().execute(
            argumentsJSON: #"{"content":"hello world"}"#
        )
        #expect(EnvelopeAssertions.failureKind(envelope) == "invalid_args")
    }
}
