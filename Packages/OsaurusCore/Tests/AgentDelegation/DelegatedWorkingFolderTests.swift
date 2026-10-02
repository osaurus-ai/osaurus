//
//  DelegatedWorkingFolderTests.swift
//  OsaurusCoreTests — Agent delegation
//
//  Issue #2703: "the orchestrator can't save files through agents". A
//  delegated child is a REAL chat session of the target agent, so its file
//  access uses the target agent's configured Working Folder, or inherits the
//  launcher's active chat folder when the target has none. This suite pins the whole chain so
//  a "save X to disk" delegation can actually complete:
//
//    • a folder-less `.delegation` dispatch for an agent WITH a Working
//      Folder mounts that folder as a dispatch target, resolves to
//      `.hostFolder`, binds the turn root, and composes a schema that
//      carries the host WRITE tools (`file_write` / `file_edit`) while the
//      structural strips (spawn tools + `clarify`) still apply;
//    • the same dispatch for an agent WITHOUT a Working Folder composes no
//      host file tools at all — the child cannot write to disk;
//    • the child-side delivery contract names the folder and steers file
//      output to it (and stays folder-less / remote otherwise);
//    • the orchestrator-side spawn guidance advertises which listed agents
//      have a working folder, from the same `AgentManager.workingFolder`
//      source of truth the dispatch fallback reads.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct DelegatedWorkingFolderTests {

    // MARK: - Helpers

    private func makeAgent() -> Agent {
        Agent(
            name: "Writer-\(UUID().uuidString.prefix(6))",
            systemPrompt: "Writes reports",
            agentAddress: "test-delegated-folder-\(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
    }

    /// Run `body` with freshly added agents under isolated chat-history
    /// storage AND a sandboxed delegation store. `AgentManager.add` appends
    /// every new agent to the Default spawn pool (`registerInDefaultSpawnPool`)
    /// and `delete` prunes it, so without the store sandbox these writes race
    /// the pool assertions in `OrchestratorSpawnDefaultsTests`. Cleanup is
    /// AWAITED (not a fire-and-forget `defer { Task {…} }`) for the same
    /// reason.
    ///
    /// Lock order is the canonical Storage → Sandbox (both taken by
    /// `ChatHistoryTestStorage.run`) → SubagentStore innermost. Taking the
    /// store lease outermost deadlocked the whole suite against
    /// `OrchestratorSpawnDefaultsTests` / `SpawnPermissionGateTests`, which
    /// nest it canonically: each side held one lock and waited on the other,
    /// and every later storage-locked test queued behind them forever.
    private func withAgents(
        _ count: Int,
        _ body: @MainActor ([Agent]) async throws -> Void
    ) async throws {
        try await ChatHistoryTestStorage.run {
            let lease = await acquireSubagentStoreSandbox("delegated-working-folder")
            defer { lease.release() }
            let agents = (0..<count).map { _ in makeAgent() }
            for agent in agents { AgentManager.shared.add(agent) }
            var thrown: Error?
            do {
                try await body(agents)
            } catch {
                thrown = error
            }
            for agent in agents { _ = await AgentManager.shared.delete(id: agent.id) }
            if let thrown { throw thrown }
        }
    }

    private func makeFolder(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-delegated-folder-\(label)-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sameFolder(_ a: URL?, _ b: URL) -> Bool {
        a?.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static let hostWriteTools: Set<String> = ["file_write", "file_edit"]

    // MARK: - The launching chat owns its folder

    @Test("an existing launcher chat keeps delegating its folder after the agent default is cleared")
    func launcherChatFolderSurvivesDefaultClearThroughChildRead() async throws {
        let dir = try makeFolder("launcher")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "fresh-launcher-content".write(
            to: dir.appendingPathComponent("facts.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await withAgents(2) { agents in
            let parent = agents[0]
            let worker = agents[1]
            AgentManager.shared.updateWorkingFolder(for: parent.id, bookmark: nil, path: dir.path)
            let session = ChatSession()
            session.agentId = parent.id
            session.sessionId = UUID()
            _ = try #require(await session.folderState.restoreAndWait(bookmark: nil, path: dir.path))
            defer { session.folderState.clearFolder() }
            AgentManager.shared.clearWorkingFolder(for: parent.id)

            let launcher = ChatExecutionContext.$currentChatSessionBox.withValue(WeakChatSessionBox(session)) {
                ChatExecutionContext.$currentFolderRoot.withValue(dir) {
                    AgentDelegationDispatcher.resolveLauncherWorkingFolder(
                        scopeAgentId: parent.id,
                        parentSessionId: session.sessionId?.uuidString
                    )
                }
            }
            let child = AgentDelegationDispatcher.resolveChildWorkingFolder(targetFolder: nil, launcherFolder: launcher)
            #expect(child.inherited)
            #expect(child.folder?.path == dir.path)
            let request = DispatchRequest(
                prompt: "read facts.txt",
                agentId: worker.id,
                folderPath: child.folder?.path,
                folderBookmark: child.folder?.bookmark,
                source: .delegation
            )
            let context = BackgroundTaskManager.shared.makeContextForTesting(request)
            #expect(await context.activateFolderContextIfNeeded() == nil)
            defer { context.chatSession.folderState.clearFolder() }
            #expect(sameFolder(context.chatSession.folderState.rootPath, dir))
            let result = try await ChatExecutionContext.$currentFolderRoot.withValue(
                context.chatSession.folderState.rootPath
            ) {
                try await FileReadTool().execute(argumentsJSON: "{\"path\":\"facts.txt\"}")
            }
            #expect(result.contains("fresh-launcher-content"))
        }
    }

    enum LauncherFolderCase: CaseIterable {
        case current, cleared, suspended, readOnly, differentRoot, differentAgent, differentSession, stale, defaultAgent
    }

    @Test(
        "launcher folder scope overrides defaults without granting a cleared or unrelated folder",
        arguments: LauncherFolderCase.allCases
    )
    func launcherChatFolderScope(_ scenario: LauncherFolderCase) async throws {
        let dir = try makeFolder("chat")
        let agentDir = try makeFolder("default")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: agentDir)
        }
        try await withAgents(2) { agents in
            let parent = agents[0]
            AgentManager.shared.updateWorkingFolder(for: parent.id, bookmark: nil, path: agentDir.path)
            let session = ChatSession()
            session.agentId = scenario == .defaultAgent ? nil : parent.id
            session.sessionId = UUID()
            _ = try #require(await session.folderState.restoreAndWait(bookmark: nil, path: dir.path))
            defer { session.folderState.clearFolder() }
            if scenario == .cleared { session.folderState.clearFolder() }
            if scenario == .stale {
                _ = await session.folderState.restoreAndWait(
                    bookmark: Data([0]),
                    path: dir.appendingPathComponent("missing").path
                )
            }
            let turnRoot: URL? =
                switch scenario {
                case .cleared, .suspended: nil
                case .differentRoot: agentDir
                default: dir
                }
            let folder = ChatExecutionContext.$currentChatSessionBox.withValue(WeakChatSessionBox(session)) {
                ChatExecutionContext.$currentFolderRoot.withValue(turnRoot) {
                    ChatExecutionContext.$hostReadOnlyScope.withValue(scenario == .readOnly ? dir : nil) {
                        AgentDelegationDispatcher.resolveLauncherWorkingFolder(
                            scopeAgentId: scenario == .differentAgent
                                ? agents[1].id : (session.agentId ?? Agent.defaultId),
                            parentSessionId: scenario == .differentSession
                                ? UUID().uuidString : session.sessionId?.uuidString
                        )
                    }
                }
            }
            if scenario == .current || scenario == .defaultAgent {
                #expect(folder?.path == dir.path)
                #expect(folder?.path != agentDir.path)
            } else {
                #expect(folder == nil)
            }
        }
    }

    @Test("headless delegation retains configured agent folder fallback without borrowing a task-local path")
    func headlessLauncherFolderFallback() async throws {
        let dir = try makeFolder("headless")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await withAgents(1) { agents in
            let parent = agents[0]
            AgentManager.shared.updateWorkingFolder(for: parent.id, bookmark: nil, path: dir.path)
            let folder = ChatExecutionContext.$currentChatSessionBox.withValue(nil) {
                ChatExecutionContext.$currentFolderRoot.withValue(URL(fileURLWithPath: "/unrelated")) {
                    AgentDelegationDispatcher.resolveLauncherWorkingFolder(
                        scopeAgentId: parent.id,
                        parentSessionId: nil
                    )
                }
            }
            #expect(folder?.path == dir.path)
            AgentManager.shared.clearWorkingFolder(for: parent.id)
            #expect(
                AgentDelegationDispatcher.resolveLauncherWorkingFolder(scopeAgentId: parent.id, parentSessionId: nil)
                    == nil
            )
        }
    }

    // MARK: - Dispatch → host-folder mode → writable schema

    @Test("a delegated child of an agent with a Working Folder can write files there")
    func delegatedChildMountsAgentWorkingFolderWithWriteTools() async throws {
        let dir = try makeFolder("writable")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await withAgents(1) { agents in
            let agent = agents[0]
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: dir.path)

            // Exactly the request `AgentDelegationDispatcher.run` builds: no
            // folder of its own (no launcher folder was supplied here).
            let request = DispatchRequest(prompt: "save the report", agentId: agent.id, source: .delegation)
            #expect(request.folderBookmark == nil && request.folderPath == nil)
            #expect(BackgroundTaskManager.resolveDispatchFolder(for: request)?.path == dir.path)

            let context = BackgroundTaskManager.shared.makeContextForTesting(request)
            let failure = await context.activateFolderContextIfNeeded()
            #expect(failure == nil, "a readable agent folder must mount without a preamble")
            let session = context.chatSession
            defer { session.folderState.clearFolder() }
            #expect(sameFolder(session.folderState.rootPath, dir))
            #expect(session.folderContextFromDispatchBookmark)

            // Execution mode: the agent folder wins even for a sandbox-default
            // agent (dispatch folders have no interactive sandbox toggle).
            let mode = session.resolveExecutionModeForSend(agentId: agent.id, autonomousEnabled: false)
            #expect(mode.usesHostFolderTools)
            #expect(sameFolder(mode.folderContext?.rootPath, dir))
            let sandboxDefault = session.resolveExecutionModeForSend(
                agentId: agent.id, autonomousEnabled: true)
            #expect(sandboxDefault.usesHostFolderTools)

            // Turn root binding is the folder, not nil.
            let root = ChatSession.turnFolderRoot(
                sandboxEnabled: true,
                folderFromDispatch: session.folderContextFromDispatchBookmark,
                folderRoot: session.folderState.rootPath
            )
            #expect(sameFolder(root, dir))

            // Composed schema for the delegated session: host WRITE tools are
            // present (registered `.auto`, so no approval card strands the
            // headless child); the structural strips still hold.
            let tools = await ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
                SystemPromptComposer.resolveTools(agentId: agent.id, executionMode: mode)
            }
            let names = Set(tools.map { $0.function.name })
            #expect(
                names.isSuperset(of: Self.hostWriteTools),
                "delegated child must carry the host write tools; missing: \(Self.hostWriteTools.subtracting(names))"
            )
            #expect(names.contains("file_read"))
            #expect(names.isDisjoint(with: Set(SubagentCapabilityRegistry.spawn.toolNames)))
            #expect(!names.contains("clarify"))
            #expect(FileWriteTool().defaultPermissionPolicy == .auto, "file_write must not gate a headless child")
            #expect(FileEditTool().defaultPermissionPolicy == .auto, "file_edit must not gate a headless child")
        }
    }

    @Test("a delegated child of an agent without a Working Folder has no host file tools")
    func delegatedChildWithoutAgentFolderCannotWrite() async throws {
        try await withAgents(1) { agents in
            let agent = agents[0]
            let request = DispatchRequest(prompt: "save the report", agentId: agent.id, source: .delegation)
            #expect(BackgroundTaskManager.resolveDispatchFolder(for: request) == nil)

            let context = BackgroundTaskManager.shared.makeContextForTesting(request)
            let failure = await context.activateFolderContextIfNeeded()
            #expect(failure == nil)
            let session = context.chatSession
            #expect(!session.folderState.hasActiveFolder)
            #expect(!session.folderContextFromDispatchBookmark)

            let mode = session.resolveExecutionModeForSend(agentId: agent.id, autonomousEnabled: false)
            #expect(!mode.usesHostFolderTools)

            let tools = await ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
                SystemPromptComposer.resolveTools(agentId: agent.id, executionMode: mode)
            }
            let names = Set(tools.map { $0.function.name })
            #expect(names.isDisjoint(with: Self.hostWriteTools), "no folder → no host write tools: \(names)")
            #expect(names.contains("share_artifact"), "artifacts remain the folder-less delivery path")
        }
    }

    @Test("clearing the agent's Working Folder takes the write tools away from the next delegation")
    func clearingAgentFolderRemovesWriteAccess() async throws {
        let dir = try makeFolder("cleared")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await withAgents(1) { agents in
            let agent = agents[0]
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: dir.path)
            let request = DispatchRequest(prompt: "go", agentId: agent.id, source: .delegation)
            #expect(BackgroundTaskManager.resolveDispatchFolder(for: request) != nil)

            AgentManager.shared.clearWorkingFolder(for: agent.id)
            #expect(BackgroundTaskManager.resolveDispatchFolder(for: request) == nil)
            let context = BackgroundTaskManager.shared.makeContextForTesting(request)
            _ = await context.activateFolderContextIfNeeded()
            #expect(!context.chatSession.folderState.hasActiveFolder)
        }
    }

    // MARK: - Child-side delivery contract

    @Test("the delivery contract names the child's working folder and routes file output to it")
    func deliveryContractIsFolderAware() {
        let input = "Write the Q3 report and save it as reports/q3.md."
        let folder = "/Users/probe/Documents/Reports"

        let withFolder = AgentDelegationDispatcher.delegatedPrompt(
            input: input, workingFolderPath: folder)
        #expect(withFolder.hasPrefix(input))
        #expect(withFolder.contains("[Delegated task]"))
        #expect(withFolder.contains("ONLY your final message"))
        #expect(withFolder.contains("Your working folder is `\(folder)`"))
        #expect(withFolder.contains("`file_write` / `file_edit`"))
        #expect(withFolder.contains("exact relative paths you wrote"))
        #expect(withFolder.contains("Never write outside the working folder"))
        // `share_artifact` is demoted to "return to requester", not the
        // default file path — otherwise the child ignores the folder.
        #expect(withFolder.contains("Use `share_artifact` only when"))
        #expect(!withFolder.contains("Only when `share_artifact` is unavailable"))

        // Folder-less child: the artifact-first contract is unchanged.
        let withoutFolder = AgentDelegationDispatcher.delegatedPrompt(input: input)
        #expect(withoutFolder == input + "\n\n" + AgentDelegationDispatcher.deliveryContract)
        #expect(!withoutFolder.contains("working folder"))
        let blank = AgentDelegationDispatcher.delegatedPrompt(input: input, workingFolderPath: "")
        #expect(blank == withoutFolder)

        // Workspace (remote) child: the host owns its folder; the remote
        // contract wins even if a caller passes a local path.
        let remote = AgentDelegationDispatcher.delegatedPrompt(
            input: input, remote: true, workingFolderPath: folder)
        #expect(remote == input + "\n\n" + AgentDelegationDispatcher.remoteDeliveryContract)
        #expect(!remote.contains(folder))
    }

    @Test("the dispatcher mounts the target agent's folder, else the launcher's supplied bookmark")
    func dispatcherSourceResolvesTargetThenLauncherFolder() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // AgentDelegation/
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // OsaurusCore/
                .appendingPathComponent("Services/AgentDelegation/AgentDelegationDispatcher.swift"),
            encoding: .utf8
        )
        // Target agent's own folder is looked up; the launcher's folder is
        // the explicit fallback (`resolveChildWorkingFolder`), and the
        // request carries exactly the resolved folder so the contract and
        // the mount never disagree.
        #expect(source.contains("AgentManager.shared.workingFolder(for: agentId)"))
        #expect(source.contains("launcherFolder: launcherWorkingFolder"))
        #expect(source.contains("workingFolderPath: childFolder.folder?.path"))
        #expect(source.contains("folderPath: target.isWorkspace ? nil : childFolder.folder?.path"))
        // Never the caller's live task-local root (that is the Orchestrator's
        // own read-only view, not a folder the child may write to).
        #expect(!source.contains("ChatExecutionContext.currentFolderRoot"))

        // The pure resolver: target wins, launcher is the fallback, and a
        // path-less/bookmark-less target does not shadow the launcher.
        let target = DelegatedWorkingFolder(bookmark: nil, path: "/tmp/target")
        let launcher = DelegatedWorkingFolder(bookmark: nil, path: "/tmp/launcher")
        let own = AgentDelegationDispatcher.resolveChildWorkingFolder(targetFolder: target, launcherFolder: launcher)
        #expect(own.folder?.path == "/tmp/target")
        #expect(!own.inherited)
        let inherited = AgentDelegationDispatcher.resolveChildWorkingFolder(targetFolder: nil, launcherFolder: launcher)
        #expect(inherited.folder?.path == "/tmp/launcher")
        #expect(inherited.inherited)
        let empty = AgentDelegationDispatcher.resolveChildWorkingFolder(
            targetFolder: DelegatedWorkingFolder(bookmark: nil, path: ""), launcherFolder: nil)
        #expect(empty.folder == nil)
    }

    // MARK: - Orchestrator-side guidance

    private func descriptor(_ name: String, folder: String?) -> SpawnAgentDescriptor {
        SpawnAgentDescriptor(
            id: UUID(),
            name: name,
            description: nil,
            modelId: "local/model",
            isLocal: true,
            providerName: nil,
            workingFolderPath: folder
        )
    }

    @Test("spawn guidance lists each agent's own folder and names who can write to disk")
    func spawnGuidanceAdvertisesWorkingFolders() {
        let writer = descriptor("Writer", folder: "/Users/probe/Reports")
        let reader = descriptor("Reader", folder: nil)
        let text = SystemPromptTemplates.spawnGuidance(agents: [writer, reader])

        #expect(text.contains("own folder: /Users/probe/Reports"))
        #expect(text.contains("Writer work in their own folder"))
        // The child IS the agent, with its own tools (only spawning and
        // `clarify` are removed) — no "audited subset" contract.
        #expect(text.contains("Agents run with their own enabled tools"))
        #expect(!text.contains("Target-agent workers receive only their enabled tools"))
        #expect(text.contains("`share_artifact`"))

        // Without a launcher folder and no agent folder: nobody can write.
        let noneHaveFolders = SystemPromptTemplates.spawnGuidance(agents: [reader])
        #expect(noneHaveFolders.contains("cannot write files to disk"))
        #expect(!noneHaveFolders.contains("own folder: "))

        // With a launcher folder, folder-less agents inherit it.
        let inherited = SystemPromptTemplates.spawnGuidance(
            agents: [reader], launcherHasFolder: true)
        #expect(inherited.contains("work in YOUR working folder"))
        #expect(inherited.contains("save deliverables"))
        #expect(!inherited.contains("cannot write files to disk"))
    }

    @Test("the descriptor's working folder comes from AgentManager.workingFolder, the dispatch fallback's source")
    func descriptorReadsTheAgentWorkingFolder() async throws {
        try await withAgents(2) { agents in
            let agent = agents[0]
            let bare = agents[1]
            AgentManager.shared.updateWorkingFolder(
                for: agent.id, bookmark: Data([0xA]), path: "/Users/probe/agent-folder")

            let snapshot = SpawnDescriptors.resolveForPreview(
                agentIDs: [agent.id, bare.id],
                launcherModelOverride: nil
            )
            let byId = Dictionary(
                uniqueKeysWithValues: snapshot.agentTargets.map { ($0.descriptor.id, $0.descriptor) })
            #expect(byId[agent.id]?.workingFolderPath == "/Users/probe/agent-folder")
            #expect(byId[bare.id]?.workingFolderPath == nil)

            // Clearing the folder clears the advertised path on the next
            // resolve — prompt and runtime move together.
            AgentManager.shared.clearWorkingFolder(for: agent.id)
            let cleared = SpawnDescriptors.resolveForPreview(
                agentIDs: [agent.id], launcherModelOverride: nil)
            #expect(cleared.agentTargets.first?.descriptor.workingFolderPath == nil)
        }
    }

    @Test("a blank working folder path normalizes to nil on the descriptor")
    func blankFolderPathIsNil() {
        #expect(descriptor("x", folder: "").workingFolderPath == nil)
        #expect(descriptor("x", folder: nil).workingFolderPath == nil)
        #expect(descriptor("x", folder: "/a").workingFolderPath == "/a")
    }
}
