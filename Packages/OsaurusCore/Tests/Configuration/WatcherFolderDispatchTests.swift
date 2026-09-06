//
//  WatcherFolderDispatchTests.swift
//  osaurus
//
//  Pins the contract that a Watcher run works IN the folder it was pointed
//  at (the "monitored folder is /workspace/agents/<id>" failure, reported
//  again on 0.24.6):
//
//  - the trigger's dispatch request carries the RESOLVED watched folder
//    (not the nil display path of a bookmark-only watcher) plus the bookmark;
//  - restoring that folder onto the run's session marks it as a dispatch
//    folder, so the execution mode is `.hostFolder(<that folder>)` even
//    for an autonomous (sandbox-default) agent, the turn's folder root is
//    bound, and both the system-prompt section and the trigger prompt name
//    the folder;
//  - a run with NO folder keeps the agent's sandbox workspace;
//  - inside a dispatched host-folder run the file tools never answer a
//    `/workspace/...` path from the VM (the autonomous agent's sandbox stays
//    registered process-wide, so the bridge used to be bound in host-folder
//    mode and a repeated `file_read("/workspace/agents/<id>")` got a real
//    `SOUL.md` + `plugins/` listing);
//  - a stale / unresolvable bookmark falls back to the plain path exactly as
//    the Watcher engine itself does when it decides to watch the folder.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WatcherFolderDispatchTests {

    // MARK: - Helpers

    private func makeWatchedFolder(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-watch-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "memo".write(
            to: dir.appendingPathComponent("New Recording 12.m4a"), atomically: true, encoding: .utf8)
        return dir
    }

    private func registerSandboxExec() {
        BuiltinSandboxTools.register(
            agentId: "watcher-folder-test",
            agentName: "watcher-folder-test",
            config: AutonomousExecConfig(enabled: true)
        )
    }

    private func sameFolder(_ a: URL?, _ b: URL) -> Bool {
        a?.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Trigger → dispatch request

    @Test
    func dispatchRequestCarriesTheResolvedFolderAndTheBookmark() {
        let bookmark = Data([0x01, 0x02, 0x03])
        // A GUI watcher whose display path was never stored: only the
        // bookmark exists. The engine resolves the bookmark to a real path
        // for its own FSEvents stream — that path must reach the run too.
        let watcher = Watcher(
            name: "Voice Memo Watcher",
            instructions: "transcribe",
            agentId: UUID(),
            watchPath: nil,
            watchBookmark: bookmark
        )
        let request = WatcherManager.shared.makeDispatchRequest(
            for: watcher,
            prompt: "p",
            resolvedWatchPath: "/Users/probe/Music/Voice Memos"
        )
        #expect(request.folderPath == "/Users/probe/Music/Voice Memos")
        #expect(request.folderBookmark == bookmark)
        #expect(request.source == .watcher)
        #expect(request.externalSessionKey == watcher.id.uuidString)
        #expect(request.agentId == watcher.agentId)
        #expect(request.loadIntent == .background)

        // No resolved path (engine could not resolve) → the display path
        // still travels, so the run's plain-path fallback has something.
        let pathOnly = Watcher(
            name: "Config Watcher", instructions: "organize", agentId: UUID(),
            watchPath: "/Users/probe/Inbox", watchBookmark: nil
        )
        let fallback = WatcherManager.shared.makeDispatchRequest(
            for: pathOnly, prompt: "p", resolvedWatchPath: nil
        )
        #expect(fallback.folderPath == "/Users/probe/Inbox")
        #expect(fallback.folderBookmark == nil)
    }

    // MARK: - Chosen folder → run context + prompt

    @Test
    func chosenFolder_runContextUsesThatFolderAndThePromptNamesIt() async throws {
        let dir = try makeWatchedFolder("chosen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentId = UUID()

        let context = ExecutionContext(
            agentId: agentId,
            title: "Voice Memo Watcher",
            folderBookmark: nil,
            folderPath: dir.path,
            source: .watcher
        )
        let failure = await context.activateFolderContextIfNeeded()
        #expect(failure == nil, "a readable chosen folder must restore without a preamble")

        let session = context.chatSession
        defer { session.folderState.clearFolder() }
        #expect(sameFolder(session.folderState.rootPath, dir))
        #expect(session.folderContextFromDispatchBookmark, "the folder must be marked as a dispatch target")

        // Execution mode: an autonomous (sandbox-default) agent with the
        // sandbox registered still runs IN the chosen folder.
        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }
            let mode = session.resolveExecutionModeForSend(agentId: agentId, autonomousEnabled: true)
            #expect(mode.usesHostFolderTools)
            #expect(!mode.usesSandboxTools)
            #expect(sameFolder(mode.folderContext?.rootPath, dir))
        }

        // Turn root binding: the folder is NOT suspended for the sandbox
        // when it came from a dispatch.
        let root = ChatSession.turnFolderRoot(
            sandboxEnabled: true,
            folderFromDispatch: session.folderContextFromDispatchBookmark,
            folderRoot: session.folderState.rootPath
        )
        #expect(sameFolder(root, dir))

        // Prompt: the system-prompt working-directory section names the
        // folder (what `.hostFolder` composes) and lists its files …
        let folderContext = try #require(session.folderState.context)
        let section = SystemPromptTemplates.leanFolderContext(from: folderContext)
        #expect(section.contains("## Working directory"))
        #expect(section.contains(folderContext.rootPath.path))
        #expect(!section.contains("/workspace/agents"))
        // … and the trigger prompt anchors the run on the same folder.
        let watcher = Watcher(
            name: "Voice Memo Watcher", instructions: "transcribe new voice memos",
            agentId: agentId, watchPath: nil, watchBookmark: Data([0x01])
        )
        let prompt = WatcherManager.shared.buildDispatchPrompt(
            for: watcher, iteration: 1, resolvedWatchPath: dir.path,
            changedPaths: ["New Recording 12.m4a"]
        )
        #expect(prompt.contains("work HERE, not in any other directory): \(dir.path)"))
        #expect(prompt.contains("New Recording 12.m4a"))
    }

    @Test
    func chosenFolderViaBookmark_restoresTheSameFolder() async throws {
        let dir = try makeWatchedFolder("bookmark")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark: Data
        do {
            bookmark = try dir.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Harness can't mint security-scoped bookmarks here; the
            // path-only and stale-bookmark variants pin the rest.
            return
        }

        let context = ExecutionContext(
            agentId: UUID(),
            folderBookmark: bookmark,
            folderPath: nil,  // bookmark-only GUI watcher shape
            source: .watcher
        )
        let failure = await context.activateFolderContextIfNeeded()
        defer { context.chatSession.folderState.clearFolder() }
        #expect(failure == nil)
        #expect(sameFolder(context.chatSession.folderState.rootPath, dir))
        #expect(context.chatSession.folderContextFromDispatchBookmark)
    }

    // MARK: - No folder → agent workspace

    @Test
    func noFolder_runStaysInTheAgentWorkspace() async {
        let agentId = UUID()
        let context = ExecutionContext(agentId: agentId, source: .watcher)
        let failure = await context.activateFolderContextIfNeeded()
        #expect(failure == nil)

        let session = context.chatSession
        #expect(session.folderState.rootPath == nil)
        #expect(!session.folderContextFromDispatchBookmark)

        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }
            let mode = session.resolveExecutionModeForSend(agentId: agentId, autonomousEnabled: true)
            #expect(mode.usesSandboxTools)
            #expect(!mode.usesHostFolderTools)
            #expect(mode.folderContext == nil)
        }
        #expect(
            ChatSession.turnFolderRoot(sandboxEnabled: true, folderFromDispatch: false, folderRoot: nil)
                == nil)
    }

    /// An INTERACTIVE folder (user picked it in the chat UI, sandbox left
    /// on) keeps the historical sandbox-priority contract: the folder is
    /// suspended, not bridged. Only a dispatched folder wins.
    @Test
    func interactiveFolder_keepsSandboxPriority() async throws {
        let dir = try makeWatchedFolder("interactive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentId = UUID()
        let session = ChatSession()
        session.agentId = agentId
        _ = await session.folderState.restoreAndWait(bookmark: nil, path: dir.path)
        defer { session.folderState.clearFolder() }
        #expect(session.folderState.hasActiveFolder)
        #expect(!session.folderContextFromDispatchBookmark)

        await SandboxTestLock.shared.run {
            registerSandboxExec()
            defer { ToolRegistry.shared.unregisterAllSandboxTools() }
            let mode = session.resolveExecutionModeForSend(agentId: agentId, autonomousEnabled: true)
            #expect(mode.usesSandboxTools)
            #expect(!mode.usesHostFolderTools)
        }
        #expect(
            ChatSession.turnFolderRoot(
                sandboxEnabled: true, folderFromDispatch: false, folderRoot: dir) == nil)
        // Sandbox off → the interactive folder resumes.
        #expect(
            sameFolder(
                ChatSession.turnFolderRoot(
                    sandboxEnabled: false, folderFromDispatch: false, folderRoot: dir), dir))
    }

    // MARK: - File tools inside a dispatched host-folder run

    @Test
    func dispatchFolderRun_neverServesWorkspacePathsFromTheVM() async throws {
        let dir = try makeWatchedFolder("route")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bridge = SandboxReadBridge(agentName: "agent-x", home: "/workspace/agents/agent-x")

        // Default contract (interactive / VM shapes) is untouched: a bridge
        // with no host root is VM mode, `/workspace` is the sandbox.
        ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
            #expect(combinedFileRoute(path: "/workspace/agents/agent-x") == .sandbox)
            #expect(combinedFileRoute(path: ".") == .sandbox)
        }
        ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
            ChatExecutionContext.$currentFolderRoot.withValue(dir) {
                #expect(combinedFileRoute(path: "/workspace/agents/agent-x") == .sandbox)
                #expect(combinedFileRoute(path: ".") == .host)
            }
        }

        // Dispatched host-folder run: the watched folder is the ONLY
        // filesystem, whatever is registered process-wide.
        ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
            ChatExecutionContext.$currentFolderRoot.withValue(dir) {
                ChatExecutionContext.$hostFolderIsDispatchTarget.withValue(true) {
                    #expect(combinedFileRoute(path: "/workspace/agents/agent-x") == .host)
                    #expect(combinedFileRoute(path: "/workspace/shared/x.txt") == .host)
                    #expect(combinedFileRoute(path: ".") == .host)
                }
            }
        }

        // End to end through the tool body: with the bridge bound (the
        // pre-fix shape) the listing of the agent's VM home is refused on the
        // host route and the model is told to stay relative to the working
        // directory; a relative listing shows the watched folder's files.
        // `file_read` is the tool the model actually calls; it lists a
        // directory when given one. The host route rejects the absolute VM
        // path by throwing `FolderToolError.invalidArguments` (the registry
        // folds that into an envelope for the model) — accept either shape.
        let read = FileReadTool()
        let refused: String = await ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
            await ChatExecutionContext.$currentFolderRoot.withValue(dir) {
                await ChatExecutionContext.$hostFolderIsDispatchTarget.withValue(true) {
                    do {
                        return try await read.execute(
                            argumentsJSON: #"{"path":"/workspace/agents/agent-x"}"#)
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
        }
        #expect(refused.contains("relative to the working directory"), "got: \(refused)")
        #expect(!refused.contains("SOUL.md"))

        let listing: String = await ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
            await ChatExecutionContext.$currentFolderRoot.withValue(dir) {
                await ChatExecutionContext.$hostFolderIsDispatchTarget.withValue(true) {
                    do {
                        return try await read.execute(argumentsJSON: #"{"path":"."}"#)
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
        }
        #expect(listing.contains("New Recording 12.m4a"), "got: \(listing)")
    }

    // MARK: - Bookmark fallback

    @Test
    func staleBookmarkFallsBackToThePlainPath() async throws {
        let dir = try makeWatchedFolder("stale")
        defer { try? FileManager.default.removeItem(at: dir) }

        // An opaque blob can never resolve as a bookmark. The Watcher engine
        // falls back to the plain path to watch the folder; the run must
        // reach the same folder instead of failing (0.24.6: silently ran in
        // the sandbox; later: "could not be read" over a readable folder).
        let state = ChatFolderState()
        let restored = await state.restoreAndWait(bookmark: Data([0xAA, 0xBB]), path: dir.path)
        defer { state.clearFolder() }
        #expect(restored != nil)
        #expect(sameFolder(state.rootPath, dir))
        #expect(state.persistedBookmark == nil, "the stale bookmark must be dropped")
        #expect(state.persistedPath != nil)

        // No path to fall back to → still an honest nil, never an empty tree.
        let bare = ChatFolderState()
        let none = await bare.restoreAndWait(bookmark: Data([0xAA, 0xBB]), path: nil)
        #expect(none == nil)
        #expect(!bare.hasActiveFolder)
    }

    /// A folder that really cannot be read never silently becomes a
    /// sandbox run: the run proceeds (never blocked) with the explicit
    /// preamble naming the folder, and is NOT marked as a dispatch folder.
    @Test
    func unreadableFolder_isReportedNotSilentlySwappedForTheSandbox() async {
        let missing = "/tmp/osaurus-missing-\(UUID().uuidString)"
        let context = ExecutionContext(
            agentId: UUID(), folderBookmark: Data([0xAA, 0xBB]), folderPath: missing, source: .watcher
        )
        let failure = await context.activateFolderContextIfNeeded()
        #expect(failure?.contains("could not") == true)
        #expect(failure?.contains(missing) == true)
        #expect(!context.chatSession.folderContextFromDispatchBookmark)
        #expect(context.chatSession.folderState.rootPath == nil)
    }
}
