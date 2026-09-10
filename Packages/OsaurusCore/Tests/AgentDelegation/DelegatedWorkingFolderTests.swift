//
//  DelegatedWorkingFolderTests.swift
//  OsaurusCoreTests — Agent delegation
//
//  Issue #2703: "the orchestrator can't save files through agents". A
//  delegated child is a REAL chat session of the target agent, so its file
//  access is the target agent's configured Working Folder — the launcher's
//  own chat folder is never inherited. This suite pins the whole chain so
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
    private func withAgents(
        _ count: Int,
        _ body: @MainActor ([Agent]) async throws -> Void
    ) async throws {
        let lease = await acquireSubagentStoreSandbox("delegated-working-folder")
        defer { lease.release() }
        try await ChatHistoryTestStorage.run {
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

    // MARK: - Dispatch → host-folder mode → writable schema

    @Test("a delegated child of an agent with a Working Folder can write files there")
    func delegatedChildMountsAgentWorkingFolderWithWriteTools() async throws {
        let dir = try makeFolder("writable")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await withAgents(1) { agents in
            let agent = agents[0]
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: dir.path)

            // Exactly the request `AgentDelegationDispatcher.run` builds: no
            // folder of its own (the launcher's folder is never threaded).
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

    @Test("the dispatcher looks the folder up from the target agent, never from the launcher")
    func dispatcherSourceReadsTargetAgentFolder() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // AgentDelegation/
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // OsaurusCore/
                .appendingPathComponent("Services/AgentDelegation/AgentDelegationDispatcher.swift"),
            encoding: .utf8
        )
        #expect(source.contains("AgentManager.shared.workingFolder(for: agentId)?.path"))
        #expect(source.contains("workingFolderPath: childWorkingFolder"))
        // The request must stay folder-less so `resolveDispatchFolder`'s
        // agent fallback (the folder the contract advertises) is what mounts.
        #expect(!source.contains("folderPath: childWorkingFolder"))
        #expect(!source.contains("ChatExecutionContext.currentFolderRoot"))
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

    @Test("spawn guidance lists each agent's working folder and names who can write to disk")
    func spawnGuidanceAdvertisesWorkingFolders() {
        let writer = descriptor("Writer", folder: "/Users/probe/Reports")
        let reader = descriptor("Reader", folder: nil)
        let text = SystemPromptTemplates.spawnGuidance(agents: [writer, reader], models: [])

        #expect(text.contains("working folder: /Users/probe/Reports"))
        #expect(text.contains("An agent that lists a working folder (Writer) can READ and WRITE files"))
        #expect(text.contains("put the exact relative path in `input`"))
        #expect(text.contains("Agents without a working folder cannot write to disk"))
        // The stale "audited subset" contract is gone for agent targets: the
        // child IS the agent, with its own tools.
        #expect(text.contains("Agent targets run as a full chat session of that agent"))
        #expect(!text.contains("Target-agent workers receive only their enabled tools"))
        // Artifacts remain the path when the file should land in THIS chat.
        #expect(text.contains("Workers deliver FILES as artifacts when the file should land in THIS"))

        let noneHaveFolders = SystemPromptTemplates.spawnGuidance(agents: [reader], models: [])
        #expect(noneHaveFolders.contains("None of the listed agents has a working folder"))
        #expect(!noneHaveFolders.contains("working folder: "))

        // Bare-model workers keep their own, unchanged contract per grant.
        let readOnly = SystemPromptTemplates.spawnGuidance(
            agents: [reader], models: [], toolAccess: .readOnly)
        #expect(readOnly.contains("Bare-model workers (`spawn_model`) receive only the added host file_read"))
        #expect(readOnly.contains("They cannot write files."))
        let textOnly = SystemPromptTemplates.spawnGuidance(agents: [reader], models: [], toolAccess: .none)
        #expect(textOnly.contains("Bare-model workers (`spawn_model`) have no tools."))
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
                modelNames: [],
                modelNotes: [:],
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
                agentIDs: [agent.id], modelNames: [], modelNotes: [:], launcherModelOverride: nil)
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
