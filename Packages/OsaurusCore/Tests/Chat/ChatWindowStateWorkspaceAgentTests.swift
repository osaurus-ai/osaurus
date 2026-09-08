//
//  ChatWindowStateWorkspaceAgentTests.swift
//  osaurusTests
//
//  Picking a workspace teammate's shared agent from the sidebar must feel
//  like picking a local agent: a blank tab is repurposed (stamped with the
//  agent's `WorkspaceSessionContext`), a non-blank tab opens a new one, an
//  existing blank tab for the same agent is focused, and switching back to
//  a local agent drops the workspace identity so a send can never route to
//  the wrong agent. The composer lock derives from roster presence +
//  pairing + connection phase so an offline / unpaired / connecting agent
//  is browsable but never sendable.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatWindowStateWorkspaceAgentTests {

    private static let addressA = "0xAAAA000000000000000000000000000000000001"
    private static let addressB = "0xBBBB000000000000000000000000000000000002"

    // MARK: - Roster fixtures

    private static func rosterAgent(
        address: String,
        name: String,
        online: String,
        lastSeen: String? = nil
    ) throws -> OsaurusRouterWorkspaceAgent {
        let lastSeenJSON = lastSeen.map { "\"\($0)\"" } ?? "null"
        let body = """
            {"agent_address": "\(address)", "display_name": "\(name)",
             "owner": {"account_id": "acct-1", "wallet_address": "0xowner", "display_name": "Alice"},
             "relay_url": "wss://relay.example", "online": \(online), "last_seen": \(lastSeenJSON),
             "shared_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceAgent.self, from: Data(body.utf8))
    }

    private static func workspace(id: String, name: String) throws -> OsaurusRouterWorkspaceSummary {
        let body = """
            {"id": "\(id)", "name": "\(name)", "role": "member", "source": "subscription", "active": true,
             "members_active": 2, "agents_shared": 2, "created_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceSummary.self, from: Data(body.utf8))
    }

    /// Install a two-agent roster on the shared store for the duration of
    /// `body`, then clear it so other suites see an empty store.
    private func withRoster(
        aOnline: String = "true",
        bOnline: String = "true",
        bLastSeen: String? = nil,
        _ body: @MainActor () async throws -> Void
    ) async throws {
        let store = WorkspaceRosterStore.shared
        store.apply(rosters: [
            .init(
                workspace: try Self.workspace(id: "ws-acme", name: "Acme"),
                agents: [
                    try Self.rosterAgent(address: Self.addressA, name: "Research Agent", online: aOnline),
                    try Self.rosterAgent(
                        address: Self.addressB,
                        name: "Writer",
                        online: bOnline,
                        lastSeen: bLastSeen
                    ),
                ]
            )
        ])
        defer { store.apply(rosters: []) }
        try await body()
    }

    private func lowered(_ address: String) -> String { address.lowercased() }

    // MARK: - Switching

    @Test func switchToWorkspaceAgent_repurposesBlankTabAndStampsContext() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                #expect(window.tabs.count == 1)

                window.switchToWorkspaceAgent(address: Self.addressA)

                #expect(window.tabs.count == 1, "a blank tab is repurposed, not duplicated")
                #expect(window.agentId == Agent.defaultId, "Mode 2 needs a host agent id")
                let context = try #require(window.session.workspaceContext)
                #expect(context.agentAddress == lowered(Self.addressA), "address is stored lowercased")
                #expect(context.workspaceId == "ws-acme", "workspace id is resolved from the roster")
                #expect(context.isServedForTeammate == false)
                #expect(window.workspaceAgentAddress == lowered(Self.addressA))
            }
        }
    }

    @Test func switchToWorkspaceAgent_fromLocalAgentBlankTab_replacesLocalIdentity() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let custom = Agent(name: "Custom-\(UUID().uuidString.prefix(6))")
                AgentManager.shared.add(custom)

                let window = ChatWindowState(windowId: UUID(), agentId: custom.id)

                window.switchToWorkspaceAgent(address: Self.addressB)

                #expect(window.tabs.count == 1)
                #expect(window.agentId == Agent.defaultId)
                #expect(window.session.workspaceContext?.agentAddress == lowered(Self.addressB))

                window.cleanup()
                _ = await AgentManager.shared.delete(id: custom.id)
            }
        }
    }

    @Test func switchToWorkspaceAgent_onNonBlankTab_opensNewTab() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.session.turns.append(ChatTurn(role: .user, content: "keep me"))
                let firstTab = window.activeTabId

                window.switchToWorkspaceAgent(address: Self.addressA)

                #expect(window.tabs.count == 2, "a non-blank tab is preserved; the team agent opens beside it")
                #expect(window.activeTabId != firstTab)
                #expect(window.session.turns.isEmpty)
                #expect(window.session.workspaceContext?.agentAddress == lowered(Self.addressA))
                let original = try #require(window.tabs.first { $0.id == firstTab })
                #expect(original.session.workspaceContext == nil, "the local tab keeps its identity")
            }
        }
    }

    @Test func switchToWorkspaceAgent_focusesExistingBlankTabForSameAgent() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                // Tab 1: local, non-blank. Tab 2: blank team-agent tab for A.
                window.session.turns.append(ChatTurn(role: .user, content: "local work"))
                let localTab = window.activeTabId
                window.switchToWorkspaceAgent(address: Self.addressA)
                let teamTab = window.activeTabId
                #expect(window.tabs.count == 2)

                window.selectTab(id: localTab)
                #expect(window.workspaceAgentAddress == nil, "selecting a local tab leaves remote mode")

                window.switchToWorkspaceAgent(address: Self.addressA)
                #expect(window.tabs.count == 2, "the existing blank team-agent tab is focused, not duplicated")
                #expect(window.activeTabId == teamTab)
                #expect(window.workspaceAgentAddress == lowered(Self.addressA))
            }
        }
    }

    @Test func switchToWorkspaceAgent_blankTabForOtherAgent_isRepurposed() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)
                window.switchToWorkspaceAgent(address: Self.addressB)

                #expect(window.tabs.count == 1)
                #expect(window.session.workspaceContext?.agentAddress == lowered(Self.addressB))
                #expect(window.workspaceAgentAddress == lowered(Self.addressB))
            }
        }
    }

    @Test func switchAgent_backToLocal_dropsWorkspaceIdentityAndRemoteMode() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)
                #expect(window.workspaceAgentAddress != nil)

                window.switchAgent(to: Agent.defaultId)

                #expect(window.tabs.count == 1)
                #expect(window.session.workspaceContext == nil)
                #expect(window.workspaceAgentAddress == nil)
                #expect(window.selectedDiscoveredAgentProviderId == nil)
                #expect(window.composerLock == nil)
            }
        }
    }

    @Test func startNewChat_inTeamAgentTab_staysWithThatAgent() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)

                window.startNewChat()

                #expect(window.tabs.count == 1)
                #expect(
                    window.session.workspaceContext?.agentAddress == lowered(Self.addressA),
                    "New Chat inside a team-agent tab keeps talking to that agent"
                )
            }
        }
    }

    @Test func startNewChat_onHostServedReadOnlyRow_becomesPlainLocalChat() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.session.workspaceContext = WorkspaceSessionContext(
                    workspaceId: "ws-acme",
                    agentAddress: Self.addressA,
                    callerWallet: "0xcaller",
                    callerName: "Alice"
                )
                #expect(
                    window.composerLock
                        == .teammateConversation(
                            callerName: "Alice",
                            agentName: "Research Agent",
                            isWorkspace: true
                        )
                )

                window.startNewChat()

                #expect(window.session.workspaceContext == nil)
                #expect(window.composerLock == nil)
            }
        }
    }

    @Test func loadSession_reAdoptsTeamAgentAndClearsOnLocalHistory() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let manager = ChatSessionsManager.shared
                let teamRow = ChatSessionData(
                    id: UUID(),
                    title: "Earlier with Research Agent",
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: 2),
                    selectedModel: "m",
                    turns: [
                        ChatTurnData(role: .user, content: "hello"),
                        ChatTurnData(role: .assistant, content: "hi"),
                    ],
                    agentId: Agent.defaultId,
                    workspace: WorkspaceSessionContext(workspaceId: "ws-acme", agentAddress: Self.addressA)
                )
                let localRow = ChatSessionData(
                    id: UUID(),
                    title: "Local",
                    createdAt: Date(timeIntervalSince1970: 3),
                    updatedAt: Date(timeIntervalSince1970: 4),
                    selectedModel: "m",
                    turns: [ChatTurnData(role: .user, content: "local")],
                    agentId: Agent.defaultId
                )
                manager.save(teamRow)
                manager.save(localRow)
                defer {
                    manager.delete(id: teamRow.id)
                    manager.delete(id: localRow.id)
                }

                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }

                // History for a team-agent tab is keyed by address.
                window.switchToWorkspaceAgent(address: Self.addressA)
                #expect(window.filteredSessions.map(\.id) == [teamRow.id])

                window.loadSession(teamRow)
                #expect(window.session.sessionId == teamRow.id)
                #expect(window.session.workspaceContext?.agentAddress == lowered(Self.addressA))
                #expect(window.workspaceAgentAddress == lowered(Self.addressA), "reopening re-binds remote mode")
                #expect(window.composerLock != nil, "unpaired in tests → still locked, but browsable")

                window.loadSession(localRow)
                #expect(window.session.sessionId == localRow.id)
                #expect(window.session.workspaceContext == nil)
                #expect(window.workspaceAgentAddress == nil, "a local conversation leaves remote mode")
                #expect(window.composerLock == nil)
                #expect(window.filteredSessions.contains { $0.id == localRow.id })
                #expect(!window.filteredSessions.contains { $0.id == teamRow.id })
            }
        }
    }

    // MARK: - Composer lock derivation

    @Test func composerLock_isNilForLocalTabs() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            #expect(window.composerLock == nil)
        }
    }

    @Test func composerLock_offlineAgent_locksWithOwnerAndLastSeen() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster(bOnline: "false", bLastSeen: "2026-03-01T12:00:00Z") {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressB)

                let lock = try #require(window.composerLock)
                guard case .agentOffline(let name, let owner, let lastSeen) = lock else {
                    Issue.record("expected agentOffline, got \(lock)")
                    return
                }
                #expect(name == "Writer")
                #expect(owner == "Alice")
                #expect(lastSeen == ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z"))
                // Offline: no connect is queued for the view — Retry re-issues it.
                #expect(window.pendingRelayConnect == nil)
                #expect(window.remoteAgentConnectionPhase == .idle)
            }
        }
    }

    @Test func composerLock_unpairedOnlineAgent_isNotConnected() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)

                // No paired RemoteAgent/provider exists for this address in
                // the test environment, so the agent is "not connected yet".
                let lock = try #require(window.composerLock)
                guard case .agentNotConnected(let name, _) = lock else {
                    Issue.record("expected agentNotConnected, got \(lock)")
                    return
                }
                #expect(name == "Research Agent")
                #expect(window.selectedDiscoveredAgentProviderId == nil)
            }
        }
    }

    @Test func composerLock_unknownPresence_pausesWhileChecking() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster(aOnline: "null") {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)

                #expect(window.sharedAgentStatus == .checking)
                let lock = try #require(window.composerLock)
                guard case .connecting = lock else {
                    Issue.record("unknown presence must never read as offline; got \(lock)")
                    return
                }
            }
        }
    }

    @Test func composerLock_forcedOffline_overridesRouterOnline() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)

                WorkspaceRosterStore.shared.noteHostUnreachable(agentAddress: Self.addressA)
                defer { WorkspaceRosterStore.shared.noteHostReachable(agentAddress: Self.addressA) }

                guard case .agentOffline = window.composerLock else {
                    Issue.record("a relay failure must lock the composer as offline immediately")
                    return
                }
            }
        }
    }

    @Test func composerLock_teammateConversation_isReadOnlyWithCallerLabel() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.session.workspaceContext = WorkspaceSessionContext(
                    workspaceId: "ws-acme",
                    agentAddress: Self.addressA,
                    callerWallet: "0xCALLER00000000000000000000000000000000AA"
                )
                #expect(
                    window.composerLock
                        == .teammateConversation(
                            callerName: "0xcall…00aa",
                            agentName: "Research Agent",
                            isWorkspace: true
                        )
                )
                // A host-served row never binds remote mode.
                window.reconcileRemoteMode()
                #expect(window.workspaceAgentAddress == nil)
            }
        }
    }

    @Test func composerLock_directShareHostedRow_isReadOnlyAndNamesTheLocalAgent() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let local = Agent(name: "Ops Helper")
                AgentManager.shared.add(local)
                defer { Task { _ = await AgentManager.shared.delete(id: local.id) } }
                let window = ChatWindowState(windowId: UUID(), agentId: local.id)
                defer { window.cleanup() }
                // Invite-link peer: no workspace, no resolvable address —
                // the row's agent id names the agent.
                window.session.workspaceContext = WorkspaceSessionContext(
                    workspaceId: "",
                    agentAddress: "",
                    callerWallet: "key-nonce-1",
                    callerName: "Bob's laptop"
                )
                #expect(
                    window.composerLock
                        == .teammateConversation(
                            callerName: "Bob's laptop",
                            agentName: "Ops Helper",
                            isWorkspace: false
                        )
                )
                window.reconcileRemoteMode()
                #expect(window.workspaceAgentAddress == nil)
            }
        }
    }

    // MARK: - Roster drift after the tab was opened

    @Test func composerLock_agentUnsharedWhileTabOpen_locksAsUnavailable() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)

                // Owner unshares Research Agent; the next poll drops it from
                // the (still present) Acme roster.
                WorkspaceRosterStore.shared.apply(rosters: [
                    .init(
                        workspace: try Self.workspace(id: "ws-acme", name: "Acme"),
                        agents: [try Self.rosterAgent(address: Self.addressB, name: "Writer", online: "true")]
                    )
                ])

                let lock = try #require(window.composerLock)
                guard case .agentUnavailable(let agentName, let reason) = lock else {
                    Issue.record("an unshared agent must lock as unavailable, not connectable; got \(lock)")
                    return
                }
                #expect(agentName == "Research Agent", "name survives from the stamped session")
                if OsaurusRouter.isEnabled {
                    #expect(reason.contains("Acme"), "reason names the workspace it was shared in")
                }
                #expect(lock.offersRetry == false, "nothing to retry — the key is revoked")
            }
        }
    }

    @Test func composerLock_removedFromWorkspaceWhileTabOpen_locksAsUnavailable() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)

                // The user leaves / is removed: the whole workspace vanishes
                // from a *loaded* roster.
                WorkspaceRosterStore.shared.apply(rosters: [])

                guard case .agentUnavailable(_, let reason) = window.composerLock else {
                    Issue.record(
                        "losing membership must lock the composer; got \(String(describing: window.composerLock))"
                    )
                    return
                }
                if OsaurusRouter.isEnabled {
                    #expect(reason.contains("member"))
                }
            }
        }
    }

    @Test func composerLock_agentMissingBeforeAnyRosterLoad_doesNotReadAsUnavailable() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            // A tab restored from history for an agent the (empty, never
            // loaded) store doesn't know yet — e.g. before the first poll
            // completes. Must not claim it was unshared.
            window.session.workspaceContext = WorkspaceSessionContext(
                workspaceId: "ws-acme",
                agentAddress: Self.addressA
            )
            WorkspaceRosterStore.shared.resetForTesting()

            if case .agentUnavailable = window.composerLock {
                Issue.record("an unloaded roster is not evidence the agent was unshared")
            }
        }
    }

    // MARK: - Directly shared agents (invite link, no workspace)

    /// The sidebar's "Shared with you" rows and Settings ▸ Agents ▸ Chat both
    /// route a paired agent that sits on no roster through the same path as a
    /// team agent. The stamped context carries an empty workspace id, the
    /// window binds to that address, and the lock reflects pairing state —
    /// never "no longer shared", even after the roster has loaded.
    @Test func switchToWorkspaceAgent_directlySharedAgent_stampsEmptyWorkspaceIdAndIsNeverUnavailable()
        async throws
    {
        try await ChatHistoryTestStorage.run {
            // A loaded roster that does NOT list this agent.
            try await withRoster {
                let direct = "0xDDDD000000000000000000000000000000000003"
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }

                window.switchToWorkspaceAgent(address: direct)

                let context = try #require(window.session.workspaceContext)
                #expect(context.agentAddress == lowered(direct))
                #expect(context.workspaceId.isEmpty, "no roster → no workspace id")
                #expect(window.workspaceAgentAddress == lowered(direct), "sidebar row selection follows")
                #expect(window.filteredSessions.isEmpty, "history is keyed by the agent's address")

                switch window.composerLock {
                case .agentUnavailable:
                    Issue.record("a directly shared agent is not a lost workspace agent")
                case .agentOffline:
                    Issue.record("no router presence exists for a directly shared agent")
                case .agentNotConnected, .connecting, nil:
                    break  // pairing / connection state drives the lock
                case .teammateConversation:
                    Issue.record("client-side chat, not a host-served row")
                }
            }
        }
    }

    // MARK: - Failure mirroring

    /// The window's relay connect verdict is mirrored into the connect
    /// service's failure map — the one map every list row reads — so the
    /// sidebar / Workspaces rows can't show a green "ready" dot while the
    /// composer says the connect was rejected. A new attempt clears it.
    @Test func connectionPhaseFailure_isMirroredIntoConnectServiceAndClearedOnRetry() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let connect = WorkspaceAgentConnectService.shared
                let address = lowered(Self.addressA)
                connect.clearFailure(for: address, workspaceId: "ws-acme")
                defer { connect.clearFailure(for: address, workspaceId: "ws-acme") }

                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)
                #expect(window.workspaceAgentAddress == address)

                window.remoteAgentConnectionPhase = .failed("Remote agent rejected the connection.")
                #expect(connect.connectFailure(for: address, workspaceId: "ws-acme") == "Remote agent rejected the connection.")
                #expect(connect.hasAttempted(address, workspaceId: "ws-acme"))

                window.remoteAgentConnectionPhase = .connecting
                #expect(connect.connectFailure(for: address, workspaceId: "ws-acme") == nil, "a fresh attempt supersedes the verdict")

                window.remoteAgentConnectionPhase = .failed("timed out")
                #expect(connect.connectFailure(for: address, workspaceId: "ws-acme") == "timed out")

                window.remoteAgentConnectionPhase = .connected
                #expect(connect.connectFailure(for: address, workspaceId: "ws-acme") == nil)
            }
        }
    }

    // MARK: - Pairing repair after a peer rejection

    /// The host answering 4xx to our key is a stale attestation, not a dead
    /// agent: the window re-runs the workspace handshake once, mints a fresh
    /// pairing + provider, and rebinds so the connect runs again. A second
    /// refusal in the same bind is surfaced instead of looping; a later
    /// `.connected` re-arms the repair for the next expiry.
    @Test func repairAfterRejection_reHandshakesOnceThenRearmsOnConnected() async throws {
        try await ChatHistoryTestStorage.run {
            try await withRoster {
                let connect = WorkspaceAgentConnectService.shared
                let address = lowered(Self.addressA)
                var handshakes = 0
                connect.testHandshakeOverride = { workspaceId, agentAddress in
                    handshakes += 1
                    #expect(workspaceId == "ws-acme", "the roster's workspace is used")
                    #expect(agentAddress.lowercased() == address)
                    return .init(
                        agentAddress: agentAddress,
                        agentName: "Research Agent",
                        agentDescription: nil,
                        agentModel: "gpt-5.6-sol",
                        apiKey: "fresh-key-\(handshakes)",
                        attestationExpiresAt: nil
                    )
                }
                defer {
                    connect.testHandshakeOverride = nil
                    if let paired = RemoteAgentManager.shared.remoteAgent(forAddress: address) {
                        RemoteAgentManager.shared.remove(id: paired.id)
                    }
                    connect.clearFailure(for: address, workspaceId: "ws-acme")
                }

                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)
                #expect(RemoteAgentManager.shared.remoteAgent(forAddress: address) == nil)

                // Rejection → one silent repair: new pairing, rebind queued.
                #expect(await window.repairWorkspacePairingAfterRejection())
                #expect(handshakes == 1)
                let paired = try #require(RemoteAgentManager.shared.remoteAgent(forAddress: address))
                #expect(paired.workspaceId == "ws-acme")
                #expect(window.selectedDiscoveredAgentProviderId == paired.providerId, "bound to the fresh provider")
                #expect(window.pendingRelayConnect != nil, "the connect runs again against the new key")

                // Second refusal in the same bind: no loop, the failure surfaces.
                #expect(await window.repairWorkspacePairingAfterRejection() == false)
                #expect(handshakes == 1)

                // A successful connect re-arms the repair for a later expiry.
                window.remoteAgentConnectionPhase = .connected
                #expect(await window.repairWorkspacePairingAfterRejection())
                #expect(handshakes == 2)
            }
        }
    }

    /// Nothing to repair on a local tab, and a handshake that fails leaves
    /// the caller to surface the original rejection.
    @Test func repairAfterRejection_returnsFalseWithoutWorkspaceOrOnHandshakeFailure() async throws {
        try await ChatHistoryTestStorage.run {
            let connect = WorkspaceAgentConnectService.shared
            var handshakes = 0
            connect.testHandshakeOverride = { _, _ in
                handshakes += 1
                struct Refused: Error {}
                throw Refused()
            }
            defer { connect.testHandshakeOverride = nil }

            let local = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { local.cleanup() }
            #expect(await local.repairWorkspacePairingAfterRejection() == false)
            #expect(handshakes == 0, "a local tab never handshakes")

            try await withRoster {
                let address = lowered(Self.addressA)
                defer { connect.clearFailure(for: address, workspaceId: "ws-acme") }
                let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
                defer { window.cleanup() }
                window.switchToWorkspaceAgent(address: Self.addressA)

                #expect(await window.repairWorkspacePairingAfterRejection() == false)
                #expect(handshakes == 1)
                #expect(RemoteAgentManager.shared.remoteAgent(forAddress: address) == nil)
                #expect(window.selectedDiscoveredAgentProviderId == nil)
            }
        }
    }

    @Test func isPeerRejection_matchesOnlyTheHandshakeRefusal() {
        #expect(
            RemoteProviderService.isPeerRejection(
                RemoteProviderServiceError.requestFailed(RemoteProviderService.peerRejectedConnectionMessage)
            )
        )
        #expect(
            !RemoteProviderService.isPeerRejection(
                RemoteProviderServiceError.requestFailed(
                    "Could not reach the remote agent (Secure Channel handshake failed)."
                )
            )
        )
        #expect(!RemoteProviderService.isPeerRejection(RemoteProviderServiceError.notConnected))
        #expect(!RemoteProviderService.isPeerRejection(URLError(.timedOut)))
    }

    /// A local tab has no workspace agent bound; its Mode 2 phase changes
    /// must not touch the workspace failure map.
    @Test func connectionPhaseFailure_onLocalTab_doesNotTouchConnectService() async throws {
        try await ChatHistoryTestStorage.run {
            let connect = WorkspaceAgentConnectService.shared
            let before = connect.connectFailures
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            #expect(window.workspaceAgentAddress == nil)

            window.remoteAgentConnectionPhase = .failed("nope")
            #expect(connect.connectFailures == before)
        }
    }
}
