//
//  AgentReorderPersistenceTests.swift
//  osaurusTests
//
//  Focused coverage for the custom-agent display order stored on Agent.order.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AgentReorderPersistenceTests {
    private func makeAgent(name: String, order: Int? = nil) -> Agent {
        Agent(
            name: name,
            agentAddress: "test-reorder-\(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: false),
            order: order
        )
    }

    private func customAgentNames(in agents: [Agent]) -> [String] {
        agents.filter { !$0.isBuiltIn }.map(\.name)
    }

    private func managerCustomNames() -> [String] {
        customAgentNames(in: AgentManager.shared.agents)
    }

    private func writeLegacyAgent(id: UUID, name: String) throws {
        let directory = OsaurusPaths.agents()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "id": id.uuidString,
            "name": name,
            "description": "",
            "systemPrompt": "",
            "isBuiltIn": false,
            "createdAt": "2024-01-01T00:00:00Z",
            "updatedAt": "2024-01-01T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: OsaurusPaths.agentFile(for: id), options: [.atomic])
    }

    @Test("agent reorder persists across manager refresh")
    func reorderPersistsAcrossRefresh() async throws {
        try await ChatHistoryTestStorage.run {
            let alpha = makeAgent(name: "Alpha")
            let beta = makeAgent(name: "Beta")
            let gamma = makeAgent(name: "Gamma")

            for agent in [alpha, beta, gamma] {
                AgentStore.save(agent)
            }
            AgentManager.shared.refresh()

            #expect(managerCustomNames() == ["Alpha", "Beta", "Gamma"])

            AgentManager.shared.reorder(orderedIds: [gamma.id, alpha.id, beta.id])

            #expect(managerCustomNames() == ["Gamma", "Alpha", "Beta"])
            #expect(AgentStore.load(id: gamma.id)?.order == 0)
            #expect(AgentStore.load(id: alpha.id)?.order == 1)
            #expect(AgentStore.load(id: beta.id)?.order == 2)

            AgentManager.shared.refresh()

            #expect(managerCustomNames() == ["Gamma", "Alpha", "Beta"])
        }
    }

    @Test("legacy agents without order decode and can be reordered")
    func legacyAgentsWithoutOrderCanBeReordered() async throws {
        try await ChatHistoryTestStorage.run {
            let alphaId = UUID()
            let bravoId = UUID()
            let charlieId = UUID()

            try writeLegacyAgent(id: charlieId, name: "Charlie")
            try writeLegacyAgent(id: alphaId, name: "Alpha")
            try writeLegacyAgent(id: bravoId, name: "Bravo")

            let legacyJSON = try String(contentsOf: OsaurusPaths.agentFile(for: alphaId), encoding: .utf8)
            #expect(!legacyJSON.contains("\"order\""))

            AgentManager.shared.refresh()

            #expect(AgentStore.load(id: alphaId)?.order == nil)
            #expect(managerCustomNames() == ["Alpha", "Bravo", "Charlie"])

            AgentManager.shared.reorder(orderedIds: [charlieId, alphaId, bravoId])

            #expect(managerCustomNames() == ["Charlie", "Alpha", "Bravo"])
            #expect(AgentStore.load(id: charlieId)?.order == 0)
            #expect(AgentStore.load(id: alphaId)?.order == 1)
            #expect(AgentStore.load(id: bravoId)?.order == 2)
        }
    }

    @Test("chat agent picker snapshot follows reordered agents")
    func chatAgentPickerSnapshotFollowsReorder() async throws {
        try await ChatHistoryTestStorage.run {
            let alpha = makeAgent(name: "Alpha")
            let beta = makeAgent(name: "Beta")
            let gamma = makeAgent(name: "Gamma")

            for agent in [alpha, beta, gamma] {
                AgentStore.save(agent)
            }
            AgentManager.shared.refresh()

            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)

            #expect(customAgentNames(in: window.agents) == ["Alpha", "Beta", "Gamma"])

            AgentManager.shared.reorder(orderedIds: [beta.id, gamma.id, alpha.id])

            #expect(customAgentNames(in: window.agents) == ["Beta", "Gamma", "Alpha"])
        }
    }
}
