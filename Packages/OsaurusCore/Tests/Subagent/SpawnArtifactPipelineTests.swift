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

// MARK: - Delegated-run artifact pass-through

/// A delegated agent spawn runs the child as a REAL chat session, so its
/// `share_artifact` results land in the CHILD session's store and transcript
/// — not in the worker intercept. After any terminal state the dispatcher
/// harvests the child's artifacts, adopts them into the PARENT session's
/// store, and deposits them for the parent's ordinary post-spawn drain.
@Suite(.serialized)
struct DelegatedArtifactPassThroughTests {

    /// Run `share_artifact` with inline content and process it into
    /// `contextId`'s artifact store, returning the typed artifact and the
    /// enriched envelope exactly as the child chat loop persists it.
    private func makeChildArtifact(
        contextId: String,
        filename: String,
        content: String
    ) async throws -> (artifact: SharedArtifact, enrichedEnvelope: String) {
        let raw = try await ShareArtifactTool().execute(
            argumentsJSON: """
                {"content": \(String(reflecting: content)), "filename": \(String(reflecting: filename))}
                """
        )
        let payload = try #require(ToolEnvelope.successPayload(raw) as? [String: Any])
        let markerText = try #require(payload["text"] as? String)
        let processed = try SharedArtifact.processToolResultDetailed(
            markerText,
            contextId: contextId,
            contextType: .chat,
            executionMode: .none
        ).get()
        let envelope = ToolEnvelope.success(
            tool: "share_artifact",
            text: processed.enrichedToolResult
        )
        return (processed.artifact, envelope)
    }

    private func removeContextDir(_ contextId: String) {
        try? FileManager.default.removeItem(
            at: OsaurusPaths.contextArtifactsDir(contextId: contextId)
        )
    }

    @Test("harvest collects typed attachments and enriched tool results, deduped by backing file")
    func harvestCollectsAndDedupes() async throws {
        let childId = "delegated-harvest-\(UUID().uuidString)"
        defer { removeContextDir(childId) }
        let made = try await makeChildArtifact(
            contextId: childId, filename: "game.html", content: "<html>hi</html>"
        )

        var toolTurn = ChatTurnData(role: .tool, content: "")
        toolTurn.toolResults = [
            "call_1": made.enrichedEnvelope,
            // Non-artifact tool results are ignored.
            "call_2": ToolEnvelope.success(tool: "get_current_time", text: "noon"),
        ]
        var assistantTurn = ChatTurnData(role: .assistant, content: "done")
        // The same artifact ALSO promoted as a typed attachment (the
        // generated-media path) must not adopt twice.
        assistantTurn.sharedArtifacts = [made.artifact]

        let harvested = AgentDelegationDispatcher.harvestArtifacts(
            from: [toolTurn, assistantTurn]
        )
        #expect(harvested.count == 1)
        #expect(harvested.first?.filename == "game.html")
    }

