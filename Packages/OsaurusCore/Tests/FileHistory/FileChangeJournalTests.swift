//
//  FileChangeJournalTests.swift
//  osaurusTests
//
//  The file history journal end to end: precise and shadow capture, exact
//  byte/mode/symlink restores, conflict-safe reverts (and forced reverts
//  that stay undoable), redo, per-file and rollback scopes, persistence
//  across relaunch, crash recovery of in-flight captures, purge + GC,
//  retention, the legacy import, and the "can't snapshot -> ask" gate.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct FileChangeJournalTests {

    private static let session = "journal-session"
    private var agent: String { FileHistoryTestEnv.agent }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    }

    /// Run `body` inside one capture of `targets` in the agent home.
    @discardableResult
    private func captured(
        _ env: FileHistoryTestEnv,
        session: String = FileChangeJournalTests.session,
        tool: String = "file_write",
        declared: [String]?,
        _ body: () throws -> Void
    ) async throws -> FileChangeSet? {
        let token = await env.journal.beginCapture(
            sessionId: session, toolName: tool,
            targets: [.init(kind: .agentHome, rootId: agent, declaredPaths: declared)])
        try body()
        return await env.journal.endCapture(token)
    }

    // MARK: - Precise capture + revert

    @Test func preciseCreateModifyDelete_revertRestoresExactly() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let mod = env.agentHome.appendingPathComponent("mod.txt")
        let gone = env.agentHome.appendingPathComponent("gone.txt")
        let new = env.agentHome.appendingPathComponent("new.txt")
        try write(mod, "v1")
        try write(gone, "keep me")

        let set = try #require(
            try await captured(env, declared: ["mod.txt", "gone.txt", "new.txt"]) {
                try self.write(mod, "v2")
                try FileManager.default.removeItem(at: gone)
                try self.write(new, "hello")
            })
        let kinds = Dictionary(uniqueKeysWithValues: set.entries.map { ($0.path, $0.kind) })
        #expect(kinds == ["mod.txt": .modified, "gone.txt": .deleted, "new.txt": .created])
        #expect(await env.journal.outstandingCount(for: Self.session) == 3)

        let summary = await env.journal.revert(.set(set.id), sessionId: Self.session)
        #expect(summary.isClean && summary.restored == 3, "\(summary)")
        #expect(read(mod) == "v1")
        #expect(read(gone) == "keep me")
        #expect(!exists(new))
        #expect(await env.journal.changeSet(id: set.id, sessionId: Self.session)?.status == .reverted)
        #expect(await env.journal.outstandingCount(for: Self.session) == 0)

        // The revert is itself a change set that can be undone ("redo").
        let revertId = try #require(summary.revertSetId)
        let revertSet = try #require(await env.journal.changeSet(id: revertId, sessionId: Self.session))
        #expect(revertSet.origin == .userRevert)
        #expect(revertSet.revertsSetId == set.id)
        let redo = await env.journal.revert(.set(revertId), sessionId: Self.session)
        #expect(redo.isClean, "\(redo)")
        #expect(read(mod) == "v2")
        #expect(!exists(gone))
        #expect(read(new) == "hello")
        #expect(await env.journal.changeSet(id: set.id, sessionId: Self.session)?.status == .applied)
    }

    @Test func createdParentDirectoriesAreRecordedAndRemovedOnRevert() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("a/b/c.txt")
        let set = try #require(
            try await captured(env, declared: ["a/b/c.txt"]) { try self.write(file, "deep") })
        #expect(Set(set.entries.map(\.path)) == ["a", "a/b", "a/b/c.txt"])

        let summary = await env.journal.revert(.set(set.id), sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        #expect(!exists(env.agentHome.appendingPathComponent("a")))
    }

    @Test func revertKeepsFoldersHoldingFilesTheChatDidNotCreate() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("out/report.txt")
        let set = try #require(
            try await captured(env, declared: ["out/report.txt"]) { try self.write(file, "r") })
        // The user drops their own file into the chat-created folder.
        let userFile = env.agentHome.appendingPathComponent("out/mine.txt")
        try write(userFile, "user")

        let summary = await env.journal.revert(.set(set.id), sessionId: Self.session)
        #expect(!exists(file))
        #expect(read(userFile) == "user")
        #expect(summary.failed == 1, "\(summary)")
    }

    @Test func binaryBytesModeAndSymlinksRoundTrip() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let fm = FileManager.default
        let blob = env.agentHome.appendingPathComponent("blob.bin")
        let script = env.agentHome.appendingPathComponent("run.sh")
        let link = env.agentHome.appendingPathComponent("latest")
        let bytes = Data((0 ..< 70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: blob)
        try write(script, "#!/bin/sh\necho hi\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "blob.bin")

        let set = try #require(
            try await captured(env, declared: ["blob.bin", "run.sh", "latest"]) {
                try Data("replaced".utf8).write(to: blob)
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
                try fm.removeItem(at: link)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "run.sh")
            })
        #expect(set.entries.count == 3)

        let summary = await env.journal.revert(.set(set.id), sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        #expect(try Data(contentsOf: blob) == bytes)
        let mode = try fm.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "blob.bin")
    }

    // MARK: - Conflicts

    @Test func conflictIsSkippedAndForcedOverwriteStaysUndoable() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("notes.txt")
        try write(file, "original")
        let set = try #require(
            try await captured(env, declared: ["notes.txt"]) { try self.write(file, "agent") })
        try write(file, "user edit")

        let preview = await env.journal.previewRevert(.set(set.id), sessionId: Self.session)
        #expect(preview.conflictCount == 1)

        let skipped = await env.journal.revert(.set(set.id), sessionId: Self.session)
        #expect(skipped.conflicted == 1 && skipped.restored == 0)
        #expect(skipped.revertSetId == nil)
        #expect(read(file) == "user edit")

        let forced = await env.journal.revert(.set(set.id), sessionId: Self.session, force: true)
        #expect(forced.restored == 1, "\(forced)")
        #expect(read(file) == "original")

        // The overwritten user edit was captured by the revert set.
        let revertId = try #require(forced.revertSetId)
        let redo = await env.journal.revert(.set(revertId), sessionId: Self.session)
        #expect(redo.isClean, "\(redo)")
        #expect(read(file) == "user edit")
    }

    @Test func revertThroughSymlinkedAncestorIsRefused() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let fm = FileManager.default
        let outside = env.tmp.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = env.agentHome.appendingPathComponent("dir/f.txt")
        try write(file, "before")
        let set = try #require(
            try await captured(env, declared: ["dir/f.txt"]) { try self.write(file, "after") })

        // Swap the folder for a symlink pointing outside the root.
        try fm.removeItem(at: env.agentHome.appendingPathComponent("dir"))
        try fm.createSymbolicLink(
            atPath: env.agentHome.appendingPathComponent("dir").path, withDestinationPath: outside.path)
        try write(outside.appendingPathComponent("f.txt"), "after")

        let summary = await env.journal.revert(.set(set.id), sessionId: Self.session, force: true)
        #expect(summary.restored == 0)
        #expect(read(outside.appendingPathComponent("f.txt")) == "after")
    }

    // MARK: - Scopes

    @Test func fileScopeAndRollbackSpanMultipleSets() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let a = env.agentHome.appendingPathComponent("a.txt")
        let b = env.agentHome.appendingPathComponent("b.txt")
        try write(a, "a0")
        let first = try #require(try await captured(env, declared: ["a.txt"]) { try self.write(a, "a1") })
        let second = try #require(try await captured(env, declared: ["a.txt"]) { try self.write(a, "a2") })
        _ = try #require(try await captured(env, declared: ["b.txt"]) { try self.write(b, "b1") })

        let net = await env.journal.netChanges(for: Self.session)
        #expect(net.count == 2)
        #expect(net.first { $0.key.path == "a.txt" }?.setIds == [first.id, second.id])

        // Reverting the OLDER set alone conflicts with the newer edit.
        let older = await env.journal.previewRevert(.set(first.id), sessionId: Self.session)
        #expect(older.conflictCount == 1)

        // File scope: straight back to the pre-chat bytes.
        let fileKey = FilePathKey(rootKind: .agentHome, rootId: agent, path: "a.txt")
        let fileRevert = await env.journal.revert(.file(fileKey), sessionId: Self.session)
        #expect(fileRevert.isClean, "\(fileRevert)")
        #expect(read(a) == "a0")
        #expect(read(b) == "b1")

        // Redo the file restore; then roll back everything from `second`.
        _ = await env.journal.revert(.set(try #require(fileRevert.revertSetId)), sessionId: Self.session)
        #expect(read(a) == "a2")
        let rollback = await env.journal.revert(.rollback(fromSet: second.id), sessionId: Self.session)
        #expect(rollback.isClean, "\(rollback)")
        #expect(read(a) == "a1")
        #expect(!exists(b))

        let all = await env.journal.revert(.all, sessionId: Self.session)
        #expect(all.isClean, "\(all)")
        #expect(read(a) == "a0")
        #expect(await env.journal.outstandingCount(for: Self.session) == 0)
    }

    @Test func dryRunOrNoOpCallRecordsNothing() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("same.txt")
        try write(file, "x")
        let set = try await captured(env, declared: ["same.txt"]) { try self.write(file, "x") }
        #expect(set == nil)
        #expect(await env.journal.changeSets(for: Self.session).isEmpty)
    }

    // MARK: - Shadow capture (opaque tools)

    @Test func shadowCaptureRecordsOpaqueChangesAndRenames() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let home = env.agentHome
        try write(home.appendingPathComponent("src/main.py"), "print(1)")
        try write(home.appendingPathComponent("old-name.txt"), "rename me")
        try write(home.appendingPathComponent("node_modules/dep/index.js"), "dep")

        let set = try #require(
            try await captured(env, tool: "sandbox_exec", declared: nil) {
                try self.write(home.appendingPathComponent("src/main.py"), "print(2)")
                try FileManager.default.moveItem(
                    at: home.appendingPathComponent("old-name.txt"),
                    to: home.appendingPathComponent("new-name.txt"))
                try self.write(home.appendingPathComponent("build/out.txt"), "artifact")
                try self.write(home.appendingPathComponent("node_modules/dep/index.js"), "changed")
            })
        let byPath = Dictionary(uniqueKeysWithValues: set.entries.map { ($0.path, $0) })
        #expect(byPath["src/main.py"]?.kind == .modified)
        #expect(byPath["old-name.txt"]?.kind == .deleted)
        #expect(byPath["new-name.txt"]?.fromPath == "old-name.txt")
        #expect(byPath["build/out.txt"]?.kind == .created)
        #expect(byPath["build"]?.kind == .created)
        #expect(!set.entries.contains { $0.path.hasPrefix("node_modules") })

        let summary = await env.journal.revert(.set(set.id), sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        #expect(read(home.appendingPathComponent("src/main.py")) == "print(1)")
        #expect(read(home.appendingPathComponent("old-name.txt")) == "rename me")
        #expect(!exists(home.appendingPathComponent("new-name.txt")))
        #expect(!exists(home.appendingPathComponent("build")))
    }

    @Test func shadowPicksUpUserEditsBetweenCalls() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("doc.txt")
        try write(file, "v1")
        try await captured(env, tool: "sandbox_exec", declared: nil) { try self.write(file, "v2") }
        // The user edits outside any tool call …
        try write(file, "user v3")
        // … so the next opaque call's "before" is the user's version.
        let set = try #require(
            try await captured(env, tool: "sandbox_exec", declared: nil) { try self.write(file, "v4") })
        let summary = await env.journal.revert(.set(set.id), sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        #expect(read(file) == "user v3")
    }

    /// A background job (or a parallel opaque call) holds the shadow while
    /// other opaque calls start and finish. Neither may lose its exact
    /// pre-image, and the shadow must be current once everything ends.
    @Test func overlappingShadowCapturesKeepTheirOwnPreImages() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let home = env.agentHome
        let jobFile = home.appendingPathComponent("job.txt")
        let toolFile = home.appendingPathComponent("tool.txt")
        try write(jobFile, "job v1")
        try write(toolFile, "tool v1")

        let job = await env.journal.beginCapture(
            sessionId: Self.session, toolName: "sandbox_exec_background",
            targets: [.init(kind: .agentHome, rootId: agent)])
        // The job writes; a foreground opaque call then starts and ends
        // while the job is still running.
        try write(jobFile, "job v2 (mid-run)")
        let tool = try #require(
            try await captured(env, tool: "sandbox_exec", declared: nil) { try self.write(toolFile, "tool v2") })
        #expect(tool.entries.map(\.path) == ["tool.txt"], "foreground call must not absorb the job's writes: \(tool.entries.map(\.path))")
        try write(jobFile, "job v3 (final)")
        let jobSet = try #require(await env.journal.endCapture(job))
        let jobEntry = try #require(jobSet.entries.first { $0.path == "job.txt" })
        #expect(jobEntry.kind == .modified)

        // Reverting the job restores the bytes from before the job started,
        // not the mid-run version the foreground call saw.
        let summary = await env.journal.revert(.set(jobSet.id), sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        #expect(read(jobFile) == "job v1")
        #expect(read(toolFile) == "tool v2")

        // The shadow caught up: a later opaque call sees the post-revert
        // state as its "before".
        try write(toolFile, "user v3")
        let later = try #require(
            try await captured(env, tool: "sandbox_exec", declared: nil) { try self.write(toolFile, "tool v4") })
        _ = await env.journal.revert(.set(later.id), sessionId: Self.session)
        #expect(read(toolFile) == "user v3")
    }

    // MARK: - Untracked gate

    private struct OpaqueWriter: OsaurusTool, @unchecked Sendable {
        let name = "test_opaque_writer"
        let description = "test-only opaque sandbox writer"
        let parameters: JSONValue? = nil
        var mutatesSandboxWorkspace: Bool { true }
        let fileURL: URL
        func execute(argumentsJSON: String) async throws -> String {
            try "written".write(to: fileURL, atomically: true, encoding: .utf8)
            return "ok"
        }
    }

    @Test func untrackableRootAsksFirstAndDenialPreventsTheCall() async throws {
        let env = try FileHistoryTestEnv.make(shadowEntryLimit: 3)
        defer { env.cleanup() }
        for i in 0 ..< 5 { try write(env.agentHome.appendingPathComponent("f\(i).txt"), "\(i)") }
        let target = env.agentHome.appendingPathComponent("new.txt")
        let tool = OpaqueWriter(fileURL: target)

        let denied = try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
            try await env.run(tool, "{}", sessionId: Self.session, sandboxAgent: agent)
        }
        #expect(EnvelopeAssertions.failureKind(denied) == "user_denied", "\(denied)")
        #expect(!exists(target))
        #expect(await env.journal.changeSets(for: Self.session).isEmpty)

        let approved = try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
            try await env.run(tool, "{}", sessionId: Self.session, sandboxAgent: agent)
        }
        #expect(approved == "ok")
        #expect(exists(target))
        // Recorded honestly as untracked, never as an undoable set.
        let sets = await env.journal.changeSets(for: Self.session)
        #expect(sets.count == 1)
        #expect(sets.first?.status == .untracked)
        #expect(sets.first?.isRevertible == false)
    }

    // MARK: - Persistence / recovery

    @Test func setsSurviveRelaunchAndRevertAfterward() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("persist.txt")
        try write(file, "before")
        let set = try #require(
            try await captured(env, declared: ["persist.txt"]) { try self.write(file, "after") })

        let relaunched = env.relaunched()
        let loaded = await relaunched.changeSets(for: Self.session)
        #expect(loaded.map(\.id) == [set.id])
        #expect(loaded.first?.entries.first?.before?.objectHash != nil)
        let summary = await relaunched.revert(.set(set.id), sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        #expect(read(file) == "before")
        #expect(await env.relaunched().changeSet(id: set.id, sessionId: Self.session)?.status == .reverted)
    }

    @Test func inlineCardLookupsResolveByIdAndToolCallAcrossRelaunch() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = env.agentHome.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(root.appendingPathComponent("card.txt"), "one\n")

        let result = try await env.run(
            FileWriteTool(rootPath: root), #"{"path": "card.txt", "content": "two\n"}"#,
            sessionId: Self.session, folder: root, toolCallId: "call-card")
        let diff = try #require(FileDiff.from(toolResult: result))
        let setId = try #require(diff.operationId)

        // A fresh journal has nothing cached: both lookups go to the DB.
        let relaunched = env.relaunched()
        #expect(await relaunched.changeSet(id: setId)?.sessionId == Self.session)
        #expect(await env.relaunched().changeSet(forToolCallId: "call-card")?.id == setId)
        #expect(await env.relaunched().changeSet(forToolCallId: "call-missing") == nil)

        let summary = await relaunched.revert(.set(setId), sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        let undo = try #require(await relaunched.activeRevert(of: setId, sessionId: Self.session))
        #expect(undo.id == summary.revertSetId)
        _ = await relaunched.revert(.set(undo.id), sessionId: Self.session)
        #expect(await relaunched.activeRevert(of: setId, sessionId: Self.session) == nil)
        #expect(read(root.appendingPathComponent("card.txt")) == "two\n")
    }

    @Test func inFlightCaptureIsRecoveredAfterCrash() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("crash.txt")
        try write(file, "before")
        let token = await env.journal.beginCapture(
            sessionId: Self.session, toolName: "file_write",
            targets: [.init(kind: .agentHome, rootId: agent, declaredPaths: ["crash.txt"])])
        try write(file, "after")
        // The app dies here: `endCapture` never runs.

        let relaunched = env.relaunched()
        // GC before anything else must not drop the pending pre-state blob.
        await relaunched.collectGarbage()
        let sets = await relaunched.changeSets(for: Self.session)
        #expect(sets.map(\.id) == [token.setId])
        let summary = await relaunched.revert(.set(token.setId), sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        #expect(read(file) == "before")
    }

    @Test func backgroundJobIsCapturedUntilFinalizedAndBlocksRevert() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let out = env.agentHome.appendingPathComponent("job-output.txt")
        await env.journal.beginBackgroundJob(
            sessionId: Self.session, agentName: agent, pid: "4242", toolName: "sandbox_exec")
        #expect(await env.journal.hasActiveBackgroundJobs(sessionId: Self.session))
        let blocked = await env.journal.revert(.all, sessionId: Self.session)
        #expect(blocked.blockedReason != nil)

        try write(out, "done")
        await env.journal.finalizeBackgroundJob(agentName: agent, pid: "4242")
        #expect(await !env.journal.hasActiveBackgroundJobs(sessionId: Self.session))
        let sets = await env.journal.changeSets(for: Self.session)
        #expect(sets.count == 1)
        #expect(sets.first?.origin == .externalJob)
        #expect(sets.first?.entries.map(\.path) == ["job-output.txt"])
    }

    /// Any in-flight capture for the chat (not only a background job)
    /// pauses reverts: the capture would claim the revert's writes and the
    /// tool may overwrite them next.
    @Test func foregroundCaptureBlocksRevertUntilItEnds() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("f.txt")
        try await captured(env, declared: ["f.txt"]) { try self.write(file, "1") }

        let token = await env.journal.beginCapture(
            sessionId: Self.session, toolName: "file_write",
            targets: [.init(kind: .agentHome, rootId: agent, declaredPaths: ["f.txt"])])
        #expect(await env.journal.hasActiveCaptures(sessionId: Self.session))
        let blocked = await env.journal.revert(.all, sessionId: Self.session)
        #expect(blocked.blockedReason != nil)
        #expect(read(file) == "1")

        _ = await env.journal.endCapture(token)
        #expect(await !env.journal.hasActiveCaptures(sessionId: Self.session))
        let summary = await env.journal.revert(.all, sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        #expect(!exists(file))
    }

    // MARK: - Purge / GC / retention

    /// Shadow clones hold a full copy of the root (`.env` included); they go
    /// when the root's history goes, and a capture still running for the
    /// purged chat is dropped rather than recorded later as an orphan.
    @Test func purgeDropsShadowsAndInFlightCaptures() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let home = env.agentHome
        try write(home.appendingPathComponent(".env"), "SECRET=1")
        try await captured(env, tool: "sandbox_exec", declared: nil) {
            try self.write(home.appendingPathComponent("out.txt"), "x")
        }
        let shadows = env.storeRoot.appendingPathComponent("shadows")
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: shadows.path)) ?? []).isEmpty)
        #expect(await env.journal.storedBytes() > 0)

        let token = await env.journal.beginCapture(
            sessionId: Self.session, toolName: "file_write",
            targets: [.init(kind: .agentHome, rootId: agent, declaredPaths: ["late.txt"])])
        await env.journal.purgeSession(Self.session)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: shadows.path)) ?? []).isEmpty)
        #expect(await !env.journal.hasActiveCaptures(sessionId: Self.session))

        try write(home.appendingPathComponent("late.txt"), "late")
        #expect(await env.journal.endCapture(token) == nil)
        #expect(await env.journal.changeSets(for: Self.session).isEmpty)
        #expect(await env.relaunched().changeSets(for: Self.session).isEmpty)
    }

    /// Once retention trims a file's earliest sets, "Revert File" can only
    /// reach the oldest change still kept — the preview must say so.
    @Test func retentionMarksPathsWhoseEarliestHistoryIsGone() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("big.txt")
        for round in 0..<4 {
            try await captured(env, declared: ["big.txt"]) {
                try self.write(file, String(repeating: "\(round)", count: 10_000))
            }
        }
        let key = FilePathKey(rootKind: .agentHome, rootId: agent, path: "big.txt")
        #expect(await env.journal.previewRevert(.file(key), sessionId: Self.session).items.first?.isTruncated == false)

        await env.journal.performMaintenance(.init(maxBytes: 25_000))
        #expect(await env.journal.truncatedPaths(sessionId: Self.session).contains(key))
        let preview = await env.journal.previewRevert(.file(key), sessionId: Self.session)
        #expect(preview.items.first?.isTruncated == true)
        // Survives relaunch, and a purge forgets it.
        #expect(await env.relaunched().truncatedPaths(sessionId: Self.session).contains(key))
        await env.journal.purgeSession(Self.session)
        #expect(await env.journal.truncatedPaths(sessionId: Self.session).isEmpty)
    }

    @Test func purgeDropsHistoryAndCollectsBlobs() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("p.txt")
        try write(file, String(repeating: "x", count: 10_000))
        try await captured(env, declared: ["p.txt"]) { try self.write(file, "small") }
        let objects = env.storeRoot.appendingPathComponent("objects")
        let stored = (try? FileManager.default.subpathsOfDirectory(atPath: objects.path)) ?? []
        #expect(stored.contains { ($0 as NSString).pathComponents.count == 2 })

        await env.journal.purgeSession(Self.session)
        #expect(await env.journal.changeSets(for: Self.session).isEmpty)
        #expect(await env.relaunched().changeSets(for: Self.session).isEmpty)
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: objects.path)) ?? []
        let blobs = files.filter { ($0 as NSString).pathComponents.count == 2 }
        #expect(blobs.isEmpty, "\(blobs)")
    }

    /// Crash after the set was persisted but before its write-ahead file
    /// was removed: recovery must not re-diff (and absorb later edits).
    @Test func recoveryLeavesAnAlreadyRecordedSetAlone() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("f.txt")
        try write(file, "v1")
        let set = try #require(try await captured(env, declared: ["f.txt"]) { try self.write(file, "v2") })
        let entry = try #require(set.entries.first)

        // Re-create the write-ahead file exactly as it looked mid-call.
        let record = FileChangeJournal.CaptureRecord(
            id: set.id, sessionId: Self.session, toolName: "file_write", toolCallId: nil, turnId: nil,
            origin: .agent, revertsSetId: nil, note: nil, createdAt: set.createdAt,
            roots: [
                .init(
                    kind: .agentHome, rootId: agent, mode: .precise, declared: ["f.txt"],
                    pre: ["f.txt": .init(state: entry.before)], preManifest: nil, untrackedReason: nil)
            ],
            jobKey: nil)
        let pending = env.storeRoot.appendingPathComponent("pending/\(set.id.uuidString).json")
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: pending)

        // The user edits after the "crash"; relaunch must not attribute it.
        try write(file, "user v3")
        let relaunched = env.relaunched()
        let sets = await relaunched.changeSets(for: Self.session)
        #expect(sets.count == 1)
        #expect(sets.first?.entries.first?.after?.signature == entry.after?.signature)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
    }

    /// A broken reference query must never read as "nothing is referenced":
    /// GC skips instead of deleting every snapshot.
    @Test func gcSkipsWhenReferenceQueryFails() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("keep.txt")
        try write(file, String(repeating: "k", count: 5_000))
        let set = try await captured(env, declared: ["keep.txt"]) { try self.write(file, "changed") }
        let beforeHash = try #require(set?.entries.first?.before?.signature).dropFirst("sha256:".count)
        #expect(env.journal.objects.contains(hash: String(beforeHash)))

        try env.db.executeForTesting("ALTER TABLE file_change_entries RENAME TO file_change_entries_broken")
        #expect(await env.journal.collectGarbage() == 0)
        #expect(env.journal.objects.contains(hash: String(beforeHash)), "GC deleted a blob it could not prove unreferenced")
        try env.db.executeForTesting("ALTER TABLE file_change_entries_broken RENAME TO file_change_entries")

        // With the table back, the blob is still referenced and still kept.
        _ = await env.journal.collectGarbage()
        #expect(env.journal.objects.contains(hash: String(beforeHash)))
    }

    @Test func retentionDropsOldSetsOnly() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("r.txt")
        try await captured(env, declared: ["r.txt"]) { try self.write(file, "1") }
        try await captured(env, declared: ["r.txt"]) { try self.write(file, "2") }
        #expect(await env.journal.applyRetention(.init(maxAgeDays: 7)) == 0)
        let later = Date().addingTimeInterval(8 * 86_400)
        #expect(await env.journal.applyRetention(.init(maxAgeDays: 7), now: later) == 2)
        #expect(await env.journal.changeSets(for: Self.session).isEmpty)
        // Files on disk are never touched by retention.
        #expect(read(file) == "2")
    }

    @Test func sizeCapTrimsOldestSetsFirst() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("big.txt")
        for round in 0..<4 {
            try await captured(env, declared: ["big.txt"]) {
                try self.write(file, String(repeating: "\(round)", count: 10_000))
            }
        }
        #expect(await env.journal.storedBytes() >= 40_000)
        let newest = try #require(await env.journal.changeSets(for: Self.session).max { $0.createdAt < $1.createdAt })
        await env.journal.performMaintenance(.init(maxBytes: 25_000))
        #expect(await env.journal.storedBytes() <= 25_000)
        let remaining = await env.journal.changeSets(for: Self.session)
        #expect(!remaining.isEmpty && remaining.count < 4)
        // The newest change survives, so the latest edit stays revertible.
        #expect(remaining.contains { $0.id == newest.id })
        #expect(read(file) == String(repeating: "3", count: 10_000))
    }

    @Test func retentionSettingDecodesFromOlderConfigsAndRoundTrips() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatConfiguration.default)) as! [String: Any]
        legacy["fileHistoryRetention"] = nil
        let decoded = try JSONDecoder().decode(
            ChatConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.fileHistoryRetention == .keepUntilChatDeleted)

        var config = ChatConfiguration.default
        config.fileHistoryRetention = .init(maxAgeDays: 30, maxBytes: 5 << 30)
        let roundTripped = try JSONDecoder().decode(ChatConfiguration.self, from: JSONEncoder().encode(config))
        #expect(roundTripped.fileHistoryRetention == config.fileHistoryRetention)
    }

    // MARK: - Legacy import

    @Test func legacySandboxChangesImportAsOneRevertibleSet() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let baselines = env.tmp.appendingPathComponent("sandbox-baselines", isDirectory: true)
        let live = env.agentHome.appendingPathComponent("legacy.txt")
        try write(live, "agent version")
        let baseline = baselines.appendingPathComponent(
            "\(Self.session)/\(agent)/home/legacy.txt")
        try write(baseline, "pre-chat version")
        let liveSig = try #require(FileObjectStore.liveSignature(at: live)?.signature)
        let baseSig = try #require(FileObjectStore.liveSignature(at: baseline)?.signature)
        try env.db.upsertSandboxChange(
            SandboxWorkspaceChange(
                sessionId: Self.session, agentName: agent, root: .agentHome,
                relativePath: "legacy.txt", entryType: .file, kind: .modified,
                baselineSignature: baseSig, currentSignature: liveSig, sourceTool: "sandbox_exec",
                firstChangedAt: Date(), lastChangedAt: Date()))

        let journal = FileChangeJournal(
            database: env.db, storeRoot: env.storeRoot, hostRootProvider: env.provider,
            legacyBaselinesRoot: baselines)
        let sets = await journal.changeSets(for: Self.session)
        #expect(sets.count == 1)
        #expect(sets.first?.origin == .imported)
        #expect(env.db.loadSandboxChanges(sessionId: Self.session).isEmpty)
        #expect(!exists(baselines.appendingPathComponent(Self.session)))

        let summary = await journal.revert(.set(try #require(sets.first?.id)), sessionId: Self.session)
        #expect(summary.isClean, "\(summary)")
        #expect(read(live) == "pre-chat version")
    }

    /// A legacy "modified" row whose baseline bytes are gone must not become
    /// a "created" entry — reverting that would delete the user's file.
    @Test func legacyModifiedRowWithoutBaselineNeverBecomesCreated() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let live = env.agentHome.appendingPathComponent("legacy.txt")
        try write(live, "agent version")
        let liveSig = try #require(FileObjectStore.liveSignature(at: live)?.signature)
        try env.db.upsertSandboxChange(
            SandboxWorkspaceChange(
                sessionId: Self.session, agentName: agent, root: .agentHome,
                relativePath: "legacy.txt", entryType: .file, kind: .modified,
                baselineSignature: nil, currentSignature: liveSig, sourceTool: "sandbox_exec",
                firstChangedAt: Date(), lastChangedAt: Date()))

        let journal = FileChangeJournal(
            database: env.db, storeRoot: env.storeRoot, hostRootProvider: env.provider,
            legacyBaselinesRoot: env.tmp.appendingPathComponent("no-baselines"))
        let sets = await journal.changeSets(for: Self.session)
        let entry = try #require(sets.first?.entries.first)
        #expect(entry.kind == .modified)
        #expect(entry.before?.isRestorable == false)

        let summary = await journal.revert(.set(try #require(sets.first?.id)), sessionId: Self.session)
        #expect(summary.failed == 1 && summary.restored == 0)
        #expect(read(live) == "agent version")
    }

    /// A damaged blob (bytes no longer hash to the key) is refused before
    /// the swap; the live file is untouched.
    @Test func corruptSnapshotIsRefusedBeforeSwap() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("c.txt")
        try write(file, "before")
        let set = try #require(
            try await captured(env, declared: ["c.txt"]) { try self.write(file, "after") })
        let hash = try #require(set.entries.first?.before?.objectHash)
        let blob = env.journal.objects.url(forHash: hash)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blob.path)
        try Data("garbage".utf8).write(to: blob)

        let summary = await env.journal.revert(.set(set.id), sessionId: Self.session)
        #expect(summary.failed == 1 && summary.restored == 0)
        #expect(read(file) == "after")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.agentHome.path)
            .filter { $0.hasPrefix(".osaurus-restore-") }
        #expect(leftovers.isEmpty)
    }

    @Test func missingSnapshotIsReportedUnrestorableNotAttempted() async throws {
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let file = env.agentHome.appendingPathComponent("m.txt")
        try write(file, "before")
        let set = try #require(
            try await captured(env, declared: ["m.txt"]) { try self.write(file, "after") })
        try FileManager.default.removeItem(at: env.storeRoot.appendingPathComponent("objects"))

        let preview = await env.journal.previewRevert(.set(set.id), sessionId: Self.session)
        #expect(preview.unrestorableCount == 1)
        let summary = await env.journal.revert(.set(set.id), sessionId: Self.session)
        #expect(summary.failed == 1 && summary.restored == 0)
        #expect(read(file) == "after")
    }

    // MARK: - Registry integration

    private struct FakeHostMutatingTool: OsaurusTool, @unchecked Sendable {
        let name = "test_host_mutator"
        let description = "test-only host folder mutator"
        let parameters: JSONValue? = nil
        var mutatesHostFolder: Bool { true }
        let fileURL: URL
        func declaredMutationTargets(argumentsJSON: String) -> [String]? { [fileURL.lastPathComponent] }
        func execute(argumentsJSON: String) async throws -> String {
            try "payload".write(to: fileURL, atomically: true, encoding: .utf8)
            return ChatExecutionContext.currentChangeSetId?.uuidString ?? "no-set"
        }
    }

    @Test @MainActor
    func toolRegistryCapturesHostFolderToolCalls() async throws {
        try await SandboxTestLock.shared.run {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory
                .appendingPathComponent("osu-journal-registry-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            let sessionId = UUID().uuidString
            let target = folder.appendingPathComponent("host-tracked.txt")

            ToolRegistry.shared.register(FakeHostMutatingTool(fileURL: target))
            defer { ToolRegistry.shared.unregister(names: ["test_host_mutator"]) }

            let result = try await ChatExecutionContext.$currentFolderRoot.withValue(folder) {
                try await ChatExecutionContext.$currentToolCallId.withValue("call-1") {
                    try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                        try await ToolRegistry.shared.execute(
                            name: "test_host_mutator", argumentsJSON: "{}")
                    }
                }
            }

            let sets = await FileChangeJournal.shared.changeSets(for: sessionId)
            defer { Task { await FileChangeJournal.shared.purgeSession(sessionId) } }
            #expect(sets.count == 1)
            let set = try #require(sets.first)
            #expect(result.contains(set.id.uuidString))
            #expect(set.toolName == "test_host_mutator")
            #expect(set.toolCallId == "call-1")
            #expect(set.entries.map(\.path) == ["host-tracked.txt"])
            #expect(set.entries.first?.rootKind == .hostFolder)
            #expect(
                await FileChangeJournal.shared.changeSet(forToolCallId: "call-1", sessionId: sessionId)?.id
                    == set.id)
        }
    }
}
