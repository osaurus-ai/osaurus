//
//  AgentWorkingFolderTests.swift
//  OsaurusCoreTests
//
//  The agent's working folder is STICKY: the composer folder chip (and the
//  agent editor) write it onto the `Agent` record, and it is then inherited
//  by every folder-less background dispatch for that agent. This suite pins
//  the persistence API and the dispatch fallback:
//    • `updateWorkingFolder` / `clearWorkingFolder` round-trip through
//      `AgentStore` (JSON on disk under the test root) and the in-memory
//      snapshot `workingFolder(for:)` reads.
//    • The Default agent never carries a folder (no-op write, nil read).
//    • `BackgroundTaskManager.resolveDispatchFolder` uses the request's own
//      folder when it names one and falls back to the agent's working folder
//      otherwise — so a Schedule/Watcher without a folder, a self-schedule,
//      a delegation, or an HTTP dispatch all land in the agent's folder.
//    • The resolved folder actually reaches the `ExecutionContext` built for
//      the dispatch (`makeContextForTesting`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AgentWorkingFolderTests {

    // MARK: - Helpers

    private func makeAgent() -> Agent {
        Agent(
            name: "WorkingFolder-\(UUID().uuidString.prefix(6))",
            systemPrompt: "Test identity",
            agentAddress: "test-working-folder-\(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
    }

    private func agentFileURL(_ id: UUID) -> URL {
        OsaurusPaths.agents().appendingPathComponent("\(id.uuidString).json")
    }

    /// Decode the agent JSON as it sits on disk once `settled` accepts it —
    /// `AgentStore.save` writes on a background queue, and `add()` has just
    /// written an earlier version of the same file.
    private func onDiskJSON(
        for id: UUID,
        settled: ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let url = agentFileURL(id)
        let deadline = ContinuousClock.now + .seconds(5)
        var last: [String: Any]?
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: url),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                last = obj
                if settled(obj) { return obj }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let last { return last }
        throw WaitTimeout()
    }

    // MARK: - Persistence

    @Test("updateWorkingFolder persists bookmark + path on disk and in the snapshot")
    func updateWorkingFolder_persists() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            #expect(AgentManager.shared.workingFolder(for: agent.id) == nil)

            let bookmark = Data([0x10, 0x20, 0x30])
            let path = "/Users/tester/Projects/sticky"
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: bookmark, path: path)

            // In-memory snapshot (what fresh chats and dispatches read).
            let folder = try #require(AgentManager.shared.workingFolder(for: agent.id))
            #expect(folder.bookmark == bookmark)
            #expect(folder.path == path)
            #expect(AgentManager.shared.agent(for: agent.id)?.workingFolderBookmark == bookmark)
            #expect(AgentManager.shared.agent(for: agent.id)?.workingFolderPath == path)

            // On disk, under the NEW keys only.
            let json = try await onDiskJSON(for: agent.id) { $0["workingFolderPath"] != nil }
            #expect(json["workingFolderBookmark"] as? String == bookmark.base64EncodedString())
            #expect(json["workingFolderPath"] as? String == path)
            #expect(json["hostWorkspaceBookmark"] == nil)
            #expect(json["hostWorkspacePath"] == nil)

            // A cold load from the store agrees.
            let reloaded = try #require(AgentStore.load(id: agent.id))
            #expect(reloaded.workingFolderBookmark == bookmark)
            #expect(reloaded.workingFolderPath == path)
        }
    }

    @Test("clearWorkingFolder forgets the folder everywhere")
    func clearWorkingFolder_forgets() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(
                for: agent.id, bookmark: Data([1]), path: "/tmp/somewhere")
            #expect(AgentManager.shared.workingFolder(for: agent.id) != nil)

            AgentManager.shared.clearWorkingFolder(for: agent.id)

            #expect(AgentManager.shared.workingFolder(for: agent.id) == nil)
            #expect(AgentManager.shared.agent(for: agent.id)?.workingFolderBookmark == nil)
            #expect(AgentManager.shared.agent(for: agent.id)?.workingFolderPath == nil)
            let reloaded = try #require(AgentStore.load(id: agent.id))
            #expect(reloaded.workingFolderBookmark == nil)
            #expect(reloaded.workingFolderPath == nil)
        }
    }

    @Test("path-only folder (no bookmark) still counts as a working folder")
    func pathOnlyFolder_counts() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: "/tmp/plain")
            let folder = try #require(AgentManager.shared.workingFolder(for: agent.id))
            #expect(folder.bookmark == nil)
            #expect(folder.path == "/tmp/plain")

            // An empty path with no bookmark is "no folder", not a folder at "".
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: "")
            #expect(AgentManager.shared.workingFolder(for: agent.id) == nil)
        }
    }

    @Test("Default agent never carries a working folder")
    func defaultAgent_isNoop() async throws {
        try await ChatHistoryTestStorage.run {
            AgentManager.shared.updateWorkingFolder(
                for: Agent.defaultId, bookmark: Data([7]), path: "/tmp/default")
            #expect(AgentManager.shared.workingFolder(for: Agent.defaultId) == nil)
            #expect(AgentManager.shared.agent(for: Agent.defaultId)?.workingFolderBookmark == nil)
        }
    }

    @Test("unknown agent id → nil, no crash")
    func unknownAgent_isNil() async throws {
        try await ChatHistoryTestStorage.run {
            let ghost = UUID()
            AgentManager.shared.updateWorkingFolder(for: ghost, bookmark: Data([1]), path: "/x")
            #expect(AgentManager.shared.workingFolder(for: ghost) == nil)
        }
    }

    // MARK: - Dispatch fallback

    @Test("request without a folder inherits the agent's working folder")
    func dispatch_inheritsAgentFolder() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let bookmark = Data([0xA, 0xB])
            AgentManager.shared.updateWorkingFolder(
                for: agent.id, bookmark: bookmark, path: "/Users/tester/agent-folder")

            for source in [
                SessionSource.schedule, .watcher, .selfSchedule, .delegation, .http, .channel,
                .plugin,
            ] {
                let request = DispatchRequest(prompt: "go", agentId: agent.id, source: source)
                #expect(request.folderBookmark == nil)
                #expect(request.folderPath == nil)
                let resolved = BackgroundTaskManager.resolveDispatchFolder(for: request)
                #expect(resolved?.bookmark == bookmark, "\(source)")
                #expect(resolved?.path == "/Users/tester/agent-folder", "\(source)")

                let context = BackgroundTaskManager.shared.makeContextForTesting(request)
                #expect(context.folderBookmark == bookmark, "\(source)")
                #expect(context.folderPath == "/Users/tester/agent-folder", "\(source)")
            }
        }
    }

    @Test("request with its own folder keeps it over the agent's working folder")
    func dispatch_explicitFolderWins() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(
                for: agent.id, bookmark: Data([1, 1]), path: "/Users/tester/agent-folder")

            // Bookmark + path (GUI Watcher / Schedule).
            let full = DispatchRequest(
                prompt: "go", agentId: agent.id,
                folderPath: "/Users/tester/watched", folderBookmark: Data([2, 2]),
                source: .watcher
            )
            let resolvedFull = BackgroundTaskManager.resolveDispatchFolder(for: full)
            #expect(resolvedFull?.bookmark == Data([2, 2]))
            #expect(resolvedFull?.path == "/Users/tester/watched")

            // Path only (orchestrator-created Watcher).
            let pathOnly = DispatchRequest(
                prompt: "go", agentId: agent.id, folderPath: "/Users/tester/inbox", source: .watcher
            )
            let resolvedPath = BackgroundTaskManager.resolveDispatchFolder(for: pathOnly)
            #expect(resolvedPath?.bookmark == nil)
            #expect(resolvedPath?.path == "/Users/tester/inbox")

            // Bookmark only (plugin `folder_bookmark`).
            let bookmarkOnly = DispatchRequest(
                prompt: "go", agentId: agent.id, folderBookmark: Data([3, 3]), source: .plugin
            )
            let resolvedBookmark = BackgroundTaskManager.resolveDispatchFolder(for: bookmarkOnly)
            #expect(resolvedBookmark?.bookmark == Data([3, 3]))
            #expect(resolvedBookmark?.path == nil)

            let context = BackgroundTaskManager.shared.makeContextForTesting(full)
            #expect(context.folderBookmark == Data([2, 2]))
            #expect(context.folderPath == "/Users/tester/watched")
        }
    }

    @Test("agent without a working folder → dispatch stays folder-less")
    func dispatch_noFolderAnywhere_isNil() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let request = DispatchRequest(prompt: "go", agentId: agent.id, source: .schedule)
            #expect(BackgroundTaskManager.resolveDispatchFolder(for: request) == nil)
            let context = BackgroundTaskManager.shared.makeContextForTesting(request)
            #expect(context.folderBookmark == nil)
            #expect(context.folderPath == nil)
        }
    }

    @Test("clearing the working folder stops seeding dispatches")
    func dispatch_afterClear_isNil() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: Data([1]), path: "/tmp/a")
            let request = DispatchRequest(prompt: "go", agentId: agent.id, source: .selfSchedule)
            #expect(BackgroundTaskManager.resolveDispatchFolder(for: request) != nil)
            AgentManager.shared.clearWorkingFolder(for: agent.id)
            #expect(BackgroundTaskManager.resolveDispatchFolder(for: request) == nil)
        }
    }

    @Test("an inherited agent folder is restored onto the run as a dispatch folder")
    func dispatch_inheritedFolderActivatesOnTheRun() async throws {
        try await ChatHistoryTestStorage.run {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-agent-folder-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: dir.path)

            let request = DispatchRequest(prompt: "go", agentId: agent.id, source: .schedule)
            let context = BackgroundTaskManager.shared.makeContextForTesting(request)
            let failure = await context.activateFolderContextIfNeeded()
            #expect(failure == nil)
            let session = context.chatSession
            defer { session.folderState.clearFolder() }
            #expect(
                session.folderState.rootPath?.standardizedFileURL.resolvingSymlinksInPath().path
                    == dir.standardizedFileURL.resolvingSymlinksInPath().path)
            // Same contract as an explicit Watcher/Schedule folder: the run
            // must see this folder even for a sandbox-default agent.
            #expect(session.folderContextFromDispatchBookmark)
        }
    }

    @Test("reattach with no resolved folder drops the session's persisted folder")
    func reattach_noResolvedFolder_clearsSessionFolder() async throws {
        try await ChatHistoryTestStorage.run {
            let stale = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-stale-folder-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stale) }

            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

            let existing = ChatSessionData(
                title: "Prior schedule run",
                agentId: agent.id,
                source: .schedule,
                externalSessionKey: "schedule-\(UUID().uuidString)",
                folderPath: stale.path
            )
            let context = ExecutionContext(reattaching: existing)
            // `load` starts an async restore of the stale folder; wait so
            // the test actually observes it being present before we drop it.
            _ = await context.chatSession.folderState.contextWaitingForRestore()
            #expect(context.chatSession.folderState.hasActiveFolder)

            let failure = await context.activateFolderContextIfNeeded()
            #expect(failure == nil)
            #expect(!context.chatSession.folderState.hasActiveFolder)
            #expect(context.chatSession.folderState.persistedPath == nil)
            #expect(!context.chatSession.folderContextFromDispatchBookmark)
        }
    }

    @Test("reattach with a resolved folder overrides the session's persisted folder")
    func reattach_resolvedFolder_overridesSessionFolder() async throws {
        try await ChatHistoryTestStorage.run {
            let stale = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-stale-folder-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let current = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-current-folder-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: stale)
                try? FileManager.default.removeItem(at: current)
            }

            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: current.path)

            let existing = ChatSessionData(
                title: "Prior schedule run",
                agentId: agent.id,
                source: .schedule,
                externalSessionKey: "schedule-\(UUID().uuidString)",
                folderPath: stale.path
            )
            let resolved = BackgroundTaskManager.resolveDispatchFolder(
                for: DispatchRequest(prompt: "go", agentId: agent.id, source: .schedule)
            )
            let context = ExecutionContext(
                reattaching: existing,
                folderBookmark: resolved?.bookmark,
                folderPath: resolved?.path
            )
            let failure = await context.activateFolderContextIfNeeded()
            #expect(failure == nil)
            #expect(
                context.chatSession.folderState.rootPath?.standardizedFileURL
                    .resolvingSymlinksInPath().path
                    == current.standardizedFileURL.resolvingSymlinksInPath().path)
            #expect(context.chatSession.folderContextFromDispatchBookmark)
        }
    }
}

private struct WaitTimeout: Error {}