    @Test("adoption copies the file into the parent store and rekeys the context")
    func adoptionRekeysIntoParentStore() async throws {
        let childId = "delegated-child-\(UUID().uuidString)"
        let parentId = "delegated-parent-\(UUID().uuidString)"
        defer {
            removeContextDir(childId)
            removeContextDir(parentId)
        }
        let made = try await makeChildArtifact(
            contextId: childId, filename: "game.html", content: "<html>rolling ball</html>"
        )

        let adopted = try #require(
            SharedArtifact.adoptIntoContext(
                made.artifact,
                contextId: parentId,
                sourceRootContextId: childId
            )
        )
        #expect(adopted.contextId == parentId)
        #expect(adopted.filename == "game.html")
        let parentDir = OsaurusPaths.contextArtifactsDir(contextId: parentId).path
        #expect(adopted.hostPath.hasPrefix(parentDir + "/"))
        #expect(FileManager.default.fileExists(atPath: adopted.hostPath))
        // The child's own copy survives — its session card must keep working.
        #expect(FileManager.default.fileExists(atPath: made.artifact.hostPath))
    }

    @Test("adoption refuses out-of-store host paths; inline content still passes safely")
    func adoptionRefusesOutOfStorePaths() async throws {
        let childId = "delegated-escape-\(UUID().uuidString)"
        let parentId = "delegated-escape-parent-\(UUID().uuidString)"
        defer { removeContextDir(parentId) }

        // A transcript-carried hostPath outside the child's store must never
        // be copied (no content to fall back on → skipped entirely).
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("delegated-outside-\(UUID().uuidString).txt")
        try Data("outside the store".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escaping = SharedArtifact(
            contextId: childId,
            contextType: .chat,
            filename: "escape.txt",
            mimeType: "text/plain",
            fileSize: 3,
            hostPath: outside.path
        )
        #expect(
            SharedArtifact.adoptIntoContext(
                escaping, contextId: parentId, sourceRootContextId: childId
            ) == nil
        )

        // With inline content the adoption re-WRITES the text instead of
        // touching the untrusted path.
        let inline = SharedArtifact(
            contextId: childId,
            contextType: .chat,
            filename: "inline.md",
            mimeType: "text/markdown",
            fileSize: 5,
            hostPath: outside.path,
            content: "# safe"
        )
        let adopted = try #require(
            SharedArtifact.adoptIntoContext(
                inline, contextId: parentId, sourceRootContextId: childId
            )
        )
        let written = try String(
            contentsOfFile: adopted.hostPath, encoding: .utf8
        )
        #expect(written == "# safe")
    }

    @Test("adoptChildArtifacts deposits the persisted child's artifacts for the parent drain")
    @MainActor
    func adoptChildArtifactsDepositsForParentDrain() async throws {
        try await ChatHistoryTestStorage.run {
            SpawnArtifactCollector._resetForTesting()
            defer { SpawnArtifactCollector._resetForTesting() }

            let childSessionId = UUID()
            let parentSessionId = "delegated-drain-parent-\(UUID().uuidString)"
            defer {
                removeContextDir(childSessionId.uuidString)
                removeContextDir(parentSessionId)
            }
            let made = try await makeChildArtifact(
                contextId: childSessionId.uuidString,
                filename: "report.md",
                content: "# delegated result"
            )
            var toolTurn = ChatTurnData(role: .tool, content: "")
            toolTurn.toolResults = ["call_1": made.enrichedEnvelope]
            ChatSessionStore.save(
                ChatSessionData(
                    id: childSessionId,
                    title: "Delegated: test",
                    turns: [
                        ChatTurnData(role: .user, content: "write a report"),
                        toolTurn,
                        ChatTurnData(role: .assistant, content: "shared it"),
                    ],
                    source: .delegation
                )
            )

            let count = AgentDelegationDispatcher.adoptChildArtifacts(
                childSessionId: childSessionId,
                parentSessionId: parentSessionId
            )
            #expect(count == 1)

            let drained = SpawnArtifactCollector.drain(sessionId: parentSessionId)
            #expect(drained.count == 1)
            let artifact = try #require(drained.first)
            #expect(artifact.contextId == parentSessionId)
            #expect(artifact.filename == "report.md")
            #expect(FileManager.default.fileExists(atPath: artifact.hostPath))

            // No parent session → nothing deposited (HTTP/eval parents).
            #expect(
                AgentDelegationDispatcher.adoptChildArtifacts(
                    childSessionId: childSessionId, parentSessionId: nil
                ) == 0
            )
        }
    }

    @Test("the dispatcher adopts artifacts for EVERY terminal state, before the result switch")
    func adoptionRunsForEveryTerminalState() throws {
        // Source pin, matching the repo's wiring-guard style: cancelled and
        // failed children must still pass their artifacts through, so the
        // adoption call has to precede the terminal-state switch in `run`.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Subagent/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        let dispatcher = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Services/AgentDelegation/AgentDelegationDispatcher.swift"),
            encoding: .utf8
        )
        let adoptRange = try #require(
            dispatcher.range(of: "await adoptChildArtifacts("),
            "dispatcher.run must adopt child artifacts"
        )
        let switchRange = try #require(
            dispatcher.range(of: "switch result {"),
            "dispatcher.run terminal switch not found"
        )
        #expect(
            adoptRange.lowerBound < switchRange.lowerBound,
            "artifact adoption must precede the terminal-state switch (cancelled/failed pass-through)"
        )
        // And the spawn kind must actually forward the parent session.
        let kind = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Subagent/Kinds/TextSubagentKind.swift"),
            encoding: .utf8
        )
        #expect(kind.contains("parentSessionId: scope.sessionId"))
        #expect(kind.contains("outcome.artifactsShared"))
    }
}
