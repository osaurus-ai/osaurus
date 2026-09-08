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

    @Test("sandbox on → explicit opt-out with host writes cleared")
    func policy_disablesEnabledSandbox() {
        var enabled = AutonomousExecConfig(enabled: true)
        enabled.allowHostFolderWrites = true
        let result = AgentManager.autonomousExecForHostFolder(effective: enabled)
        #expect(result?.enabled == false)
        #expect(result?.allowHostFolderWrites == false)
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
