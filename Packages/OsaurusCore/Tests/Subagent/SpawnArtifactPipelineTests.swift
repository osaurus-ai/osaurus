//
//  SpawnArtifactPipelineTests.swift
//  OsaurusCoreTests
//
//  Typed artifact pipeline contract for spawned workers:
//
//   * `share_artifact` is cancellation-audited and exposed to spawned
//     workers (`canExposeToSpawnedOperation`), and rides the declarative
//     worker baseline (`ToolRegistry.spawnedWorkerBaselineToolNames`).
//   * The worker-side intercept (`SpawnArtifactCollector
//     .processWorkerShareArtifact`) processes the marker blob at worker
//     time into the PARENT session's artifact store, deposits the typed
//     `SharedArtifact`, and hands the worker model ONLY a compact
//     confirmation — no marker bytes in the child transcript.
//   * The parent drains deposits exactly once per session.
//   * Path-mode shares (no worker execution mode) fail with the standard
//     model-readable envelope steering the model to `content`+`filename`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SpawnArtifactPipelineTests {

    @Test("share_artifact is audited for spawned workers and in the worker baseline")
    @MainActor
    func shareArtifactIsExposedToWorkers() {
        let tool = ShareArtifactTool()
        #expect(tool.canExposeToSpawnedOperation)
        #expect(
            tool.spawnedOperationCancellationSupport(argumentsJSON: "{}") == .cooperative
        )
        #expect(ToolRegistry.spawnedWorkerBaselineToolNames.contains("share_artifact"))
        // The spawn-safety gate passes it through to child schemas.
        let specs = ToolRegistry.shared.specsForSpawnedOperations(forTools: ["share_artifact"])
        #expect(specs.map(\.function.name) == ["share_artifact"])
    }

    @Test("content-mode worker share deposits a typed artifact and returns a compact confirmation")
    func workerContentShareDepositsAndConfirms() async throws {
        let parentSessionId = "spawn-artifact-test-\(UUID().uuidString)"
        SpawnArtifactCollector._resetForTesting()
        defer { SpawnArtifactCollector._resetForTesting() }

        let raw = try await ShareArtifactTool().execute(
            argumentsJSON: #"""
                {"content": "# Report\nhello from the worker",
                 "filename": "report.md",
                 "description": "worker test artifact"}
                """#
        )
        let outcome = SpawnArtifactCollector.processWorkerShareArtifact(
            rawResult: raw,
            parentSessionId: parentSessionId
        )

        // Worker model sees a compact success confirmation, never markers.
        #expect(outcome.sharedFilename == "report.md")
        #expect(!ToolEnvelope.isError(outcome.modelResult))
        #expect(!outcome.modelResult.contains("SHARED_ARTIFACT_START"))
        #expect(outcome.modelResult.contains("report.md"))

        // The typed artifact is drained exactly once, keyed by the parent
        // session, with the file on disk in the parent's artifact store.
        let drained = SpawnArtifactCollector.drain(sessionId: parentSessionId)
        #expect(drained.count == 1)
        let artifact = try #require(drained.first)
        #expect(artifact.filename == "report.md")
        #expect(artifact.contextId == parentSessionId)
        #expect(artifact.content?.contains("hello from the worker") == true)
        #expect(FileManager.default.fileExists(atPath: artifact.hostPath))

        // Drain is destructive: a second drain is empty.
        #expect(SpawnArtifactCollector.drain(sessionId: parentSessionId).isEmpty)
    }

    @Test("path-mode worker share fails with the inline-content hint and deposits nothing")
    func workerPathShareFailsWithHint() async throws {
        let parentSessionId = "spawn-artifact-path-\(UUID().uuidString)"
        SpawnArtifactCollector._resetForTesting()
        defer { SpawnArtifactCollector._resetForTesting() }

        let raw = try await ShareArtifactTool().execute(
            argumentsJSON: #"{"path": "output/chart.svg"}"#
        )
        let outcome = SpawnArtifactCollector.processWorkerShareArtifact(
            rawResult: raw,
            parentSessionId: parentSessionId
        )

        #expect(outcome.sharedFilename == nil)
        #expect(ToolEnvelope.isError(outcome.modelResult))
        // The `.none`-mode hint steers the worker to inline content.
        #expect(outcome.modelResult.contains("content"))
        #expect(SpawnArtifactCollector.drain(sessionId: parentSessionId).isEmpty)
    }

    @Test("non-success tool results pass through the intercept unchanged")
    func workerShareFailurePassesThrough() async throws {
        let parentSessionId = "spawn-artifact-fail-\(UUID().uuidString)"
        SpawnArtifactCollector._resetForTesting()
        defer { SpawnArtifactCollector._resetForTesting() }

        // Invalid args: neither path nor content.
        let raw = try await ShareArtifactTool().execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(raw))

        let outcome = SpawnArtifactCollector.processWorkerShareArtifact(
            rawResult: raw,
            parentSessionId: parentSessionId
        )
        #expect(outcome.modelResult == raw)
        #expect(outcome.sharedFilename == nil)
        #expect(SpawnArtifactCollector.drain(sessionId: parentSessionId).isEmpty)
    }

    @Test("deposits are isolated per parent session")
    func depositsAreSessionScoped() {
        SpawnArtifactCollector._resetForTesting()
        defer { SpawnArtifactCollector._resetForTesting() }

        let a = "session-a-\(UUID().uuidString)"
        let b = "session-b-\(UUID().uuidString)"
        let artifact = SharedArtifact(
            contextId: a,
            contextType: .chat,
            filename: "a.txt",
            mimeType: "text/plain",
            fileSize: 1,
            hostPath: "/tmp/a.txt"
        )
        SpawnArtifactCollector.deposit(artifact, sessionId: a)
        #expect(SpawnArtifactCollector.drain(sessionId: b).isEmpty)
        #expect(SpawnArtifactCollector.drain(sessionId: a).count == 1)
    }

    // MARK: - Non-chat parent hygiene (HTTP / plugin host)

    /// Wait (bounded) for the collector's detached file-deletion task.
    private func waitForRemoval(of path: String) async -> Bool {
        for _ in 0 ..< 100 {
            if !FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return !FileManager.default.fileExists(atPath: path)
    }

    private func makeTempFile() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-artifact-discard-\(UUID().uuidString).txt")
        try Data("orphan candidate".utf8).write(to: url)
        return url.path
    }

    private func makeArtifact(sessionId: String, hostPath: String) -> SharedArtifact {
        SharedArtifact(
            contextId: sessionId,
            contextType: .chat,
            filename: (hostPath as NSString).lastPathComponent,
            mimeType: "text/plain",
            fileSize: 1,
            hostPath: hostPath
        )
    }

    @Test("discard empties the bucket AND deletes the store files (HTTP / plugin drain)")
    func discardDeletesBucketAndFiles() async throws {
        SpawnArtifactCollector._resetForTesting()
        defer { SpawnArtifactCollector._resetForTesting() }

        let sessionId = "http-run-\(UUID().uuidString)"
        let path = try makeTempFile()
        SpawnArtifactCollector.deposit(
            makeArtifact(sessionId: sessionId, hostPath: path),
            sessionId: sessionId
        )

        SpawnArtifactCollector.discard(sessionId: sessionId)

        // The non-chat parent (HTTP `/agents/{id}/run`, plugin host loop)
        // leaves neither an undrained bucket nor an orphaned file.
        #expect(SpawnArtifactCollector.drain(sessionId: sessionId).isEmpty)
        #expect(await waitForRemoval(of: path))
    }

    @Test("a full bucket drops the overflow deposit AND deletes its file")
    func overflowDropDeletesTheFile() async throws {
        SpawnArtifactCollector._resetForTesting()
        defer { SpawnArtifactCollector._resetForTesting() }

        let sessionId = "overflow-\(UUID().uuidString)"
        for _ in 0 ..< 32 {
            SpawnArtifactCollector.deposit(
                makeArtifact(sessionId: sessionId, hostPath: ""),
                sessionId: sessionId
            )
        }

        let path = try makeTempFile()
        SpawnArtifactCollector.deposit(
            makeArtifact(sessionId: sessionId, hostPath: path),
            sessionId: sessionId
        )

        // The overflow deposit never joins the bucket, and its
        // already-written store file must not linger.
        #expect(SpawnArtifactCollector.drain(sessionId: sessionId).count == 32)
        #expect(await waitForRemoval(of: path))
    }

    @Test("promotion without an owner turn leaves the bucket for the next drain point")
    @MainActor
    func promotionWithoutAnOwnerTurnKeepsTheBucket() async {
        SpawnArtifactCollector._resetForTesting()
        defer { SpawnArtifactCollector._resetForTesting() }

        let session = ChatSession()
        let id = UUID()
        session.sessionId = id
        let artifact = makeArtifact(sessionId: id.uuidString, hostPath: "/tmp/keep.txt")
        SpawnArtifactCollector.deposit(artifact, sessionId: id.uuidString)

        // No assistant turn yet (background report-back racing a fresh
        // thread): the artifacts must survive in the collector instead of
        // being silently dropped with orphaned files.
        await session.promoteWorkerSharedArtifacts()
        #expect(session.turns.allSatisfy { $0.sharedArtifacts.isEmpty })

        // Once an assistant turn exists, the same drain attaches them.
        session.turns = [
            ChatTurn(role: .user, content: "make me a file"),
            ChatTurn(role: .assistant, content: "done"),
        ]
        await session.promoteWorkerSharedArtifacts()
        #expect(session.turns.last?.sharedArtifacts.count == 1)
        #expect(SpawnArtifactCollector.drain(sessionId: id.uuidString).isEmpty)
    }
}
