//
//  WorkspaceRosterStoreTests.swift
//  osaurusTests
//
//  Presence + roster semantics behind the sidebar's workspace sections:
//  the router's tri-state `online` maps to online / offline(lastSeen) /
//  unknown, a relay "host unreachable" failure forces an agent offline
//  until a poll reports it online again, own-agent detection matches the
//  local agent's identity address, and lookups are case-insensitive.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkspaceRosterStoreTests {

    // MARK: - Fixtures (router types are Decodable-only)

    private static func agent(
        address: String,
        name: String = "Research Agent",
        online: String,
        lastSeen: String? = nil
    ) throws -> OsaurusRouterWorkspaceAgent {
        let lastSeenJSON = lastSeen.map { "\"\($0)\"" } ?? "null"
        let body = """
            {
              "agent_address": "\(address)",
              "display_name": "\(name)",
              "owner": {"account_id": "acct-1", "wallet_address": "0xowner", "display_name": "Alice"},
              "relay_url": "wss://relay.example",
              "online": \(online),
              "last_seen": \(lastSeenJSON),
              "shared_at": "2026-01-01T00:00:00Z"
            }
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceAgent.self, from: Data(body.utf8))
    }

    private static func workspace(id: String, name: String) throws -> OsaurusRouterWorkspaceSummary {
        let body = """
            {"id": "\(id)", "name": "\(name)", "role": "member", "source": "subscription", "active": true,
             "members_active": 2, "agents_shared": 1, "created_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceSummary.self, from: Data(body.utf8))
    }

    private func makeStore() -> WorkspaceRosterStore {
        WorkspaceRosterStore(observeAppActivation: false)
    }

    // MARK: - Presence mapping

    @Test func presence_mapsRouterTriState() throws {
        let online = try Self.agent(address: "0xaa", online: "true")
        let offline = try Self.agent(address: "0xbb", online: "false", lastSeen: "2026-03-01T12:00:00Z")
        let unknown = try Self.agent(address: "0xcc", online: "null")

        #expect(WorkspaceRosterStore.presence(for: online) == .online)
        #expect(
            WorkspaceRosterStore.presence(for: offline)
                == .offline(lastSeen: ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z"))
        )
        #expect(WorkspaceRosterStore.presence(for: unknown) == .unknown)
        #expect(WorkspaceRosterStore.presence(for: unknown).isOffline == false)
        #expect(WorkspaceRosterStore.presence(for: offline).isOffline)
        #expect(WorkspaceRosterStore.presence(for: online).isOnline)
    }

    @Test func parseLastSeen_acceptsFractionalAndPlainISO8601() {
        let plain = WorkspaceRosterStore.parseLastSeen("2026-03-01T12:00:00Z")
        let fractional = WorkspaceRosterStore.parseLastSeen("2026-03-01T12:00:00.250Z")
        #expect(plain != nil)
        #expect(fractional != nil)
        #expect(WorkspaceRosterStore.parseLastSeen(nil) == nil)
        #expect(WorkspaceRosterStore.parseLastSeen("") == nil)
        #expect(WorkspaceRosterStore.parseLastSeen("yesterday") == nil)
    }

    @Test func presence_unknownAddressIsUnknown_andLookupIsCaseInsensitive() throws {
        let store = makeStore()
        let agent = try Self.agent(address: "0xAbC123", online: "true")
        store.apply(rosters: [.init(workspace: try Self.workspace(id: "ws-1", name: "Acme"), agents: [agent])])

        #expect(store.presence(forAddress: "0xabc123") == .online)
        #expect(store.presence(forAddress: "0XABC123") == .online)
        #expect(store.agent(forAddress: "0XABC123")?.displayName == "Research Agent")
        #expect(store.workspace(forAgentAddress: "0xabc123")?.name == "Acme")
        #expect(store.presence(forAddress: "0xnotshared") == .unknown)
        #expect(store.hasWorkspaces)
    }

    // MARK: - Force-offline override

    @Test func hostUnreachable_forcesOfflineUntilPollReportsOnline() throws {
        let store = makeStore()
        let clock = Date(timeIntervalSince1970: 1_000)
        store.now = { clock }
        let agent = try Self.agent(address: "0xaa", online: "true", lastSeen: "2026-03-01T12:00:00Z")
        let ws = try Self.workspace(id: "ws-1", name: "Acme")
        store.apply(rosters: [.init(workspace: ws, agents: [agent])])
        #expect(store.presence(forAddress: "0xaa") == .online)

        store.noteHostUnreachable(agentAddress: "0xAA")
        #expect(store.forcedOffline["0xaa"] == clock)
        // Router still says online, but the relay just failed: offline NOW,
        // carrying the roster's last-seen for the subtitle.
        #expect(
            store.presence(forAddress: "0xaa")
                == .offline(lastSeen: ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z"))
        )

        // A poll that still says offline/unknown keeps the override.
        let stillDown = try Self.agent(address: "0xaa", online: "false")
        store.apply(rosters: [.init(workspace: ws, agents: [stillDown])])
        #expect(store.forcedOffline["0xaa"] != nil)

        // A poll reporting online inside the relay's claim TTL is stale by
        // construction (the router's Redis view can lag a dead tunnel by up
        // to that long) — the relay verdict wins.
        store.now = { clock.addingTimeInterval(WorkspaceRosterStore.relayClaimTTL - 1) }
        store.apply(rosters: [.init(workspace: ws, agents: [agent])])
        #expect(store.forcedOffline["0xaa"] == nil, "a confirmed offline-to-online transition restores reachability immediately")
        #expect(store.presence(forAddress: "0xaa") == .online)

        // Once the TTL has passed, the router's online is trustworthy again.
        store.now = { clock.addingTimeInterval(WorkspaceRosterStore.relayClaimTTL) }
        store.apply(rosters: [.init(workspace: ws, agents: [agent])])
        #expect(store.forcedOffline.isEmpty)
        #expect(store.presence(forAddress: "0xaa") == .online)
    }

    @Test func hostReachable_clearsOverrideImmediately() throws {
        let store = makeStore()
        let agent = try Self.agent(address: "0xaa", online: "true")
        store.apply(rosters: [.init(workspace: try Self.workspace(id: "ws-1", name: "Acme"), agents: [agent])])
        store.noteHostUnreachable(agentAddress: "0xaa")
        #expect(store.presence(forAddress: "0xaa").isOffline)
        store.noteHostReachable(agentAddress: "0xAA")
        #expect(store.presence(forAddress: "0xaa") == .online)
    }

    @Test func indicatesHostUnreachable_classifiesTransportAndRelayErrors() {
        #expect(WorkspaceRosterStore.indicatesHostUnreachable(URLError(.timedOut)))
        #expect(WorkspaceRosterStore.indicatesHostUnreachable(URLError(.cannotConnectToHost)))
        #expect(!WorkspaceRosterStore.indicatesHostUnreachable(URLError(.userAuthenticationRequired)))

        struct Text: LocalizedError {
            let text: String
            var errorDescription: String? { text }
        }
        #expect(WorkspaceRosterStore.indicatesHostUnreachable(Text(text: "HTTP 502 Bad Gateway")))
        #expect(WorkspaceRosterStore.indicatesHostUnreachable(Text(text: "relay: agent offline")))
        #expect(!WorkspaceRosterStore.indicatesHostUnreachable(Text(text: "NOT_A_MEMBER")))
    }

    // MARK: - Own-agent detection

    @Test func isOwnAgent_matchesLocalAgentAddressCaseInsensitively() {
        var mine = Agent(name: "Mine")
        mine.agentAddress = "0xMyAgent"
        let other = Agent(name: "Other")

        #expect(WorkspaceRosterStore.isOwnAgent(address: "0xmyagent", localAgents: [mine, other]))
        #expect(WorkspaceRosterStore.isOwnAgent(address: "0XMYAGENT", localAgents: [mine]))
        #expect(!WorkspaceRosterStore.isOwnAgent(address: "0xsomeoneelse", localAgents: [mine, other]))
        #expect(!WorkspaceRosterStore.isOwnAgent(address: "0xmyagent", localAgents: []))
    }

    @Test func allAgents_dedupesAcrossWorkspacesByAddress() throws {
        let store = makeStore()
        let shared = try Self.agent(address: "0xaa", online: "true")
        let other = try Self.agent(address: "0xbb", name: "Writer", online: "null")
        store.apply(rosters: [
            .init(workspace: try Self.workspace(id: "ws-1", name: "Acme"), agents: [shared]),
            .init(workspace: try Self.workspace(id: "ws-2", name: "Beta"), agents: [shared, other]),
        ])
        #expect(store.allAgents.map(\.agentAddress) == ["0xaa", "0xbb"])
        #expect(store.workspacesSharing(agentAddress: "0xaa").map(\.id) == ["ws-1", "ws-2"])
        #expect(store.workspacesSharing(agentAddress: "0xbb").map(\.id) == ["ws-2"])
    }

    @Test func update_replacesOneWorkspaceAgentListImmediately() throws {
        // Settings ▸ Workspaces shares / unshares an agent and hands the
        // fresh list here so the chat sidebar reflects it before the poll.
        let store = makeStore()
        let acme = try Self.workspace(id: "ws-1", name: "Acme")
        let beta = try Self.workspace(id: "ws-2", name: "Beta")
        let existing = try Self.agent(address: "0xaa", online: "true")
        let other = try Self.agent(address: "0xbb", name: "Writer", online: "true")
        store.apply(rosters: [.init(workspace: acme, agents: [existing]), .init(workspace: beta, agents: [other])])

        let mine = try Self.agent(address: "0xmine", name: "My Agent", online: "true")
        store.update(workspaceId: "ws-1", agents: [existing, mine])
        #expect(store.rosters.first { $0.id == "ws-1" }?.agents.map(\.agentAddress) == ["0xaa", "0xmine"])
        #expect(
            store.rosters.first { $0.id == "ws-2" }?.agents.map(\.agentAddress) == ["0xbb"],
            "other workspaces untouched"
        )
        #expect(store.workspace(forAgentAddress: "0xmine")?.id == "ws-1")

        // Unshare: gone right away.
        store.update(workspaceId: "ws-1", agents: [existing])
        #expect(store.agent(forAddress: "0xmine") == nil)

        // Unknown workspace ids are ignored (a full refresh picks them up).
        store.update(workspaceId: "ws-unknown", agents: [mine])
        #expect(store.rosters.map(\.id) == ["ws-1", "ws-2"])
    }

    @Test func apply_recordsRefreshTimeAndSkipsNoopPublish() throws {
        let store = makeStore()
        let clock = Date(timeIntervalSince1970: 42)
        store.now = { clock }
        let roster = WorkspaceRosterStore.WorkspaceRoster(
            workspace: try Self.workspace(id: "ws-1", name: "Acme"),
            agents: [try Self.agent(address: "0xaa", online: "true")]
        )
        store.apply(rosters: [roster])
        #expect(store.lastRefreshedAt == clock)
        #expect(store.rosters == [roster])
    }
}
