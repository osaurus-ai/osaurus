//
//  SharedArtifactHostFolderFallbackTests.swift
//  osaurusTests
//
//  `resolveSourcePathDetailed` documents "falling back to a basename search",
//  but only the `.sandbox` branch implemented it. In `.hostFolder` mode — the
//  mode you get by picking a folder in the chat input bar — the resolver tried
//  the literal path once and gave up, so an agent that wrote a file into the
//  selected folder and then shared it under a slightly different spelling was
//  told the file did not exist while it sat in the folder (#2245).
//
//  The fallback must not soften the trust boundary, so the escape cases are
//  pinned here alongside the recovery cases.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("SharedArtifact host-folder basename fallback", .serialized)
struct SharedArtifactHostFolderFallbackTests {

    private static func runLocked(_ body: @Sendable (URL) throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-artifact-fallback-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = tmp
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: tmp)
            }
            try body(tmp)
        }
    }

    private static func folderContext(_ root: URL) -> FolderContext {
        FolderContext(
            rootPath: root,
            projectType: .unknown,
            tree: "",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false
        )
    }

    private static func artifactPayload(filename: String, path: String) -> String {
        let metadata: [String: Any] = [
            "filename": filename,
            "mime_type": "text/markdown",
            "has_content": false,
            "path": path,
        ]
        let metaData = try! JSONSerialization.data(withJSONObject: metadata)
        let metaLine = String(data: metaData, encoding: .utf8)!
        return """
            \(SharedArtifact.startMarker)\(metaLine)\(SharedArtifact.endMarker)
            """
    }

    /// Creates `report.md` in the selected folder and shares it under `path`.
    private static func shareOutcome(
        writing filename: String,
        into subdirectory: String?,
        sharedAs path: String,
        root: URL
    ) throws -> Result<SharedArtifact.ProcessingResult, SharedArtifact.ResolutionFailure> {
        var dir = root
        if let subdirectory {
            dir = root.appendingPathComponent(subdirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "# report".write(
            to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)

        return SharedArtifact.processToolResultDetailed(
            artifactPayload(filename: filename, path: path),
            contextId: UUID().uuidString,
            contextType: .chat,
            executionMode: .hostFolder(folderContext(root))
        )
    }

    private func isSuccess(_ outcome: Result<SharedArtifact.ProcessingResult, SharedArtifact.ResolutionFailure>) -> Bool {
        if case .failure = outcome { return false }
        return true
    }

    /// The reported shape: the model repeats the selected folder's own name in
    /// the path. `<root>/Reports/report.md` does not exist; `<root>/report.md` does.
    @Test func recoversWhenModelRepeatsTheFolderName() async throws {
        try await Self.runLocked { tmp in
            let root = tmp.appendingPathComponent("Reports", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let outcome = try Self.shareOutcome(
                writing: "report.md", into: String?.none, sharedAs: "Reports/report.md", root: root)
            #expect(isSuccess(outcome), "folder-name-prefixed path must resolve; got \(outcome)")
        }
    }

    /// A model that writes into a conventional output subdirectory and then
    /// shares the bare filename.
    @Test func recoversFileWrittenIntoOutputSubdirectory() async throws {
        try await Self.runLocked { tmp in
            let root = tmp.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let outcome = try Self.shareOutcome(
                writing: "report.md", into: "output", sharedAs: "report.md", root: root)
            #expect(isSuccess(outcome), "file in output/ must resolve; got \(outcome)")
        }
    }

    /// The plain case must keep working — the fallback runs only after the
    /// literal path misses.
    @Test func exactPathStillResolves() async throws {
        try await Self.runLocked { tmp in
            let root = tmp.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let outcome = try Self.shareOutcome(
                writing: "report.md", into: String?.none, sharedAs: "report.md", root: root)
            #expect(isSuccess(outcome))
        }
    }

    /// Traversal must remain `.pathRejected`. If the fallback recovered the
    /// basename of `../outside.txt` the model would be told the file was merely
    /// missing, and a same-named file inside the root would be shared in its
    /// place — the failure this guard exists to prevent.
    @Test func traversalStaysRejectedEvenWhenBasenameExistsInsideRoot() async throws {
        try await Self.runLocked { tmp in
            let root = tmp.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // A decoy with the same basename living *inside* the root.
            try "decoy".write(
                to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
            try "secret".write(
                to: tmp.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)

            let outcome = SharedArtifact.processToolResultDetailed(
                Self.artifactPayload(filename: "sibling.txt", path: "../outside.txt"),
                contextId: UUID().uuidString,
                contextType: .chat,
                executionMode: .hostFolder(Self.folderContext(root))
            )

            switch outcome {
            case .failure(.pathRejected(let path)):
                #expect(path == "../outside.txt")
            default:
                Issue.record("traversal must stay pathRejected, got \(outcome)")
            }
        }
    }

    /// An absolute path outside the root is a path problem, not a lookup —
    /// it must not fall back to a basename search either.
    @Test func absolutePathOutsideRootStaysRejected() async throws {
        try await Self.runLocked { tmp in
            let root = tmp.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "decoy".write(
                to: root.appendingPathComponent("passwd"), atomically: true, encoding: .utf8)

            let outcome = SharedArtifact.processToolResultDetailed(
                Self.artifactPayload(filename: "passwd", path: "/etc/passwd"),
                contextId: UUID().uuidString,
                contextType: .chat,
                executionMode: .hostFolder(Self.folderContext(root))
            )

            switch outcome {
            case .failure(.pathRejected):
                break
            default:
                Issue.record("absolute outside path must stay pathRejected, got \(outcome)")
            }
        }
    }

    /// A genuinely missing file must still report `fileNotFound`, and the
    /// attempted list must now name every place the resolver looked.
    @Test func missingFileReportsEveryAttemptedLocation() async throws {
        try await Self.runLocked { tmp in
            let root = tmp.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let outcome = SharedArtifact.processToolResultDetailed(
                Self.artifactPayload(filename: "missing.md", path: "missing.md"),
                contextId: UUID().uuidString,
                contextType: .chat,
                executionMode: .hostFolder(Self.folderContext(root))
            )

            switch outcome {
            case .failure(.fileNotFound(let path, let attempted)):
                #expect(path == "missing.md")
                #expect(attempted.first?.hasSuffix("/missing.md") == true)
                #expect(
                    attempted.contains { $0.contains("/output/") },
                    "the output/ probe should be reported so the model can correct itself")
            default:
                Issue.record("expected fileNotFound, got \(outcome)")
            }
        }
    }
}
