//
//  RemoteRunArtifactsTests.swift
//  OsaurusCoreTests
//
//  Artifacts back over the relay (Mode 2 delegation):
//
//   * Host: `RemoteRunArtifactRelay.intercept` processes a hosted run's
//     `share_artifact` result into the hosted session's store, collects the
//     typed artifact and hands the model a compact confirmation; failures
//     pass through as the tool's own envelope.
//   * The final `osaurus_artifacts` payload carries bytes within the caps
//     and lists the rest with `omitted_reason`.
//   * Wire: `StreamingArtifactHint` round-trips the list as a `\u{FFFE}`
//     sentinel (never visible text).
//   * Client: `SharedArtifact.importRemoteArtifacts` writes the bytes into
//     the requester's session store and yields typed artifacts the spawn
//     adoption path (`adoptChildArtifacts`) can re-home to the parent.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct RemoteRunArtifactsTests {

    private func removeContextDir(_ contextId: String) {
        try? FileManager.default.removeItem(at: OsaurusPaths.contextArtifactsDir(contextId: contextId))
    }

    private func share(content: String, filename: String) async throws -> String {
        try await ShareArtifactTool().execute(
            argumentsJSON: """
                {"content": \(String(reflecting: content)), "filename": \(String(reflecting: filename))}
                """
        )
    }

    @Test("host intercept stores the file, collects the artifact, and confirms compactly")
    func hostInterceptCollectsAndConfirms() async throws {
        let contextId = "remote-run-artifacts-\(UUID().uuidString)"
        defer { removeContextDir(contextId) }
        let relay = RemoteRunArtifactRelay(contextId: contextId, executionMode: .none)

        let raw = try await share(content: "# Findings\nhello over the relay", filename: "findings.md")
        let modelResult = relay.intercept(rawResult: raw)

        #expect(!ToolEnvelope.isError(modelResult))
        #expect(!modelResult.contains("SHARED_ARTIFACT_START"), "the model never sees the marker blob")
        #expect(modelResult.contains("findings.md"))
        #expect(modelResult.contains("travels back to the requester"))
        #expect(relay.count == 1)
        let artifact = try #require(relay.artifacts.first)
        #expect(artifact.contextId == contextId)
        #expect(FileManager.default.fileExists(atPath: artifact.hostPath))

        // A path-mode share with no execution mode fails with the tool's own
        // steering envelope and collects nothing.
        let pathRaw = try await ShareArtifactTool().execute(argumentsJSON: #"{"path": "out/report.pdf"}"#)
        let failed = relay.intercept(rawResult: pathRaw)
        #expect(ToolEnvelope.isError(failed))
        #expect(relay.count == 1)

        // Non-success envelopes pass through untouched.
        let invalid = ToolEnvelope.failure(kind: .invalidArgs, message: "nope", tool: "share_artifact")
        #expect(relay.intercept(rawResult: invalid) == invalid)
    }

    @Test("payload carries bytes within the caps and lists the rest as omitted")
    func payloadHonoursCaps() async throws {
        let contextId = "remote-run-artifacts-caps-\(UUID().uuidString)"
        defer { removeContextDir(contextId) }
        let relay = RemoteRunArtifactRelay(contextId: contextId, executionMode: .none)
        _ = relay.intercept(rawResult: try await share(content: "small one", filename: "a.txt"))
        _ = relay.intercept(rawResult: try await share(content: String(repeating: "x", count: 300), filename: "b.txt"))
        _ = relay.intercept(rawResult: try await share(content: "third", filename: "c.txt"))
        let artifacts = relay.artifacts
        #expect(artifacts.count == 3)

        // A budget that fits a + c but not b: b is listed without bytes.
        let rows = RemoteRunArtifactRelay.payload(for: artifacts, maxTotalBytes: 100, maxCount: 16)
        #expect(rows.map(\.name) == ["a.txt", "b.txt", "c.txt"])
        #expect(rows[0].bytes_base64 != nil)
        #expect(rows[1].isOmitted)
        #expect(rows[1].omitted_reason == "too_large")
        // Inline shares are stored with a trailing newline by the marker
        // pipeline; the size reflects the bytes on disk.
        #expect(rows[1].size_bytes >= 300)
        #expect(rows[2].bytes_base64 != nil)
        let decoded = try #require(
            Data(base64Encoded: rows[0].bytes_base64!).flatMap { String(data: $0, encoding: .utf8) })
        #expect(decoded.hasPrefix("small one"))

        // The count cap trims the tail; a directory never carries bytes.
        #expect(RemoteRunArtifactRelay.payload(for: artifacts, maxCount: 2).count == 2)
        let directory = SharedArtifact(
            contextId: contextId, contextType: .chat, filename: "site", mimeType: "inode/directory",
            fileSize: 10, hostPath: artifacts[0].hostPath, isDirectory: true
        )
        let dirRows = RemoteRunArtifactRelay.payload(for: [directory])
        #expect(dirRows.first?.omitted_reason == "directory")
        #expect(dirRows.first?.isOmitted == true)
    }

    @Test("the streaming hint round-trips the list and is a sentinel, never visible text")
    func hintRoundTrips() {
        let rows = [
            RemoteRunArtifact(name: "a.txt", mime: "text/plain", description: "d", size_bytes: 3, bytes_base64: "YWJj"),
            RemoteRunArtifact(name: "big.zip", mime: "application/zip", size_bytes: 9_000_000, omitted_reason: "too_large"),
        ]
        let delta = StreamingArtifactHint.encode(rows)
        #expect(StreamingToolHint.isSentinel(delta), "shares the \\u{FFFE} sentinel family")
        #expect(StreamingArtifactHint.decode(delta) == rows)
        #expect(StreamingArtifactHint.decode("plain text") == nil)
        #expect(StreamingBillingHint.decode(delta) == nil)
        #expect(StreamingPrefillProgressHint.decode(delta) == nil)
    }

    @Test("client import writes bytes into the session store and skips omitted rows")
    func clientImportWritesAndSkips() throws {
        let sessionId = "remote-run-import-\(UUID().uuidString)"
        defer { removeContextDir(sessionId) }
        let rows = [
            RemoteRunArtifact(
                name: "../escape.md", mime: "text/markdown", description: "notes",
                size_bytes: 5, bytes_base64: Data("hello".utf8).base64EncodedString()
            ),
            RemoteRunArtifact(name: "big.zip", mime: "application/zip", size_bytes: 9_000_000, omitted_reason: "too_large"),
            RemoteRunArtifact(name: "img.png", mime: "", size_bytes: 3, bytes_base64: Data([0x1, 0x2, 0x3]).base64EncodedString()),
        ]
        let imported = SharedArtifact.importRemoteArtifacts(rows, contextId: sessionId)
        #expect(imported.count == 2, "the omitted row produces no artifact")

        let notes = try #require(imported.first)
        #expect(notes.filename == "escape.md", "path segments are stripped")
        #expect(notes.contextId == sessionId)
        #expect(notes.content == "hello")
        #expect(notes.description == "notes")
        let storeDir = OsaurusPaths.contextArtifactsDir(contextId: sessionId).path
        #expect(notes.hostPath.hasPrefix(storeDir))
        #expect(FileManager.default.fileExists(atPath: notes.hostPath))

        let image = imported[1]
        #expect(image.mimeType == "image/png", "empty mime falls back to the extension")
        #expect(image.content == nil)
        #expect(image.fileSize == 3)

        // The imported artifacts re-home to a parent exactly like a local
        // child's — the spawn adoption path needs no special case.
        let parentId = "remote-run-import-parent-\(UUID().uuidString)"
        defer { removeContextDir(parentId) }
        let adopted = SharedArtifact.adoptIntoContext(notes, contextId: parentId, sourceRootContextId: sessionId)
        #expect(adopted?.contextId == parentId)
        #expect(adopted.map { FileManager.default.fileExists(atPath: $0.hostPath) } == true)
    }

    /// `spawn_agent(continue:)` resolves Mode 2 sessions too: the persisted
    /// row must be a delegated session stamped with the SAME shared agent;
    /// another teammate's agent, a local agent, or a non-delegated row is
    /// refused with a typed error, and a pre-resume row cannot be continued.
    @Test("continue validates workspace worker sessions and refuses foreign ones")
    @MainActor
    func continueValidatesWorkspaceSessions() async throws {
        try await ChatHistoryTestStorage.run {
            let db = ChatHistoryDatabase.shared
            try db.open()
            let ref = WorkspaceAgentRef(
                workspaceId: "ws-1", agentAddress: "0x" + String(repeating: "a", count: 40))
            let other = WorkspaceAgentRef(
                workspaceId: "ws-1", agentAddress: "0x" + String(repeating: "b", count: 40))

            let sessionId = UUID()
            try db.saveSession(
                ChatSessionData(
                    id: sessionId,
                    title: "worker",
                    agentId: Agent.defaultId,
                    source: .delegation,
                    externalSessionKey: AgentDelegationDispatcher.externalSessionKey(for: sessionId),
                    workspace: WorkspaceSessionContext(workspaceId: ref.workspaceId, agentAddress: ref.agentAddress)
                )
            )
            defer { try? db.deleteSession(id: sessionId) }

            // Same shared agent → resumable.
            let row = try AgentDelegationDispatcher.validateResumeSession(
                sessionId, target: .workspace(ref), targetAgentName: "Research")
            #expect(row.id == sessionId)

            // Another teammate's agent → denied.
            #expect(throws: SubagentError.self) {
                try AgentDelegationDispatcher.validateResumeSession(
                    sessionId, target: .workspace(other), targetAgentName: "Other")
            }
            // A local agent must not adopt a workspace transcript.
            #expect(throws: SubagentError.self) {
                try AgentDelegationDispatcher.validateResumeSession(
                    sessionId, target: .local(UUID()), targetAgentName: "Local")
            }
            // Unknown id → unavailable with a "start a new task" hint.
            do {
                _ = try AgentDelegationDispatcher.validateResumeSession(
                    UUID(), target: .workspace(ref), targetAgentName: "Research")
                Issue.record("expected unavailable")
            } catch let error as SubagentError {
                #expect("\(error)".contains("Start a new task"))
            }

            // A pre-resume row (no delegation key) cannot be continued.
            let legacyId = UUID()
            try db.saveSession(
                ChatSessionData(
                    id: legacyId, title: "legacy", agentId: Agent.defaultId, source: .delegation,
                    workspace: WorkspaceSessionContext(workspaceId: ref.workspaceId, agentAddress: ref.agentAddress)
                )
            )
            defer { try? db.deleteSession(id: legacyId) }
            #expect(throws: SubagentError.self) {
                try AgentDelegationDispatcher.validateResumeSession(
                    legacyId, target: .workspace(ref), targetAgentName: "Research")
            }
        }
    }

    @Test("the remote delivery contract tells the worker what reaches the requester")
    func remoteContractNamesTheLimit() {
        let contract = AgentDelegationDispatcher.remoteDeliveryContract
        #expect(contract.contains("share_artifact"))
        #expect(contract.contains("reach the requester"))
        #expect(contract.contains("stay on this Mac"))
    }
}
