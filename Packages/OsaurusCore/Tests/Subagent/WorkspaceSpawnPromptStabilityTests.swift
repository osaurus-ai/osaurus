//
//  WorkspaceSpawnPromptStabilityTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Prefix-cache invariant for workspace spawn targets: the spawn guidance
//  block, the resolved descriptors and the `spawn_agent` / `spawn_batch`
//  schema derive ONLY from durable configuration (ref + roster names). No
//  presence flip — online, offline, unknown, relay force-offline, expired
//  verification — may change a byte, because any change would invalidate the
//  cache-stable system prefix on the next turn. Liveness is a runtime gate
//  whose only model-visible output is a tool result.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkspaceSpawnPromptStabilityTests {

    private static let address = "0xaaaa0000000000000000000000000000000000d1"
    private static let ref = WorkspaceAgentRef(workspaceId: "ws-stable", agentAddress: address)

    private static func rosterAgent(online: String, lastSeen: String? = nil) throws -> OsaurusRouterWorkspaceAgent {
        let lastSeenJSON = lastSeen.map { "\"\($0)\"" } ?? "null"
        let body = """
            {"agent_address": "\(address)", "display_name": "Research Agent",
             "description": "Digs through papers",
             "owner": {"account_id": "acct-1", "wallet_address": "0xowner", "display_name": "Alice"},
             "relay_url": "wss://relay.example", "online": \(online), "last_seen": \(lastSeenJSON),
             "shared_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceAgent.self, from: Data(body.utf8))
    }

    private static func workspace() throws -> OsaurusRouterWorkspaceSummary {
        let body = """
            {"id": "ws-stable", "name": "Acme", "role": "member", "source": "subscription", "active": true,
             "members_active": 2, "agents_shared": 1, "created_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceSummary.self, from: Data(body.utf8))
    }

    private static func apply(online: String, lastSeen: String? = nil) throws {
        WorkspaceRosterStore.shared.apply(
            rosters: [.init(workspace: try workspace(), agents: [try rosterAgent(online: online, lastSeen: lastSeen)])]
        )
    }

    /// Everything the model can see about the workspace pool, as one blob.
    private static func promptSurface() -> String {
        let availability = SpawnDescriptors.resolveForPreview(
            agentIDs: [],
            modelNames: [],
            modelNotes: [:],
            launcherModelOverride: nil,
            workspaceAgents: [ref]
        )
        let guidance = SystemPromptTemplates.spawnGuidance(
            agents: [],
            models: [],
            workspaceAgents: availability.workspaceAgents,
            availableToolNames: [
                SubagentCapabilityRegistry.spawnAgentToolName, SubagentCapabilityRegistry.spawnBatchToolName,
            ],
            maxParallel: 2
        )
        let addresses = availability.runnableWorkspaceAgents.map(\.agentAddress)
        let names = availability.workspaceAgents.map(\.name)
        let agentSpec = SpawnAgentTool.constrainedSpec(
            SpawnAgentTool().asOpenAITool(),
            allowedAgentIDs: [],
            allowedAgentNames: names,
            allowedWorkspaceAddresses: addresses
        )
        // Sorted keys: the schema is a dictionary, and only the BYTES the
        // model sees matter here, not encoder iteration order.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let specJSON = (try? encoder.encode(agentSpec)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        return "\(availability.workspaceAgentTargets)\n\(guidance)\n\(specJSON)"
    }

    @Test func presenceFlipsNeverChangeGuidanceDescriptorsOrSchema() async throws {
        try await WorkspaceRosterTestLock.shared.run {
            let store = WorkspaceRosterStore.shared
            try Self.apply(online: "true")
            let baseline = Self.promptSurface()
            #expect(baseline.contains(Self.address), "the pool must advertise the agent by address")
            #expect(baseline.contains("Research Agent"))
            #expect(baseline.contains("Acme"))
            #expect(!baseline.lowercased().contains("online"), "presence must not reach the prompt")

            // Relay said the host is gone (502 agent_offline) → forced offline.
            store.noteHostUnreachable(agentAddress: Self.address)
            #expect(store.presence(forAddress: Self.address, workspaceId: "ws-stable").isOffline)
            #expect(Self.promptSurface() == baseline, "force-offline changed prompt bytes")

            // Router poll: offline with a last-seen stamp.
            try Self.apply(online: "false", lastSeen: "2026-03-01T12:00:00Z")
            #expect(store.presence(forAddress: Self.address, workspaceId: "ws-stable").isOffline)
            #expect(Self.promptSurface() == baseline, "router offline changed prompt bytes")

            // A request through the relay succeeded, then the router reports
            // presence unknown (`online: null`). Our own relay evidence
            // outlives a roster row with no verdict (#2687), so this reads
            // online — and still must not reach the prompt.
            store.noteHostReachable(agentAddress: Self.address)
            try Self.apply(online: "null")
            #expect(store.presence(forAddress: Self.address, workspaceId: "ws-stable") == .online)
            #expect(Self.promptSurface() == baseline, "relay-evidence presence changed prompt bytes")

            // Genuinely unknown: a `true` verdict supersedes the relay
            // evidence, then the router loses presence for the agent.
            try Self.apply(online: "true")
            try Self.apply(online: "null")
            #expect(store.presence(forAddress: Self.address, workspaceId: "ws-stable") == .unknown)
            #expect(Self.promptSurface() == baseline, "unknown presence changed prompt bytes")

            // Back online, then the 35 s verification lifetime lapses.
            try Self.apply(online: "true")
            store.noteHostReachable(agentAddress: Self.address)
            #expect(Self.promptSurface() == baseline, "host reachable changed prompt bytes")
            store.invalidateVerification()
            #expect(Self.promptSurface() == baseline, "expired verification changed prompt bytes")
        }
    }

    /// Unsharing IS a configuration change (like deleting a local agent):
    /// the target drops to `missing`, the guidance stops advertising it and
    /// the schema enum no longer offers the address.
    @Test func unsharingRemovesTheTargetFromTheSurface() async throws {
        try await WorkspaceRosterTestLock.shared.run {
            let store = WorkspaceRosterStore.shared
            try Self.apply(online: "true")
            let shared = Self.promptSurface()
            #expect(shared.contains(Self.address))

            store.apply(rosters: [.init(workspace: try Self.workspace(), agents: [])])
            let availability = SpawnDescriptors.resolveForPreview(
                agentIDs: [], modelNames: [], modelNotes: [:], launcherModelOverride: nil, workspaceAgents: [Self.ref]
            )
            #expect(availability.workspaceAgentTargets.map(\.state) == [.missing])
            #expect(availability.runnableWorkspaceAgents.isEmpty)
            #expect(!availability.hasRunnableAgentTargets)
            let guidance = SystemPromptTemplates.spawnGuidance(
                agents: [], models: [], workspaceAgents: availability.workspaceAgents,
                availableToolNames: [SubagentCapabilityRegistry.spawnAgentToolName]
            )
            #expect(!guidance.contains(Self.address))
        }
    }
}
