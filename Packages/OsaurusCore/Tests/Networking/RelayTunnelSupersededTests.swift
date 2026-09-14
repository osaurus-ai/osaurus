//
//  RelayTunnelSupersededTests.swift
//  OsaurusCoreTests
//
//  The relay evicts an agent with `agent_removed reason:"superseded"` when a
//  newer tunnel authenticates the same address — which happens when two
//  devices sharing one identity both try to serve a (legacy, v1) agent
//  address. The relay contract (osaurus-relay CLIENT_INTEGRATION §3) says the
//  evicted client MUST NOT reconnect for that address, or the two sessions
//  evict each other forever. These tests pin the host-side handling of that
//  frame without a live socket.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct RelayTunnelSupersededTests {

    private func makeAgent(address: String) -> Agent {
        Agent(
            id: UUID(),
            name: "Superseded probe",
            isBuiltIn: false,
            agentIndex: 0,
            agentAddress: address,
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
    }

    @Test func supersededFrame_marksAgentServedElsewhereAndStopsReconnect() async {
        let mgr = RelayTunnelManager.shared
        let address = "0xABCD000000000000000000000000000000000501"
        let agent = makeAgent(address: address)
        AgentManager.shared.add(agent)
        defer {
            mgr.clearSuperseded(agent.id)
            Task { _ = await AgentManager.shared.delete(id: agent.id) }
        }

        mgr.handleAgentRemoved([
            "type": "agent_removed",
            "address": address.lowercased(),
            "reason": "superseded",
        ])

        #expect(mgr.isServedElsewhere(agent.id))
        #expect(mgr.isSupersededAgent(agent.id))
        #expect(mgr.agentStatuses[agent.id] == .servedElsewhere)
    }

    @Test func plainRemoval_isNotSupersession() async {
        let mgr = RelayTunnelManager.shared
        let address = "0xABCD000000000000000000000000000000000502"
        let agent = makeAgent(address: address)
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        mgr.handleAgentRemoved([
            "type": "agent_removed",
            "address": address,
        ])

        #expect(!mgr.isServedElsewhere(agent.id))
        #expect(mgr.agentStatuses[agent.id] == .disconnected)
    }

    @Test func supersededByAddress_isRememberedUntilCleared() async {
        // The frame can name an address before the id map is built (or after
        // teardown wiped it); the eviction must still stick to the agent.
        let mgr = RelayTunnelManager.shared
        let address = "0xABCD000000000000000000000000000000000503"
        let agent = makeAgent(address: address)
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        mgr.handleAgentRemoved(["type": "agent_removed", "address": address, "reason": "superseded"])
        #expect(mgr.isSupersededAgent(agent.id))

        // A user-initiated enable is the sanctioned way to take the address
        // back; it clears both the id and the address record.
        mgr.clearSuperseded(agent.id)
        #expect(!mgr.isSupersededAgent(agent.id))
        #expect(!mgr.isServedElsewhere(agent.id))
    }

    @Test func disconnectAll_clearsSupersession() async {
        let mgr = RelayTunnelManager.shared
        let address = "0xABCD000000000000000000000000000000000504"
        let agent = makeAgent(address: address)
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        mgr.handleAgentRemoved(["type": "agent_removed", "address": address, "reason": "superseded"])
        #expect(mgr.isServedElsewhere(agent.id))

        // Server stop / app relaunch is a fresh session that may legitimately
        // supersede the other device (relay contract).
        mgr.disconnectAll()
        #expect(!mgr.isServedElsewhere(agent.id))
        #expect(mgr.agentStatuses[agent.id] == .disconnected)
    }

    /// Rotation is a fresh, uncontested claim: whatever `superseded` mark
    /// the OLD address carried must not follow the agent to its new address,
    /// or the next connect would silently skip it. With the tunnel disabled
    /// for the agent nothing else happens (no connect, no status flip).
    @Test func addressRotated_clearsSupersessionOfOldAddress_andIsNoopWhenDisabled() async {
        let mgr = RelayTunnelManager.shared
        let oldAddress = "0xABCD000000000000000000000000000000000505"
        let newAddress = "0xABCD000000000000000000000000000000000506"
        var agent = makeAgent(address: oldAddress)
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
        mgr.setTunnelEnabled(false, for: agent.id)

        mgr.handleAgentRemoved(["type": "agent_removed", "address": oldAddress, "reason": "superseded"])
        #expect(mgr.isSupersededAgent(agent.id))

        // The rotation already landed on the record before the relay hears
        // about it (that is the order `IdentityView.rotateKey` uses).
        agent.agentAddress = newAddress
        agent.agentIndex = 1
        AgentManager.shared.update(agent)
        let statusBefore = mgr.agentStatuses[agent.id]

        mgr.handleAddressRotated(agentId: agent.id, previousAddress: oldAddress)

        #expect(!mgr.isSupersededAgent(agent.id))
        #expect(!mgr.isServedElsewhere(agent.id))
        // Disabled tunnel: no reconnect attempt, status left alone.
        #expect(mgr.agentStatuses[agent.id] == statusBefore)
        #expect(!mgr.isConnected)
    }

    @Test func ownAgentStatus_servedElsewhere_isNotReportedAsRelayOff() {
        // Teammates can still reach the agent (via the other device), so the
        // row must not nag "turn the relay on".
        let status = SharedAgentStatus.forOwnAgent(relayStatus: .servedElsewhere)
        guard case .notConnected(let reason, let attempted) = status else {
            Issue.record("expected notConnected, got \(status)")
            return
        }
        #expect(attempted)
        #expect(reason?.contains("another device") == true)
    }
}
