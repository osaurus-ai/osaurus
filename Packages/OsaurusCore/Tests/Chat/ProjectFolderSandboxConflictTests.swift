//
//  ProjectFolderSandboxConflictTests.swift
//  OsaurusCoreTests
//
//  A project's working folder and the agent's sandbox are mutually
//  exclusive: `resolveExecutionMode` lets the sandbox win, so with the
//  sandbox on by default for every custom agent and no in-chat toggle, a
//  project folder used to show up in the chat's folder chip while the model
//  stayed jailed to `/workspace/agents/<id>/` and reported the folder
//  unreachable. Applying a project folder to a new chat must therefore turn
//  the agent's sandbox off, exactly as the composer's folder chip does.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ProjectFolderSandboxConflictTests {

    // MARK: - Helpers

    private func makeAgent(sandboxEnabled: Bool) -> Agent {
        Agent(
            name: "ProjectFolder-\(UUID().uuidString.prefix(6))",
            systemPrompt: "Test identity",
            agentAddress: "test-project-folder-\(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: sandboxEnabled)
        )
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-project-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func persistedSandboxEnabled(for agentId: UUID) -> Bool? {
        AgentManager.shared.agent(for: agentId)?.autonomousExec?.enabled
    }

    // MARK: - Pure policy seam

    @Test("sandbox on → explicit opt-out, other settings preserved")
    func policy_disablesEnabledSandbox() {
        var enabled = AutonomousExecConfig(enabled: true)
        enabled.sandboxNetworkEnabled = false
        enabled.maxCommandsPerTurn = 3
        let result = AgentManager.autonomousExecForHostFolder(effective: enabled)
        #expect(result?.enabled == false)
        #expect(result?.sandboxNetworkEnabled == false)
        #expect(result?.maxCommandsPerTurn == 3)
    }

    @Test("implicit default-on config (unconfigured agent) is also opted out")
    func policy_disablesImplicitDefault() {
        let legacy = Agent(name: "Legacy", autonomousExec: nil)
        let effective = AgentManager.resolvedAutonomousExec(for: legacy, availability: .available)
        #expect(effective?.enabled == true)
        #expect(AgentManager.autonomousExecForHostFolder(effective: effective)?.enabled == false)
    }

    @Test("sandbox already off or unavailable → no change")
    func policy_noopWhenAlreadyOff() {
        #expect(AgentManager.autonomousExecForHostFolder(effective: nil) == nil)
        #expect(
            AgentManager.autonomousExecForHostFolder(
                effective: AutonomousExecConfig(enabled: false)
            ) == nil
        )
    }

    // MARK: - Project entry points

    @Test("new chat in project with folder → folder active, agent sandbox persisted off")
    func startNewChatInProject_disablesSandbox() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let agent = makeAgent(sandboxEnabled: true)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let project = ProjectManager.shared.create(name: "Folder Project")
            defer { ProjectManager.shared.delete(id: project.id) }
            var withFolder = project
            withFolder.folderPath = folder.path
            ProjectManager.shared.update(withFolder)

            let window = ChatWindowState(windowId: UUID(), agentId: agent.id)
            #expect(AgentManager.shared.effectiveAutonomousExec(for: agent.id)?.enabled == true)

            window.startNewChat(in: withFolder)
            let context = await window.session.folderState.contextWaitingForRestore()

            #expect(window.session.projectId == project.id)
            #expect(
                context?.rootPath.standardizedFileURL.path == folder.standardizedFileURL.path)
            // The sandbox change follows the restore; wait for it.
            try await waitUntil(timeout: .seconds(5)) {
                persistedSandboxEnabled(for: agent.id) == false
            }
            #expect(AgentManager.shared.effectiveAutonomousExec(for: agent.id)?.enabled == false)
            #expect(window.session.folderState.hasActiveFolder)
            window.session.folderState.clearFolder()
        }
    }

    @Test("⌘N in project with folder → same sandbox opt-out as the project page")
    func newTabInCurrentProject_disablesSandbox() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let agent = makeAgent(sandboxEnabled: true)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let project = ProjectManager.shared.create(name: "Tab Project")
            defer { ProjectManager.shared.delete(id: project.id) }
            var withFolder = project
            withFolder.folderPath = folder.path
            ProjectManager.shared.update(withFolder)

            let window = ChatWindowState(windowId: UUID(), agentId: agent.id)
            window.openProjectId = project.id
            window.newTabInCurrentProject()

            #expect(window.session.projectId == project.id)
            let context = await window.session.folderState.contextWaitingForRestore()
            #expect(context != nil)
            try await waitUntil(timeout: .seconds(5)) {
                persistedSandboxEnabled(for: agent.id) == false
            }
            window.session.folderState.clearFolder()
        }
    }

    @Test("project folder that no longer exists → sandbox left untouched")
    func missingProjectFolder_keepsSandbox() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent(sandboxEnabled: true)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-missing-\(UUID().uuidString)").path
            let project = Project(name: "Gone", folderPath: missing)

            let window = ChatWindowState(windowId: UUID(), agentId: agent.id)
            let followUp = window.adoptProjectFolder(project)
            #expect(followUp != nil)
            await followUp?.value

            #expect(!window.session.folderState.hasActiveFolder)
            // Stranding the agent with neither sandbox nor folder would be
            // worse than the original bug.
            #expect(persistedSandboxEnabled(for: agent.id) == true)
            #expect(AgentManager.shared.effectiveAutonomousExec(for: agent.id)?.enabled == true)
        }
    }

    @Test("chat that already has its own folder keeps it, project folder is not applied")
    func existingChatFolder_wins() async throws {
        try await ChatHistoryTestStorage.run {
            let own = try makeFolder()
            let projectFolder = try makeFolder()
            defer {
                try? FileManager.default.removeItem(at: own)
                try? FileManager.default.removeItem(at: projectFolder)
            }
            let agent = makeAgent(sandboxEnabled: false)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

            let window = ChatWindowState(windowId: UUID(), agentId: agent.id)
            _ = await window.session.folderState.restoreAndWait(bookmark: nil, path: own.path)
            #expect(window.session.folderState.hasActiveFolder)

            let project = Project(name: "Other", folderPath: projectFolder.path)
            #expect(window.adoptProjectFolder(project) == nil)
            #expect(
                window.session.folderState.rootPath?.standardizedFileURL.path
                    == own.standardizedFileURL.path)
            window.session.folderState.clearFolder()
        }
    }

    @Test("project without a folder → nothing applied, sandbox untouched")
    func projectWithoutFolder_isNoop() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent(sandboxEnabled: true)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

            let window = ChatWindowState(windowId: UUID(), agentId: agent.id)
            #expect(window.adoptProjectFolder(Project(name: "Bare")) == nil)
            #expect(!window.session.folderState.hasActiveFolder)
            #expect(persistedSandboxEnabled(for: agent.id) == true)
        }
    }

    // MARK: - Agent working folder (sticky default for fresh chats)

    private func sameFolder(_ a: URL?, _ b: URL) -> Bool {
        a?.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @Test("new window for an agent with a working folder → folder active, sandbox persisted off")
    func agentWorkingFolder_seedsFreshWindow() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let agent = makeAgent(sandboxEnabled: true)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: folder.path)

            let window = ChatWindowState(windowId: UUID(), agentId: agent.id)
            #expect(window.session.folderFromAgentDefault)
            let context = await window.session.folderState.contextWaitingForRestore()
            #expect(sameFolder(context?.rootPath, folder))
            try await waitUntil(timeout: .seconds(5)) {
                persistedSandboxEnabled(for: agent.id) == false
            }
            #expect(window.session.folderState.hasActiveFolder)
            window.session.folderState.clearFolder()
        }
    }

    @Test("New Chat / new tab / agent switch all start in the agent's working folder")
    func agentWorkingFolder_seedsEveryFreshChatPath() async throws {
        try await ChatHistoryTestStorage.run {
            let folderA = try makeFolder()
            let folderB = try makeFolder()
            defer {
                try? FileManager.default.removeItem(at: folderA)
                try? FileManager.default.removeItem(at: folderB)
            }
            let agentA = makeAgent(sandboxEnabled: false)
            let agentB = makeAgent(sandboxEnabled: false)
            AgentManager.shared.add(agentA)
            AgentManager.shared.add(agentB)
            defer {
                Task {
                    _ = await AgentManager.shared.delete(id: agentA.id)
                    _ = await AgentManager.shared.delete(id: agentB.id)
                }
            }
            AgentManager.shared.updateWorkingFolder(for: agentA.id, bookmark: nil, path: folderA.path)
            AgentManager.shared.updateWorkingFolder(for: agentB.id, bookmark: nil, path: folderB.path)

            let window = ChatWindowState(windowId: UUID(), agentId: agentA.id)
            var context = await window.session.folderState.contextWaitingForRestore()
            #expect(sameFolder(context?.rootPath, folderA))

            // The user clears the chip in THIS chat only (the manager-level
            // forget is the composer's job); New Chat re-seeds from the agent.
            window.session.folderState.clearFolder()
            #expect(!window.session.folderState.hasActiveFolder)
            window.startNewChat()
            context = await window.session.folderState.contextWaitingForRestore()
            #expect(sameFolder(context?.rootPath, folderA), "New Chat (reset path) re-seeds")

            // ⌘T: a fresh tab for the same agent.
            window.newTab()
            context = await window.session.folderState.contextWaitingForRestore()
            #expect(sameFolder(context?.rootPath, folderA), "new tab re-seeds")

            // Switching to another agent lands in THAT agent's folder.
            window.switchAgent(to: agentB.id)
            context = await window.session.folderState.contextWaitingForRestore()
            #expect(sameFolder(context?.rootPath, folderB), "agent switch uses the new agent's folder")

            for tab in window.tabs {
                tab.session.folderState.clearFolder()
            }
        }
    }

    @Test("project folder wins over the agent's working folder for chats started in the project")
    func projectFolder_beatsAgentWorkingFolder() async throws {
        try await ChatHistoryTestStorage.run {
            let agentFolder = try makeFolder()
            let projectFolder = try makeFolder()
            defer {
                try? FileManager.default.removeItem(at: agentFolder)
                try? FileManager.default.removeItem(at: projectFolder)
            }
            let agent = makeAgent(sandboxEnabled: false)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(
                for: agent.id, bookmark: nil, path: agentFolder.path)
            let project = ProjectManager.shared.create(name: "Precedence Project")
            defer { ProjectManager.shared.delete(id: project.id) }
            var withFolder = project
            withFolder.folderPath = projectFolder.path
            ProjectManager.shared.update(withFolder)

            let window = ChatWindowState(windowId: UUID(), agentId: agent.id)
            // Let the agent-default seed fully resolve first, so the project
            // must replace an ACTIVE agent folder, not merely a pending one.
            _ = await window.session.folderState.contextWaitingForRestore()
            #expect(sameFolder(window.session.folderState.rootPath, agentFolder))

            window.startNewChat(in: withFolder)
            let context = await window.session.folderState.contextWaitingForRestore()
            #expect(sameFolder(context?.rootPath, projectFolder))
            #expect(!window.session.folderFromAgentDefault)
            #expect(window.session.projectId == project.id)

            // And a project WITHOUT a folder leaves the agent folder in place.
            let bare = ProjectManager.shared.create(name: "Bare Project")
            defer { ProjectManager.shared.delete(id: bare.id) }
            window.startNewChat(in: bare)
            let kept = await window.session.folderState.contextWaitingForRestore()
            #expect(sameFolder(kept?.rootPath, agentFolder))
            #expect(window.session.folderFromAgentDefault)

            for tab in window.tabs {
                tab.session.folderState.clearFolder()
            }
        }
    }

    @Test("a chat's own pick is never replaced by the project folder, even after a seed")
    func ownPick_afterAgentSeed_beatsProject() async throws {
        try await ChatHistoryTestStorage.run {
            let agentFolder = try makeFolder()
            let own = try makeFolder()
            let projectFolder = try makeFolder()
            defer {
                try? FileManager.default.removeItem(at: agentFolder)
                try? FileManager.default.removeItem(at: own)
                try? FileManager.default.removeItem(at: projectFolder)
            }
            let agent = makeAgent(sandboxEnabled: false)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(
                for: agent.id, bookmark: nil, path: agentFolder.path)

            let window = ChatWindowState(windowId: UUID(), agentId: agent.id)
            _ = await window.session.folderState.contextWaitingForRestore()
            #expect(window.session.folderFromAgentDefault)

            // The user picks a folder in this chat (a user mutation).
            _ = await window.session.folderState.setFolder(own)
            #expect(!window.session.folderFromAgentDefault)

            let project = Project(name: "Other", folderPath: projectFolder.path)
            #expect(window.adoptProjectFolder(project) == nil)
            #expect(sameFolder(window.session.folderState.rootPath, own))
            window.session.folderState.clearFolder()
        }
    }

    @Test("Default agent and a reopened history session never adopt a working folder")
    func agentWorkingFolder_skipsDefaultAgentAndLoadedSessions() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            // Default agent: the manager refuses the write, the window seeds nothing.
            AgentManager.shared.updateWorkingFolder(
                for: Agent.defaultId, bookmark: nil, path: folder.path)
            let defaultWindow = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            #expect(defaultWindow.adoptAgentWorkingFolder() == nil)
            #expect(!defaultWindow.session.folderState.hasActiveFolder)
            #expect(defaultWindow.session.folderState.pendingRestore == nil)

            // A session reopened from history keeps its own (empty) folder
            // state even when the agent has since gained a working folder.
            let agent = makeAgent(sandboxEnabled: false)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: folder.path)
            let data = ChatSessionData(title: "Old", agentId: agent.id)
            let reopened = ChatWindowState(windowId: UUID(), agentId: agent.id, sessionData: data)
            let restored = await reopened.session.folderState.contextWaitingForRestore()
            #expect(restored == nil)
            #expect(!reopened.session.folderState.hasActiveFolder)
            #expect(!reopened.session.folderFromAgentDefault)
        }
    }

    @Test("agent working folder that no longer exists → sandbox left untouched")
    func missingAgentWorkingFolder_keepsSandbox() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent(sandboxEnabled: true)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-missing-\(UUID().uuidString)").path
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: nil, path: missing)

            let window = ChatWindowState(windowId: UUID(), agentId: agent.id)
            _ = await window.session.folderState.contextWaitingForRestore()
            // Give the follow-up (sandbox) task a beat; it must NOT flip.
            try await Task.sleep(for: .milliseconds(100))
            #expect(!window.session.folderState.hasActiveFolder)
            #expect(!window.session.folderFromAgentDefault)
            #expect(persistedSandboxEnabled(for: agent.id) == true)
        }
    }

    // MARK: - Shared with the composer chip

    @Test("disableSandboxForHostFolder persists an explicit opt-out and reports the change")
    func disableSandboxForHostFolder_persists() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent(sandboxEnabled: true)
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

            let changed = try await AgentManager.shared.disableSandboxForHostFolder(agentId: agent.id)
            #expect(changed)
            #expect(persistedSandboxEnabled(for: agent.id) == false)

            let again = try await AgentManager.shared.disableSandboxForHostFolder(agentId: agent.id)
            #expect(!again)
        }
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
    throw WaitTimeout()
}

private struct WaitTimeout: Error {}
