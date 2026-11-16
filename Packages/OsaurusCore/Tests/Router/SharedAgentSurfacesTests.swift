//
//  SharedAgentSurfacesTests.swift
//  osaurusTests
//
//  Pure rules behind the shared-agent surfaces: the sidebar partitions
//  pairings by their PERSISTED workspace attribution (never by live roster
//  membership), a per-workspace roster fetch failure keeps the previous
//  agent list, the connect service's unified failure map lifecycle, the
//  Share sheet's already-shared / validation rules, and the Agents tab's
//  workspace attribution for remote cards.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SharedAgentSurfacesTests {

    private static let addressA = "0xAAAA000000000000000000000000000000000001"
    private static let addressB = "0xBBBB000000000000000000000000000000000002"

    // MARK: - Fixtures

    private static func rosterAgent(address: String, name: String = "Agent") throws -> OsaurusRouterWorkspaceAgent {
        let body = """
            {"agent_address": "\(address)", "display_name": "\(name)",
             "owner": {"account_id": "acct-1", "wallet_address": "0xowner", "display_name": "Alice"},
             "relay_url": "wss://relay.example", "online": true, "last_seen": null,
             "shared_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceAgent.self, from: Data(body.utf8))
    }

    private static func workspace(id: String, name: String, role: String = "member") throws
        -> OsaurusRouterWorkspaceSummary
    {
        let body = """
            {"id": "\(id)", "name": "\(name)", "role": "\(role)", "source": "subscription", "active": true,
             "members_active": 2, "agents_shared": 1, "created_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceSummary.self, from: Data(body.utf8))
    }

    private static func remote(address: String, name: String = "Remote", workspaceId: String?) -> RemoteAgent {
        RemoteAgent(
            agentAddress: address,
            name: name,
            description: "",
            relayBaseURL: "https://x.agent.osaurus.ai",
            providerId: UUID(),
            workspaceId: workspaceId
        )
    }

    // MARK: - Sidebar partition by persisted workspaceId

    @Test func sidebar_workspacePairing_neverReadsAsDirectlyShared_evenBeforeRosterLoads() {
        let workspacePaired = Self.remote(address: Self.addressA, workspaceId: "ws-1")
        let linkPaired = Self.remote(address: Self.addressB, workspaceId: nil)

        // Roster not loaded (onRoster false): the workspace pairing still
        // stays out of "Shared with you".
        #expect(!ChatSessionSidebar.isDirectlyShared(workspacePaired, onRoster: false, isOwn: false))
        #expect(ChatSessionSidebar.isDirectlyShared(linkPaired, onRoster: false, isOwn: false))
        // A link pairing that the roster now lists renders under its workspace.
        #expect(!ChatSessionSidebar.isDirectlyShared(linkPaired, onRoster: true, isOwn: false))
        // Own agents are never "shared with you".
        #expect(!ChatSessionSidebar.isDirectlyShared(linkPaired, onRoster: false, isOwn: true))
    }

    @Test func sidebar_orphanedPairings_groupByWorkspaceOnlyWhenRosterMissing() {
        let a = Self.remote(address: Self.addressA, workspaceId: "ws-1")
        let b = Self.remote(address: Self.addressB, workspaceId: "ws-2")
        let direct = Self.remote(address: "0xcc", workspaceId: nil)
        let empty = Self.remote(address: "0xdd", workspaceId: "")

        let none = ChatSessionSidebar.orphanedWorkspacePairings([a, b, direct, empty], loadedRosterIds: [])
        #expect(none.keys.sorted() == ["ws-1", "ws-2"])
        #expect(none["ws-1"]?.map(\.agentAddress) == [Self.addressA])

        let partial = ChatSessionSidebar.orphanedWorkspacePairings([a, b, direct], loadedRosterIds: ["ws-1"])
        #expect(partial.keys.sorted() == ["ws-2"])

        let all = ChatSessionSidebar.orphanedWorkspacePairings([a, b], loadedRosterIds: ["ws-1", "ws-2"])
        #expect(all.isEmpty)
    }

    // MARK: - Roster fetch failure preserves the previous list

    @Test func buildRosters_keepsPreviousAgentsWhenOneWorkspaceFetchFails() async throws {
        let ws1 = try Self.workspace(id: "ws-1", name: "One")
        let ws2 = try Self.workspace(id: "ws-2", name: "Two")
        let previousAgent = try Self.rosterAgent(address: Self.addressA, name: "Kept")
        let previous: [WorkspaceRosterStore.WorkspaceRoster] = [
            .init(workspace: ws1, agents: [previousAgent]),
            .init(workspace: ws2, agents: [try Self.rosterAgent(address: Self.addressB, name: "Old")]),
        ]
        let fresh = try Self.rosterAgent(address: Self.addressB, name: "Fresh")

        struct Boom: Error {}
        let next = await WorkspaceRosterStore.buildRosters(workspaces: [ws1, ws2], previous: previous) { id in
            if id == "ws-1" { throw Boom() }
            return [fresh]
        }

        #expect(next.map(\.id) == ["ws-1", "ws-2"])
        #expect(next[0].agents.map(\.displayName) == ["Kept"])
        #expect(next[1].agents.map(\.displayName) == ["Fresh"])
    }

    @Test func buildRosters_neverHadAList_failureYieldsEmptyNotCrash() async throws {
        let ws = try Self.workspace(id: "ws-new", name: "New")
        struct Boom: Error {}
        let next = await WorkspaceRosterStore.buildRosters(workspaces: [ws], previous: []) { _ in throw Boom() }
        #expect(next.count == 1)
        #expect(next[0].agents.isEmpty)
    }

    @Test func refreshFailureMessage_classifiesTransportVersusServer() {
        let offline = WorkspaceRosterStore.refreshFailureMessage(for: URLError(.notConnectedToInternet))
        #expect(offline == L("Couldn't reach Osaurus Router. Check your connection."))
        let generic = WorkspaceRosterStore.refreshFailureMessage(for: URLError(.badServerResponse))
        #expect(generic == L("Couldn't load your workspaces."))
    }

    // MARK: - Connect-service failure map lifecycle

    @Test func connectFailures_recordSurfacesAsAttempted_clearedByOfflineAndPrune() throws {
        let service = WorkspaceAgentConnectService.shared
        defer {
            service.clearFailure(for: Self.addressA)
            service.clearFailure(for: Self.addressB)
        }

        service.recordFailure("Host refused", for: Self.addressA.uppercased())
        #expect(service.connectFailure(for: Self.addressA) == "Host refused")
        #expect(service.hasAttempted(Self.addressA.lowercased()))

        // The row status shows the failure and offers Retry.
        let row = SharedAgentStatus.derive(
            isServedForTeammate: false, callerLabel: nil, workspaceId: "ws-1",
            rosterLists: true, rosterHasLoaded: true, routerEnabled: true, workspaceName: "One",
            presence: .unknown, isPaired: false, isBoundToProvider: false, isPairing: false,
            connectFailure: service.connectFailure(for: Self.addressA),
            hasAttempted: service.hasAttempted(Self.addressA), phase: .idle
        )
        #expect(row == .checking)
        #expect(row.actionLabel == nil)

        // Roster says offline → stale failure dropped, but "attempted" sticks.
        service.clearFailure(for: Self.addressA)
        #expect(service.connectFailure(for: Self.addressA) == nil)
        #expect(service.hasAttempted(Self.addressA))

        // Prune keeps only listed addresses.
        service.recordFailure("a", for: Self.addressA)
        service.recordFailure("b", for: Self.addressB)
        service.pruneFailures(keeping: [Self.addressB.lowercased()])
        #expect(service.connectFailure(for: Self.addressA) == nil)
        #expect(service.connectFailure(for: Self.addressB) == "b")
    }

    @Test func rosterApply_offlineAgentClearsRecordedFailure_andUnlistedIsPruned() throws {
        let service = WorkspaceAgentConnectService.shared
        let store = WorkspaceRosterStore(observeAppActivation: false)
        defer {
            service.clearFailure(for: Self.addressA, workspaceId: "ws-1")
            service.clearFailure(for: Self.addressB, workspaceId: "ws-1")
        }
        service.recordFailure("stale", for: Self.addressA, workspaceId: "ws-1")
        service.recordFailure("gone", for: Self.addressB, workspaceId: "ws-1")

        let offlineBody = """
            {"agent_address": "\(Self.addressA)", "display_name": "A",
             "owner": {"account_id": "acct-1", "wallet_address": "0xowner", "display_name": "Alice"},
             "relay_url": "wss://relay.example", "online": false, "last_seen": null,
             "shared_at": "2026-01-01T00:00:00Z"}
            """
        let offline = try JSONDecoder().decode(OsaurusRouterWorkspaceAgent.self, from: Data(offlineBody.utf8))
        store.apply(rosters: [.init(workspace: try Self.workspace(id: "ws-1", name: "One"), agents: [offline])])

        #expect(service.connectFailure(for: Self.addressA, workspaceId: "ws-1") == nil, "offline is the truer state")
        #expect(service.connectFailure(for: Self.addressB, workspaceId: "ws-1") == nil, "unlisted address pruned")
    }

    // MARK: - Roster lookups scoped per workspace

    @Test func rosterStore_agentForAddressWithinWorkspace_returnsThatWorkspacesRow() throws {
        let store = WorkspaceRosterStore(observeAppActivation: false)
        store.apply(rosters: [
            .init(workspace: try Self.workspace(id: "ws-1", name: "One"), agents: [try Self.rosterAgent(address: Self.addressA, name: "As One")]),
            .init(workspace: try Self.workspace(id: "ws-2", name: "Two"), agents: [try Self.rosterAgent(address: Self.addressA, name: "As Two")]),
        ])
        #expect(store.agent(forAddress: Self.addressA.uppercased(), workspaceId: "ws-2")?.displayName == "As Two")
        #expect(store.agent(forAddress: Self.addressA, workspaceId: "ws-1")?.displayName == "As One")
        #expect(store.agent(forAddress: Self.addressA, workspaceId: "ws-9") == nil)
    }

    // MARK: - Share sheet rules

    @Test func shareSheet_alreadySharedFilteringIsCaseInsensitive() throws {
        let roster = [try Self.rosterAgent(address: Self.addressA.uppercased())]
        let shared = WorkspaceShareAgentSheet.alreadySharedAddresses(roster: roster)
        #expect(shared.contains(Self.addressA.lowercased()))
        #expect(!shared.contains(Self.addressB.lowercased()))
    }

    @Test func shareSheet_displayNameValidation_isOneToOneTwenty() {
        #expect(!WorkspaceShareAgentSheet.displayNameIsValid(""))
        #expect(!WorkspaceShareAgentSheet.displayNameIsValid("   "))
        #expect(WorkspaceShareAgentSheet.displayNameIsValid("Editorial Writer"))
        #expect(WorkspaceShareAgentSheet.displayNameIsValid(String(repeating: "x", count: 120)))
        #expect(!WorkspaceShareAgentSheet.displayNameIsValid(String(repeating: "x", count: 121)))
    }

    @Test func shareSheet_nextDisplayName_followsSelectionOnlyWhileUntouched() {
        // Empty → prefill.
        #expect(WorkspaceShareAgentSheet.nextDisplayName(current: "", prefilled: nil, selectedAgentName: "A") == "A")
        // Still the previous prefill → follows the new selection.
        #expect(WorkspaceShareAgentSheet.nextDisplayName(current: "A", prefilled: "A", selectedAgentName: "B") == "B")
        // User typed something → preserved.
        #expect(WorkspaceShareAgentSheet.nextDisplayName(current: "My Name", prefilled: "A", selectedAgentName: "B") == "My Name")
    }

    @Test func workspaceNameValidation_isOneToEighty() {
        #expect(!WorkspaceNameValidation.isValid(" "))
        #expect(WorkspaceNameValidation.isValid("Acme"))
        #expect(WorkspaceNameValidation.isValid(String(repeating: "x", count: 80)))
        #expect(!WorkspaceNameValidation.isValid(String(repeating: "x", count: 81)))
    }

    // MARK: - Agents tab attribution

    @Test func remoteAttribution_prefersPersistedWorkspaceIdThenRoster() throws {
        let ws1 = try Self.workspace(id: "ws-1", name: "One")
        let ws2 = try Self.workspace(id: "ws-2", name: "Two")
        let paired = Self.remote(address: Self.addressA, workspaceId: "ws-2")
        #expect(RemoteAgentWorkspaceAttribution.workspace(for: paired, in: [ws1, ws2])?.id == "ws-2")
        // Persisted id for a workspace the user left → no attribution from the list.
        let left = Self.remote(address: Self.addressB, workspaceId: "ws-gone")
        #expect(RemoteAgentWorkspaceAttribution.workspace(for: left, in: [ws1, ws2]) == nil)
    }

    @Test func remoteAttribution_removeCopyDistinguishesWorkspaceFromShareLink() {
        let workspaceManaged = Self.remote(address: Self.addressA, name: "Writer", workspaceId: "ws-1")
        let linkShared = Self.remote(address: Self.addressB, name: "Writer", workspaceId: nil)
        #expect(RemoteAgentWorkspaceAttribution.removeMessage(for: workspaceManaged).contains("workspace"))
        #expect(RemoteAgentWorkspaceAttribution.removeMessage(for: linkShared).contains("share link"))
        #expect(RemoteAgentWorkspaceAttribution.removeMessage(for: linkShared).contains("Writer"))
    }

    @Test func sharedWithSection_listsSharedAndShareableWorkspaces() throws {
        let store = WorkspaceRosterStore(observeAppActivation: false)
        var mine = Agent(name: "Mine")
        mine.agentAddress = Self.addressA
        let ws1 = try Self.workspace(id: "ws-1", name: "One", role: "owner")
        let ws2 = try Self.workspace(id: "ws-2", name: "Two", role: "member")
        let ws3 = try Self.workspace(id: "ws-3", name: "Three", role: "viewer")
        store.apply(rosters: [
            .init(workspace: ws1, agents: [try Self.rosterAgent(address: Self.addressA)]),
            .init(workspace: ws2, agents: []),
            .init(workspace: ws3, agents: []),
        ])

        #expect(AgentSharedWithSection.sharedWorkspaces(for: mine, rosterStore: store).map(\.id) == ["ws-1"])
        // Shareable = not already shared AND role can share (viewer can't).
        #expect(
            AgentSharedWithSection.shareableWorkspaces(for: mine, workspaces: [ws1, ws2, ws3], rosterStore: store).map(\.id)
                == ["ws-2"]
        )
        // No identity address → nothing shared.
        #expect(AgentSharedWithSection.sharedWorkspaces(for: Agent(name: "Fresh"), rosterStore: store).isEmpty)
    }
}
