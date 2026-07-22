//
//  PerChatFolderIsolationTests.swift
//  osaurusTests
//
//  Pins the per-chat folder isolation contract: folder ownership lives on
//  each chat session, tools resolve the EXECUTING chat's root from the
//  TaskLocal execution scope (`ChatExecutionContext.currentFolderRoot`),
//  undo resolves against the root recorded on each operation, cached tool
//  state fingerprints fork per folder identity, and the legacy process-wide
//  bookmark is adopted exactly once.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PerChatFolderIsolationTests {

    // MARK: - Helpers

    private func makeRoot(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-isolation-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeContext(root: URL, isGitRepo: Bool = false) -> FolderContext {
        FolderContext(
            rootPath: root,
            projectType: .unknown,
            tree: "./\n",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: isGitRepo
        )
    }

    // MARK: - TaskLocal tool routing

    /// The same canonical tool instance (no fixed root) executes against
    /// whichever root the surrounding execution scope binds — two chats
    /// with different folders read their own files, never each other's.
    @Test func canonicalToolResolvesRootFromExecutionScope() async throws {
        let rootA = try makeRoot("a")
        let rootB = try makeRoot("b")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        try "alpha".write(
            to: rootA.appendingPathComponent("who.txt"), atomically: true, encoding: .utf8)
        try "bravo".write(
            to: rootB.appendingPathComponent("who.txt"), atomically: true, encoding: .utf8)

        let tool = FileReadTool()  // canonical: root comes from the scope

        let fromA = try await ChatExecutionContext.$currentFolderRoot.withValue(rootA) {
            try await tool.execute(argumentsJSON: #"{"path": "who.txt"}"#)
        }
        let fromB = try await ChatExecutionContext.$currentFolderRoot.withValue(rootB) {
            try await tool.execute(argumentsJSON: #"{"path": "who.txt"}"#)
        }

        #expect(fromA.contains("alpha") && !fromA.contains("bravo"))
        #expect(fromB.contains("bravo") && !fromB.contains("alpha"))
    }

    /// Two concurrent executions with different bound roots must not
    /// cross-route — this is the exact bug the per-chat isolation fixes
    /// (one chat's folder change no longer affects another mid-run).
    @Test func concurrentScopesDoNotCrossRoute() async throws {
        let rootA = try makeRoot("conc-a")
        let rootB = try makeRoot("conc-b")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        let write = FileWriteTool()
        let sessionA = "iso-a-\(UUID().uuidString)"
        let sessionB = "iso-b-\(UUID().uuidString)"

        async let a: String = ChatExecutionContext.$currentFolderRoot.withValue(rootA) {
            try await ChatExecutionContext.$currentSessionId.withValue(sessionA) {
                try await write.execute(
                    argumentsJSON: #"{"path": "out.txt", "content": "from-A"}"#)
            }
        }
        async let b: String = ChatExecutionContext.$currentFolderRoot.withValue(rootB) {
            try await ChatExecutionContext.$currentSessionId.withValue(sessionB) {
                try await write.execute(
                    argumentsJSON: #"{"path": "out.txt", "content": "from-B"}"#)
            }
        }
        let (resultA, resultB) = try await (a, b)
        #expect(ToolEnvelope.isSuccess(resultA), "got: \(resultA)")
        #expect(ToolEnvelope.isSuccess(resultB), "got: \(resultB)")

        let contentA = try String(
            contentsOf: rootA.appendingPathComponent("out.txt"), encoding: .utf8)
        let contentB = try String(
            contentsOf: rootB.appendingPathComponent("out.txt"), encoding: .utf8)
        #expect(contentA == "from-A")
        #expect(contentB == "from-B")

        await FileOperationLog.shared.clearAll()
    }

    /// With no folder bound anywhere in scope, a canonical folder tool
    /// returns the typed "no working folder" envelope instead of touching
    /// a process-wide default.
    @Test func noBoundRootReturnsUnavailableEnvelope() async throws {
        let tool = FileReadTool()
        let result = try await tool.execute(argumentsJSON: #"{"path": "who.txt"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(EnvelopeAssertions.failureKind(result) == "unavailable")
    }

    // MARK: - Per-operation undo roots

    /// Undo resolves against the root recorded ON THE OPERATION, so a
    /// session can undo a write made under root A even while a different
    /// root (another chat's folder) is currently bound.
    @Test func undoUsesRootRecordedOnOperation() async throws {
        await FileOperationLog.shared.clearAll()
        let rootA = try makeRoot("undo-a")
        let rootB = try makeRoot("undo-b")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let file = rootA.appendingPathComponent("undo.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let sessionId = "undo-\(UUID().uuidString)"
        let write = FileWriteTool()
        let opId: String = try await ChatExecutionContext.$currentFolderRoot.withValue(rootA) {
            try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                let result = try await write.execute(
                    argumentsJSON: #"{"path": "undo.txt", "content": "clobbered"}"#)
                return try #require(
                    EnvelopeAssertions.successPayload(result)?["operation_id"] as? String)
            }
        }

        // Undo while a DIFFERENT root is bound — the operation's own root wins.
        let undo = FileUndoTool()
        let result = try await ChatExecutionContext.$currentFolderRoot.withValue(rootB) {
            try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                try await undo.execute(argumentsJSON: #"{"operation_id": "\#(opId)"}"#)
            }
        }
        #expect(ToolEnvelope.isSuccess(result), "got: \(result)")
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == "original")

        await FileOperationLog.shared.clearAll()
    }

    // MARK: - Session tool-state fingerprint

    /// The fingerprint forks per folder identity: same mode + different
    /// root must invalidate cached tool state (the composed folder
    /// sections depend on which root is mounted).
    @Test func fingerprintForksPerFolderRoot() throws {
        let rootA = try makeRoot("fp-a")
        let rootB = try makeRoot("fp-b")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let a = SessionToolState.fingerprint(
            executionMode: .hostFolder(makeContext(root: rootA)), toolMode: .auto)
        let b = SessionToolState.fingerprint(
            executionMode: .hostFolder(makeContext(root: rootB)), toolMode: .auto)
        let aAgain = SessionToolState.fingerprint(
            executionMode: .hostFolder(makeContext(root: rootA)), toolMode: .auto)

        #expect(a != b, "different roots must fork the fingerprint")
        #expect(a == aAgain, "the identity must be stable for the same root")
        // The raw path must not appear (non-sensitive identity).
        #expect(!a.contains(rootA.path))

        let combinedA = SessionToolState.fingerprint(
            executionMode: .sandbox(hostRead: makeContext(root: rootA), hostWrite: false),
            toolMode: .auto)
        let combinedB = SessionToolState.fingerprint(
            executionMode: .sandbox(hostRead: makeContext(root: rootB), hostWrite: false),
            toolMode: .auto)
        #expect(combinedA != combinedB, "combined mode forks per root too")

        let plainSandbox = SessionToolState.fingerprint(
            executionMode: .sandbox(hostRead: nil, hostWrite: false), toolMode: .auto)
        #expect(plainSandbox == "sandbox/auto", "no folder -> no identity suffix")
    }

    // MARK: - Persistence round-trip

    /// `ChatSessionData` round-trips the folder bookmark + display path
    /// through Codable, and rows persisted before the fields existed
    /// decode with both nil.
    @Test func sessionDataCodableRoundTripsFolderFields() throws {
        let bookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var session = ChatSessionData(title: "with folder")
        session.folderBookmark = bookmark
        session.folderPath = "/Users/example/project"

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatSessionData.self, from: encoded)
        #expect(decoded.folderBookmark == bookmark)
        #expect(decoded.folderPath == "/Users/example/project")

        // Legacy row: no folder keys at all.
        var legacyJSON = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyJSON.removeValue(forKey: "folderBookmark")
        legacyJSON.removeValue(forKey: "folderPath")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try JSONDecoder().decode(ChatSessionData.self, from: legacyData)
        #expect(legacy.folderBookmark == nil)
        #expect(legacy.folderPath == nil)
    }

    /// The v10 columns round-trip through SQLite, and sessions without a
    /// folder store NULLs.
    @Test func databaseRoundTripsFolderFields() throws {
        let db = ChatHistoryDatabase()
        try db.openInMemory()

        let bookmark = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        var withFolder = ChatSessionData(title: "folder chat")
        withFolder.folderBookmark = bookmark
        withFolder.folderPath = "/Users/example/repo"
        try db.saveSession(withFolder)

        let withoutFolder = ChatSessionData(title: "plain chat")
        try db.saveSession(withoutFolder)

        let loadedWith = db.loadSession(id: withFolder.id)
        #expect(loadedWith?.folderBookmark == bookmark)
        #expect(loadedWith?.folderPath == "/Users/example/repo")

        let loadedWithout = db.loadSession(id: withoutFolder.id)
        #expect(loadedWithout != nil)
        #expect(loadedWithout?.folderBookmark == nil)
        #expect(loadedWithout?.folderPath == nil)
    }

    // MARK: - Session round-trip through ChatSession

    /// A stale (unresolvable) bookmark is dropped on restore but the
    /// display path survives, `toSessionData()` reflects the live folder
    /// state, and `reset()` clears it — a new chat starts folder-less.
    @Test @MainActor func chatSessionRestoreStaleBookmarkAndReset() async throws {
        let session = ChatSession()
        // An opaque blob can never resolve as a security-scoped bookmark —
        // this is exactly the "folder was moved/deleted since last launch"
        // path: the bookmark is dropped, the display path is kept.
        let restored = await session.folderState.restoreAndWait(
            bookmark: Data([0xAA, 0xBB]),
            path: "/Users/example/somewhere"
        )
        #expect(restored == nil)
        #expect(session.folderState.hasActiveFolder == false)
        #expect(session.folderState.persistedBookmark == nil, "stale bookmark must be dropped")
        let data = session.toSessionData()
        #expect(data.folderBookmark == nil)
        #expect(data.folderPath == "/Users/example/somewhere")

        session.reset()
        #expect(session.folderState.persistedBookmark == nil)
        #expect(session.folderState.persistedPath == nil)
        let afterReset = session.toSessionData()
        #expect(afterReset.folderBookmark == nil)
        #expect(afterReset.folderPath == nil)
    }

    // MARK: - Legacy global-bookmark migration

    /// The legacy process-wide `FolderContextBookmark` default is adopted
    /// by exactly ONE eligible chat, deleted from UserDefaults, and never
    /// offered to a second chat.
    @Test @MainActor func legacyGlobalBookmarkAdoptedExactlyOnce() throws {
        let key = "FolderContextBookmark"
        let previous = UserDefaults.standard.data(forKey: key)
        defer {
            ChatFolderState._resetLegacyAdoptionForTesting()
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        ChatFolderState._resetLegacyAdoptionForTesting()
        let legacy = Data([0x10, 0x20, 0x30])
        UserDefaults.standard.set(legacy, forKey: key)

        let first = ChatFolderState()
        first.adoptLegacyGlobalBookmarkIfNeeded()
        // The global key is consumed immediately, whether or not the
        // bookmark later resolves.
        #expect(UserDefaults.standard.data(forKey: key) == nil)

        // A second chat must not see any legacy default.
        UserDefaults.standard.set(legacy, forKey: key)  // even if re-planted
        let second = ChatFolderState()
        second.adoptLegacyGlobalBookmarkIfNeeded()
        #expect(second.persistedBookmark == nil)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Clearing one chat's folder leaves another untouched

    /// Two folder states are fully independent: clearing one leaves the
    /// other's persisted state intact.
    @Test @MainActor func clearingOneFolderStateLeavesOtherUntouched() async throws {
        let stateA = ChatFolderState()
        let stateB = ChatFolderState()
        _ = await stateA.restoreAndWait(bookmark: nil, path: "/tmp/a")
        _ = await stateB.restoreAndWait(bookmark: nil, path: "/tmp/b")

        stateA.clearFolder()
        #expect(stateA.persistedPath == nil)
        #expect(stateB.persistedPath == "/tmp/b")
    }

    // MARK: - Restore ordering (explicit dispatch precedence)

    /// A queued fire-and-forget `restore()` must NEVER supersede a LATER
    /// `restoreAndWait` (the explicit dispatch-bookmark path), regardless of
    /// task scheduling. The generation is claimed synchronously at call
    /// time, so by the time the queued task runs it is already stale — with
    /// generation claimed at task-run time instead, the queued restore
    /// (which suspends resolving its bookmark off-actor) would apply LAST
    /// and clobber the explicit restore's state.
    @Test @MainActor func queuedRestoreNeverSupersedesLaterExplicitRestore() async throws {
        let state = ChatFolderState()

        // Queued but not yet running (nothing on this actor has yielded).
        state.restore(bookmark: Data([0x51]), path: "/tmp/queued")
        let queued = try #require(state.pendingRestore)

        // Explicit restore issued AFTER must win…
        _ = await state.restoreAndWait(bookmark: nil, path: "/tmp/explicit")
        // …even once the earlier queued task has fully run its course.
        _ = await queued.value

        #expect(state.persistedPath == "/tmp/explicit")
        #expect(state.persistedBookmark == nil)
    }

    // MARK: - Prompt folder mutation persistence (durable select/clear)

    /// User folder mutations fire the persistence callback exactly once per
    /// real change; restores never fire it (they ARE persistence), and
    /// clearing an already-empty state is a no-op — so `reset()` can't dirty
    /// a fresh session.
    @Test @MainActor func mutationCallbackFiresOnlyForRealUserMutations() async throws {
        let state = ChatFolderState()
        var fired = 0
        state.onFolderMutated = { fired += 1 }

        _ = await state.restoreAndWait(bookmark: nil, path: "/tmp/restored")
        #expect(fired == 0, "restore is persistence, not a user mutation")

        state.clearFolder()
        #expect(fired == 1, "clearing an actual folder is a user mutation")

        state.clearFolder()
        #expect(fired == 1, "clearing empty state must not re-fire")
    }

    /// Clearing a folder mid-conversation persists PROMPTLY — the session
    /// row on disk loses its folder without waiting for the next turn or
    /// window teardown (which is where a crash/force-quit would lose it).
    @Test @MainActor func folderClearPersistsWithoutWaitingForNextTurn() async throws {
        try await ChatHistoryTestStorage.run {
            let existingId = UUID()
            var existing = ChatSessionData(
                id: existingId,
                title: "Folder chat",
                turns: [ChatTurnData(role: .user, content: "hello")]
            )
            existing.folderPath = "/tmp/previous-folder"
            ChatSessionsManager.shared.save(existing)

            let session = ChatSession()
            session.load(from: existing)
            // Let load()'s fire-and-forget restore settle first, so it can't
            // re-apply the old path after the clear below.
            _ = await session.folderState.contextWaitingForRestore()
            #expect(session.folderState.persistedPath == "/tmp/previous-folder")

            // No send, no teardown — the clear alone must reach disk.
            session.folderState.clearFolder()
            try await waitUntil(timeout: .seconds(3)) {
                ChatSessionStore.load(id: existingId)?.folderPath == nil
            }
        }
    }

    // MARK: - Send readiness (await in-flight restore)

    /// `contextWaitingForRestore()` — what the send path composes with —
    /// covers an in-flight restore: when it returns, the restore has fully
    /// applied instead of the send racing it and composing folder-less.
    @Test @MainActor func contextWaitingForRestoreCoversInFlightRestore() async throws {
        let state = ChatFolderState()

        // Nothing pending: immediate nil, no hang.
        let idle = await state.contextWaitingForRestore()
        #expect(idle == nil)

        // Queue a fire-and-forget restore whose bookmark resolution suspends
        // off the main actor — exactly the window where an unawaited send
        // would compose before the folder loaded.
        state.restore(bookmark: Data([0xAA, 0xBB]), path: "/tmp/pending")
        _ = await state.contextWaitingForRestore()

        // The restore fully applied before the wait returned: display path
        // landed, stale bookmark dropped.
        #expect(state.persistedPath == "/tmp/pending")
        #expect(state.persistedBookmark == nil)
    }

    /// End-to-end readiness with a REAL security-scoped bookmark: a send
    /// arriving while the restore is still resolving picks up the built
    /// folder context.
    @Test @MainActor func contextWaitingForRestoreReturnsBuiltContext() async throws {
        let root = try makeRoot("readiness")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark: Data
        do {
            bookmark = try root.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Harness can't mint security-scoped bookmarks here; the
            // stale-bookmark variant above still pins the await semantics.
            return
        }

        let state = ChatFolderState()
        state.restore(bookmark: bookmark, path: root.path)
        let context = await state.contextWaitingForRestore()

        #expect(
            context?.rootPath.standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(state.hasActiveFolder)
        state.clearFolder()
    }
}

// MARK: - Local waitUntil (file-private to avoid colliding with other test files)

private func waitUntil(
    timeout: Duration,
    _ predicate: @MainActor @escaping () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw NSError(domain: "PerChatFolderIsolationTests", code: 1)
}
