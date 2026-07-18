//
//  SandboxWorkspaceChangeTrackerTests.swift
//  osaurusTests
//
//  Verifies per-chat sandbox workspace change tracking: checkpoint diffing
//  and coalescing, binary/directory/symlink handling, conflict-aware undo,
//  persistence across "relaunch", session purge, background-job pending
//  records + recovery, and the registry-level checkpoint wrap.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SandboxWorkspaceChangeTrackerTests {

    private static let agent = "tester"
    private static let session = "test-session"

    // MARK: - Environment

    private struct Env {
        let tmp: URL
        let db: ChatHistoryDatabase
        let tracker: SandboxWorkspaceChangeTracker
        let agentHome: URL
        let sharedRoot: URL
        /// A user-selected "Folder" root for host checkpoint tests.
        let hostFolder: URL
        let provider: @Sendable (String, SandboxWorkspaceRootKind) -> URL
        let baselines: URL

        /// A second tracker instance over the same DB + baselines dir,
        /// simulating an app relaunch (fresh in-memory state).
        func relaunchedTracker() -> SandboxWorkspaceChangeTracker {
            SandboxWorkspaceChangeTracker(
                database: db,
                baselinesRoot: baselines,
                hostRootProvider: provider
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func makeEnv() throws -> Env {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("osu-sandbox-changes-\(UUID().uuidString)", isDirectory: true)
        let agentsRoot = tmp.appendingPathComponent("agents", isDirectory: true)
        let agentHome = agentsRoot.appendingPathComponent(Self.agent, isDirectory: true)
        let sharedRoot = tmp.appendingPathComponent("shared", isDirectory: true)
        let hostFolder = tmp.appendingPathComponent("hostfolder", isDirectory: true)
        let baselines = tmp.appendingPathComponent("baselines", isDirectory: true)
        try fm.createDirectory(at: agentHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: hostFolder, withIntermediateDirectories: true)

        let db = ChatHistoryDatabase()
        try db.openInMemory()

        let provider: @Sendable (String, SandboxWorkspaceRootKind) -> URL = { name, root in
            switch root {
            case .agentHome: return agentsRoot.appendingPathComponent(name, isDirectory: true)
            case .shared: return sharedRoot
            // Host rows carry the folder's absolute path in the agentName
            // slot — same resolution as the production default provider.
            case .hostFolder: return URL(fileURLWithPath: name, isDirectory: true)
            }
        }
        let tracker = SandboxWorkspaceChangeTracker(
            database: db,
            baselinesRoot: baselines,
            hostRootProvider: provider
        )
        return Env(
            tmp: tmp,
            db: db,
            tracker: tracker,
            agentHome: agentHome,
            sharedRoot: sharedRoot,
            hostFolder: hostFolder,
            provider: provider,
            baselines: baselines
        )
    }

    /// Run `body` inside a HOST-folder begin/end checkpoint pair, the way
    /// the registry wraps a `mutatesHostFolder` tool call.
    private func hostCheckpointed(
        _ env: Env,
        session: String = SandboxWorkspaceChangeTrackerTests.session,
        tool: String = "file_write",
        _ body: () throws -> Void
    ) async throws {
        let token = await env.tracker.beginHostCheckpoint(
            sessionId: session, folderPath: env.hostFolder.path, sourceTool: tool)
        try body()
        await env.tracker.endCheckpoint(token)
    }

    /// Run `body` inside a begin/end checkpoint pair, the way the registry
    /// wraps a mutation-capable tool call.
    private func checkpointed(
        _ tracker: SandboxWorkspaceChangeTracker,
        session: String = SandboxWorkspaceChangeTrackerTests.session,
        tool: String = "sandbox_write_file",
        _ body: () throws -> Void
    ) async throws {
        let token = await tracker.beginCheckpoint(
            sessionId: session, agentName: Self.agent, sourceTool: tool)
        try body()
        await tracker.endCheckpoint(token)
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Diffing / coalescing

    @Test
    func createEditDelete_coalescesToNetNoop() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("a.txt")

        try await checkpointed(env.tracker) { try self.write(file, "one") }
        var changes = await env.tracker.changes(for: Self.session)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .created)
        #expect(changes.first?.relativePath == "a.txt")
        #expect(changes.first?.baselineSignature == nil)

        // Edit in a later checkpoint: still ONE net change, still `created`
        // (the file didn't exist before the chat).
        try await checkpointed(env.tracker) { try self.write(file, "two") }
        changes = await env.tracker.changes(for: Self.session)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .created)

        // Delete: created-then-deleted nets out to nothing.
        try await checkpointed(env.tracker) {
            try FileManager.default.removeItem(at: file)
        }
        changes = await env.tracker.changes(for: Self.session)
        #expect(changes.isEmpty)
    }

    @Test
    func diffText_coversModifiedCreatedDeletedAndBinary() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let modified = env.agentHome.appendingPathComponent("mod.txt")
        let created = env.agentHome.appendingPathComponent("new.txt")
        let deleted = env.agentHome.appendingPathComponent("gone.txt")
        let binary = env.agentHome.appendingPathComponent("blob.bin")
        try write(modified, "line one\nline two")
        try write(deleted, "old content")

        try await checkpointed(env.tracker) {
            try self.write(modified, "line one\nline 2!")
            try self.write(created, "brand new")
            try FileManager.default.removeItem(at: deleted)
            try Data([0x00, 0x01, 0x02]).write(to: binary)
        }
        let changes = await env.tracker.changes(for: Self.session)
        #expect(changes.count == 4)

        func diff(_ rel: String) async -> SandboxChangeDiffResult {
            let id = changes.first { $0.relativePath == rel }!.id
            return await env.tracker.diffText(for: id, sessionId: Self.session)
        }

        // Modified: baseline vs live with removed + added lines.
        guard case .diff(let modText) = await diff("mod.txt") else {
            Issue.record("expected text diff for mod.txt")
            return
        }
        #expect(modText.contains("-line two"))
        #expect(modText.contains("+line 2!"))
        #expect(modText.contains(" line one"))

        // Created: every line added, none removed.
        guard case .diff(let newText) = await diff("new.txt") else {
            Issue.record("expected text diff for new.txt")
            return
        }
        #expect(newText.contains("+brand new"))
        #expect(!newText.contains("\n-"))

        // Deleted: every line removed.
        guard case .diff(let goneText) = await diff("gone.txt") else {
            Issue.record("expected text diff for gone.txt")
            return
        }
        #expect(goneText.contains("-old content"))

        // Binary: flagged, not diffed.
        #expect(await diff("blob.bin") == .binary)

        // Unknown id: unavailable.
        #expect(
            await env.tracker.diffText(for: UUID(), sessionId: Self.session) == .unavailable)
    }

    @Test
    func modifyThenRevert_removesRow() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("b.txt")
        try write(file, "hello")

        try await checkpointed(env.tracker) { try self.write(file, "world") }
        var changes = await env.tracker.changes(for: Self.session)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .modified)
        #expect(changes.first?.baselineSignature != nil)

        try await checkpointed(env.tracker) { try self.write(file, "hello") }
        changes = await env.tracker.changes(for: Self.session)
        #expect(changes.isEmpty)
    }

    @Test
    func sharedRootChanges_trackedSeparately() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await checkpointed(env.tracker) {
            try self.write(env.agentHome.appendingPathComponent("home.txt"), "h")
            try self.write(env.sharedRoot.appendingPathComponent("shared.txt"), "s")
        }
        let changes = await env.tracker.changes(for: Self.session)
        #expect(changes.count == 2)
        #expect(changes.contains { $0.root == .agentHome && $0.relativePath == "home.txt" })
        #expect(changes.contains { $0.root == .shared && $0.relativePath == "shared.txt" })
    }

    @Test
    func excludedPaths_areIgnored() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await checkpointed(env.tracker) {
            try self.write(
                env.agentHome.appendingPathComponent("node_modules/pkg/index.js"), "x")
            try self.write(env.agentHome.appendingPathComponent(".venv/lib/site.py"), "x")
            try self.write(env.agentHome.appendingPathComponent("bg-abc123.log"), "log")
            try self.write(env.agentHome.appendingPathComponent("kept.txt"), "keep")
        }
        let changes = await env.tracker.changes(for: Self.session)
        // node_modules dir itself is excluded too, so only kept.txt lands.
        #expect(changes.map(\.relativePath) == ["kept.txt"])
    }

    @Test
    func concurrentSessions_attributeOnlyOwnTouches() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await checkpointed(env.tracker, session: "session-A") {
            try self.write(env.agentHome.appendingPathComponent("from-a.txt"), "a")
        }
        // Session B's baseline is cloned AFTER A's file exists; B's
        // checkpoint only touches its own file.
        try await checkpointed(env.tracker, session: "session-B") {
            try self.write(env.agentHome.appendingPathComponent("from-b.txt"), "b")
        }

        let aChanges = await env.tracker.changes(for: "session-A")
        let bChanges = await env.tracker.changes(for: "session-B")
        #expect(aChanges.map(\.relativePath) == ["from-a.txt"])
        #expect(bChanges.map(\.relativePath) == ["from-b.txt"])
    }

    // MARK: - Undo

    @Test
    func undoDeletedBinaryFile_restoresExactBytes() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("blob.bin")
        var bytes = Data((0 ..< 4096).map { _ in UInt8.random(in: 0 ... 255) })
        bytes.append(contentsOf: [0, 0, 0])  // embedded NULs
        try bytes.write(to: file)

        try await checkpointed(env.tracker) {
            try FileManager.default.removeItem(at: file)
        }
        let changes = await env.tracker.changes(for: Self.session)
        #expect(changes.first?.kind == .deleted)

        let result = await env.tracker.undoChange(
            id: try #require(changes.first?.id), sessionId: Self.session)
        #expect(result == .undone)
        #expect(try Data(contentsOf: file) == bytes)
        let remaining = await env.tracker.changes(for: Self.session)
        #expect(remaining.isEmpty)
    }

    @Test
    func undoModifiedFile_restoresBaselineContent() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("doc.md")
        try write(file, "original")

        try await checkpointed(env.tracker) { try self.write(file, "agent edit") }
        let changes = await env.tracker.changes(for: Self.session)
        let result = await env.tracker.undoChange(
            id: try #require(changes.first?.id), sessionId: Self.session)
        #expect(result == .undone)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }

    @Test
    func undoCreatedFile_removesIt() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("new.txt")

        try await checkpointed(env.tracker) { try self.write(file, "fresh") }
        let changes = await env.tracker.changes(for: Self.session)
        let result = await env.tracker.undoChange(
            id: try #require(changes.first?.id), sessionId: Self.session)
        #expect(result == .undone)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func undoConflict_refusesAndFlagsRow() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("shared-doc.txt")
        try write(file, "original")

        try await checkpointed(env.tracker) { try self.write(file, "chat edit") }
        // Someone else changes the file AFTER the chat's last tracked state.
        try write(file, "outside edit")

        let changes = await env.tracker.changes(for: Self.session)
        let result = await env.tracker.undoChange(
            id: try #require(changes.first?.id), sessionId: Self.session)
        #expect(result == .conflicted)
        // Newer work is never overwritten; the row is retained + flagged.
        #expect(try String(contentsOf: file, encoding: .utf8) == "outside edit")
        let after = await env.tracker.changes(for: Self.session)
        #expect(after.count == 1)
        #expect(after.first?.state == .conflicted)
    }

    @Test
    func undoAll_isBestEffortAndReportsPartialFailure() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let clean = env.agentHome.appendingPathComponent("clean.txt")
        let conflicted = env.agentHome.appendingPathComponent("conflicted.txt")
        try write(clean, "one")
        try write(conflicted, "two")

        try await checkpointed(env.tracker) {
            try self.write(clean, "one-edited")
            try self.write(conflicted, "two-edited")
        }
        try write(conflicted, "outside")

        let summary = await env.tracker.undoAll(sessionId: Self.session)
        #expect(summary.undone == 1)
        #expect(summary.conflicted == 1)
        #expect(summary.failed == 0)
        #expect(try String(contentsOf: clean, encoding: .utf8) == "one")
        #expect(try String(contentsOf: conflicted, encoding: .utf8) == "outside")
        let remaining = await env.tracker.changes(for: Self.session)
        #expect(remaining.count == 1)
        #expect(remaining.first?.state == .conflicted)
    }

    @Test
    func undoAll_handlesDirectoriesAndSymlinks() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let fm = FileManager.default
        let dir = env.agentHome.appendingPathComponent("out", isDirectory: true)
        let nested = dir.appendingPathComponent("result.txt")
        let link = env.agentHome.appendingPathComponent("latest")

        try await checkpointed(env.tracker) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try self.write(nested, "data")
            try fm.createSymbolicLink(
                at: link, withDestinationURL: URL(fileURLWithPath: "out/result.txt"))
        }
        let changes = await env.tracker.changes(for: Self.session)
        #expect(changes.count == 3)
        #expect(changes.contains { $0.relativePath == "out" && $0.entryType == .directory })
        #expect(changes.contains { $0.relativePath == "latest" && $0.entryType == .symlink })

        let summary = await env.tracker.undoAll(sessionId: Self.session)
        #expect(summary.undone == 3)
        #expect(!fm.fileExists(atPath: nested.path))
        #expect(!fm.fileExists(atPath: dir.path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }

    // MARK: - Persistence

    @Test
    func changesAndUndo_surviveRelaunch() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let created = env.agentHome.appendingPathComponent("created.txt")
        let modified = env.agentHome.appendingPathComponent("modified.txt")
        try write(modified, "before")

        try await checkpointed(env.tracker) {
            try self.write(created, "new")
            try self.write(modified, "after")
        }

        // Fresh tracker over the same DB + baselines = app relaunch.
        let relaunched = env.relaunchedTracker()
        let changes = await relaunched.changes(for: Self.session)
        #expect(changes.count == 2)

        let summary = await relaunched.undoAll(sessionId: Self.session)
        #expect(summary.undone == 2)
        #expect(!FileManager.default.fileExists(atPath: created.path))
        #expect(try String(contentsOf: modified, encoding: .utf8) == "before")
    }

    @Test
    func purgeSession_dropsRowsBlobsAndDBRows() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        try await checkpointed(env.tracker) {
            try self.write(env.agentHome.appendingPathComponent("x.txt"), "x")
        }
        #expect(env.db.loadSandboxChanges(sessionId: Self.session).count == 1)
        let sessionBaselines = env.baselines.appendingPathComponent(Self.session)
        #expect(FileManager.default.fileExists(atPath: sessionBaselines.path))

        await env.tracker.purgeSession(Self.session)

        let changes = await env.tracker.changes(for: Self.session)
        #expect(changes.isEmpty)
        #expect(env.db.loadSandboxChanges(sessionId: Self.session).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sessionBaselines.path))
    }

    // MARK: - Background jobs

    @Test
    func backgroundJob_blocksUndoUntilFinalizedThenAttributesChanges() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let tracked = env.agentHome.appendingPathComponent("pre.txt")
        try write(tracked, "before")
        try await checkpointed(env.tracker) { try self.write(tracked, "after") }

        await env.tracker.registerBackgroundJob(
            sessionId: Self.session, agentName: Self.agent, pid: "4242",
            sourceTool: "sandbox_exec")
        let active = await env.tracker.hasActiveBackgroundJobs(sessionId: Self.session)
        #expect(active)

        // Undo is refused while the job may still be writing.
        let blocked = await env.tracker.undoAll(sessionId: Self.session)
        #expect(blocked.undone == 0)
        #expect(blocked.failed == 1)

        // The "job" writes its output, then exits.
        let jobOutput = env.agentHome.appendingPathComponent("job-output.txt")
        try write(jobOutput, "produced by job")
        await env.tracker.finalizeBackgroundJob(agentName: Self.agent, pid: "4242")

        let stillActive = await env.tracker.hasActiveBackgroundJobs(sessionId: Self.session)
        #expect(!stillActive)
        let changes = await env.tracker.changes(for: Self.session)
        #expect(changes.contains { $0.relativePath == "job-output.txt" && $0.kind == .created })
    }

    @Test
    func pendingBackgroundJob_isRecoveredAfterRelaunch() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        await env.tracker.registerBackgroundJob(
            sessionId: Self.session, agentName: Self.agent, pid: "777",
            sourceTool: "sandbox_exec")
        // Job writes output, then the app "dies" before the exit poll fires.
        try write(env.agentHome.appendingPathComponent("survivor.txt"), "output")

        let relaunched = env.relaunchedTracker()
        let changes = await relaunched.changes(for: Self.session)
        #expect(changes.contains { $0.relativePath == "survivor.txt" && $0.kind == .created })
        let active = await relaunched.hasActiveBackgroundJobs(sessionId: Self.session)
        #expect(!active)
    }

    // MARK: - Host folder root

    @Test
    func hostCheckpoint_tracksCoalescesDiffsAndUndoes() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let created = env.hostFolder.appendingPathComponent("new.txt")
        let modified = env.hostFolder.appendingPathComponent("doc.md")
        let deleted = env.hostFolder.appendingPathComponent("gone.txt")
        try write(modified, "original")
        try write(deleted, "old content")

        try await hostCheckpointed(env) {
            try self.write(created, "fresh")
            try self.write(modified, "edited")
            try FileManager.default.removeItem(at: deleted)
        }
        var changes = await env.tracker.changes(for: Self.session)
        #expect(changes.count == 3)
        for change in changes {
            #expect(change.root == .hostFolder)
            #expect(change.agentName == env.hostFolder.path)
            // displayPath renders the REAL host path, not a container path.
            #expect(change.displayPath == env.hostFolder.path + "/" + change.relativePath)
            #expect(change.hostURL.path == env.hostFolder.path + "/" + change.relativePath)
        }
        #expect(changes.contains { $0.relativePath == "new.txt" && $0.kind == .created })
        #expect(changes.contains { $0.relativePath == "doc.md" && $0.kind == .modified })
        #expect(changes.contains { $0.relativePath == "gone.txt" && $0.kind == .deleted })

        // Diff resolves through the host root.
        let modId = try #require(changes.first { $0.relativePath == "doc.md" }?.id)
        guard case .diff(let text) = await env.tracker.diffText(
            for: modId, sessionId: Self.session)
        else {
            Issue.record("expected text diff for doc.md")
            return
        }
        #expect(text.contains("-original"))
        #expect(text.contains("+edited"))

        // Revert-in-a-later-checkpoint coalesces the row away.
        try await hostCheckpointed(env) { try self.write(modified, "original") }
        changes = await env.tracker.changes(for: Self.session)
        #expect(changes.count == 2)
        #expect(!changes.contains { $0.relativePath == "doc.md" })

        // Undo all restores the pre-chat state.
        let summary = await env.tracker.undoAll(sessionId: Self.session)
        #expect(summary.undone == 2)
        #expect(!FileManager.default.fileExists(atPath: created.path))
        #expect(try String(contentsOf: deleted, encoding: .utf8) == "old content")
        #expect(await env.tracker.changes(for: Self.session).isEmpty)
    }

    @Test
    func hostAndSandboxRows_coexistWithoutCrossTalk() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }

        try await checkpointed(env.tracker) {
            try self.write(env.agentHome.appendingPathComponent("sb.txt"), "sandbox")
        }
        try await hostCheckpointed(env) {
            try self.write(env.hostFolder.appendingPathComponent("host.txt"), "host")
        }

        let changes = await env.tracker.changes(for: Self.session)
        #expect(changes.count == 2)
        #expect(changes.contains { $0.root == .agentHome && $0.relativePath == "sb.txt" })
        #expect(changes.contains { $0.root == .hostFolder && $0.relativePath == "host.txt" })

        // Undoing the host row leaves the sandbox row untouched (and vice
        // versa lands in other tests) — proves per-root baseline isolation.
        let hostId = try #require(changes.first { $0.root == .hostFolder }?.id)
        let result = await env.tracker.undoChange(id: hostId, sessionId: Self.session)
        #expect(result == .undone)
        let remaining = await env.tracker.changes(for: Self.session)
        #expect(remaining.map(\.relativePath) == ["sb.txt"])
        #expect(
            FileManager.default.fileExists(
                atPath: env.agentHome.appendingPathComponent("sb.txt").path))
    }

    @Test
    func hostChanges_surviveRelaunchAndPurge() async throws {
        let env = try makeEnv()
        defer { env.cleanup() }
        let file = env.hostFolder.appendingPathComponent("persist.txt")
        try write(file, "before")
        try await hostCheckpointed(env) { try self.write(file, "after") }

        let relaunched = env.relaunchedTracker()
        let changes = await relaunched.changes(for: Self.session)
        #expect(changes.count == 1)
        #expect(changes.first?.root == .hostFolder)

        let summary = await relaunched.undoAll(sessionId: Self.session)
        #expect(summary.undone == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "before")

        // Purge drops the sanitized host baseline dir with the session.
        try await hostCheckpointed(env) { try self.write(file, "again") }
        let sessionBaselines = env.baselines.appendingPathComponent(Self.session)
        #expect(FileManager.default.fileExists(atPath: sessionBaselines.path))
        await env.tracker.purgeSession(Self.session)
        #expect(!FileManager.default.fileExists(atPath: sessionBaselines.path))
        #expect(await env.tracker.changes(for: Self.session).isEmpty)
    }

    @Test
    func hostFolderKey_isStableAndFilesystemSafe() {
        let key = SandboxWorkspaceChangeTracker.hostFolderKey("/Users/me/My Projects/app")
        #expect(key.hasPrefix("host-"))
        #expect(!key.contains("/"))
        #expect(key == SandboxWorkspaceChangeTracker.hostFolderKey("/Users/me/My Projects/app"))
        #expect(key != SandboxWorkspaceChangeTracker.hostFolderKey("/Users/me/other"))
    }

    // MARK: - Registry integration

    /// A minimal mutation-capable tool whose body writes into the sandbox
    /// agent home, proving the registry's checkpoint wrap attributes the
    /// mutation without the tool knowing anything about tracking.
    private struct FakeSandboxMutatingTool: OsaurusTool, @unchecked Sendable {
        let name = "test_sandbox_mutator"
        let description = "test-only sandbox mutator"
        let parameters: JSONValue? = nil
        var mutatesSandboxWorkspace: Bool { true }
        let fileURL: URL

        func execute(argumentsJSON: String) async throws -> String {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "payload".write(to: fileURL, atomically: true, encoding: .utf8)
            return "ok"
        }
    }

    @Test @MainActor
    func toolRegistry_wrapsMutationCapableToolsInCheckpoint() async throws {
        try await SandboxTestLock.shared.run {
            let agentName = "chgtest-agent"
            let home = OsaurusPaths.containerAgentDir(agentName)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }

            let sessionId = UUID().uuidString
            let target = home.appendingPathComponent("registry-tracked.txt")

            ToolRegistry.shared.setActiveSandboxAgentContext(
                agentName: agentName,
                home: OsaurusPaths.inContainerAgentHome(agentName)
            )
            ToolRegistry.shared.register(FakeSandboxMutatingTool(fileURL: target))
            defer {
                ToolRegistry.shared.unregister(names: ["test_sandbox_mutator"])
                ToolRegistry.shared.unregisterAllBuiltinSandboxTools()
            }

            _ = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                try await ToolRegistry.shared.execute(
                    name: "test_sandbox_mutator", argumentsJSON: "{}")
            }

            let changes = await SandboxWorkspaceChangeTracker.shared.changes(for: sessionId)
            defer { Task { await SandboxWorkspaceChangeTracker.shared.purgeSession(sessionId) } }
            #expect(changes.count == 1)
            #expect(changes.first?.relativePath == "registry-tracked.txt")
            #expect(changes.first?.kind == .created)
            #expect(changes.first?.sourceTool == "test_sandbox_mutator")
        }
    }

    /// A minimal host-folder-mutating tool, proving the registry's host
    /// checkpoint wrap attributes selected-folder mutations the same way.
    private struct FakeHostMutatingTool: OsaurusTool, @unchecked Sendable {
        let name = "test_host_mutator"
        let description = "test-only host folder mutator"
        let parameters: JSONValue? = nil
        var mutatesHostFolder: Bool { true }
        let fileURL: URL

        func execute(argumentsJSON: String) async throws -> String {
            try "payload".write(to: fileURL, atomically: true, encoding: .utf8)
            return "ok"
        }
    }

    @Test @MainActor
    func toolRegistry_wrapsHostFolderToolsInHostCheckpoint() async throws {
        try await SandboxTestLock.shared.run {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory
                .appendingPathComponent("osu-host-registry-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }

            let sessionId = UUID().uuidString
            let target = folder.appendingPathComponent("host-tracked.txt")

            FolderContextService._setCachedRootPathForTesting(folder)
            ToolRegistry.shared.register(FakeHostMutatingTool(fileURL: target))
            defer {
                ToolRegistry.shared.unregister(names: ["test_host_mutator"])
                FolderContextService._setCachedRootPathForTesting(nil)
            }

            _ = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                try await ToolRegistry.shared.execute(
                    name: "test_host_mutator", argumentsJSON: "{}")
            }

            let changes = await SandboxWorkspaceChangeTracker.shared.changes(for: sessionId)
            defer { Task { await SandboxWorkspaceChangeTracker.shared.purgeSession(sessionId) } }
            #expect(changes.count == 1)
            #expect(changes.first?.root == .hostFolder)
            #expect(changes.first?.relativePath == "host-tracked.txt")
            #expect(changes.first?.kind == .created)
            #expect(changes.first?.sourceTool == "test_host_mutator")
            #expect(changes.first?.agentName == folder.standardizedFileURL.path)
        }
    }

    /// A presence-only stand-in so `toolsByName` contains "sandbox_exec",
    /// which is the registry's combined-mode gate. Never executed.
    private struct FakeSandboxExecPresence: OsaurusTool, @unchecked Sendable {
        let name = "sandbox_exec"
        let description = "test-only sandbox exec stand-in"
        let parameters: JSONValue? = nil
        func execute(argumentsJSON: String) async throws -> String { "unused" }
    }

    /// Writable combined mode: a `file_write`-style call can mutate either
    /// filesystem, so the registry takes BOTH checkpoints. A call that
    /// writes only the host must produce exactly one Changes row (the
    /// sandbox checkpoint diffs to zero rows — no phantom attribution).
    @Test @MainActor
    func toolRegistry_dualCheckpointAttributesHostWriteToExactlyOneRow() async throws {
        try await SandboxTestLock.shared.run {
            let fm = FileManager.default
            let agentName = "chgtest-dual-agent"
            let home = OsaurusPaths.containerAgentDir(agentName)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: home) }

            let folder = fm.temporaryDirectory
                .appendingPathComponent("osu-dual-registry-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }

            let sessionId = UUID().uuidString
            let target = folder.appendingPathComponent("dual-tracked.txt")

            // Combined-mode gates: sandbox_exec registered + folder root +
            // captured sandbox identity.
            FolderContextService._setCachedRootPathForTesting(folder)
            ToolRegistry.shared.setActiveSandboxAgentContext(
                agentName: agentName,
                home: OsaurusPaths.inContainerAgentHome(agentName)
            )
            ToolRegistry.shared.register(FakeSandboxExecPresence())
            ToolRegistry.shared.register(FakeHostMutatingTool(fileURL: target))
            defer {
                ToolRegistry.shared.unregister(names: ["sandbox_exec", "test_host_mutator"])
                ToolRegistry.shared.unregisterAllBuiltinSandboxTools()
                FolderContextService._setCachedRootPathForTesting(nil)
            }

            _ = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                try await ToolRegistry.shared.execute(
                    name: "test_host_mutator", argumentsJSON: "{}")
            }

            let changes = await SandboxWorkspaceChangeTracker.shared.changes(for: sessionId)
            defer { Task { await SandboxWorkspaceChangeTracker.shared.purgeSession(sessionId) } }
            #expect(changes.count == 1, "host write must land exactly one row, got \(changes)")
            #expect(changes.first?.root == .hostFolder)
            #expect(changes.first?.relativePath == "dual-tracked.txt")
        }
    }
}
