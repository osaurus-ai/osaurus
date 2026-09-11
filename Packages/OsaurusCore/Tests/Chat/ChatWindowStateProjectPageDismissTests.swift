//
//  ChatWindowStateProjectPageDismissTests.swift
//  osaurusTests
//
//  The project detail page covers the chat surface while `openProjectId`
//  is set. Picking an agent in the sidebar must dismiss it, including when
//  the picked agent is already active (where `switchAgent` otherwise
//  returns early) and when it merely focuses an existing tab. Regression
//  coverage for #2709.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatWindowStateProjectPageDismissTests {

    private func makeAgent(_ label: String) -> Agent {
        let agent = Agent(name: "\(label)-\(UUID().uuidString.prefix(6))")
        AgentManager.shared.add(agent)
        return agent
    }

    @Test("picking the active agent closes the project page")
    func switchAgent_sameAgent_closesProjectPage() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let project = ProjectManager.shared.create(name: "Dismiss Same")
            defer { ProjectManager.shared.delete(id: project.id) }

            window.openProjectId = project.id
            window.enteredChatFromProjectPage = true
            window.switchAgent(to: Agent.defaultId)

            #expect(window.openProjectId == nil)
            #expect(window.isProjectPageVisible == false)
            #expect(window.enteredChatFromProjectPage == false)
        }
    }

    @Test("picking another agent closes the project page")
    func switchAgent_otherAgent_closesProjectPage() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let project = ProjectManager.shared.create(name: "Dismiss Other")
            defer { ProjectManager.shared.delete(id: project.id) }

            window.openProjectId = project.id
            window.switchAgent(to: agentB.id)

            #expect(window.openProjectId == nil)
            #expect(window.agentId == agentB.id)
        }
    }

    @Test("picking an agent with an existing tab closes the project page")
    func switchAgent_focusesExistingTab_closesProjectPage() async throws {
        try await ChatHistoryTestStorage.run {
            let agentB = makeAgent("B")
            defer { Task { _ = await AgentManager.shared.delete(id: agentB.id) } }
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let project = ProjectManager.shared.create(name: "Dismiss Tab")
            defer { ProjectManager.shared.delete(id: project.id) }

            window.switchAgent(to: agentB.id)
            window.session.turns.append(ChatTurn(role: .user, content: "hello"))
            window.switchAgent(to: Agent.defaultId)
            window.openProjectId = project.id

            window.switchAgent(to: agentB.id)

            #expect(window.openProjectId == nil)
            #expect(window.agentId == agentB.id)
        }
    }
}
