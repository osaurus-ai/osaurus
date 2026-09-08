//
//  SharedAgentIdentityTests.swift
//  osaurusTests
//
//  The one identity model and one status vocabulary every shared-agent
//  surface renders from: name/model precedence, own-vs-teammate rules,
//  status derivation (incl. failed handshakes, offline beating stale
//  failures, Router-off), the own-agent relay mapping, and the
//  per-status presentation contract (action label, tint, glyph).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SharedAgentIdentityTests {

    private static let address = "0xAAAA000000000000000000000000000000000001"

    // MARK: - Fixtures (router types are Decodable-only)

    private static func rosterAgent(
        address: String = address,
        name: String? = "Editorial Writer",
        description: String? = nil,
        ownerName: String = "Alice"
    ) throws -> OsaurusRouterWorkspaceAgent {
        let nameJSON = name.map { "\"\($0)\"" } ?? "null"
        let descJSON = description.map { "\"\($0)\"" } ?? "null"
        let body = """
            {"agent_address": "\(address)", "display_name": \(nameJSON), "description": \(descJSON),
             "owner": {"account_id": "acct-1", "wallet_address": "0xowner", "display_name": "\(ownerName)"},
             "relay_url": "wss://relay.example", "online": true, "last_seen": null,
             "shared_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceAgent.self, from: Data(body.utf8))
    }

    private static func workspace(id: String = "ws-acme", name: String = "Acme") throws
        -> OsaurusRouterWorkspaceSummary
    {
        let body = """
            {"id": "\(id)", "name": "\(name)", "role": "member", "source": "subscription", "active": true,
             "members_active": 2, "agents_shared": 1, "created_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceSummary.self, from: Data(body.utf8))
    }

    private static func paired(
        name: String = "Dinoki",
        model: String? = "mlx-community/Qwen3-8B-4bit",
        workspaceId: String? = "ws-acme",
        avatar: String? = "dino"
    ) -> RemoteAgent {
        RemoteAgent(
            agentAddress: address,
            name: name,
            description: "",
            avatar: avatar,
            relayBaseURL: "https://x.agent.osaurus.ai",
            providerId: UUID(),
            model: model,
            workspaceId: workspaceId
        )
    }

    private func make(
        roster: OsaurusRouterWorkspaceAgent? = nil,
        workspace: OsaurusRouterWorkspaceSummary? = nil,
        paired: RemoteAgent? = nil,
        local: Agent? = nil,
        localEffectiveModel: String? = nil,
        liveEffectiveModel: String? = nil,
        lastKnownName: String? = nil,
        isMine: Bool = false
    ) -> SharedAgentIdentity {
        SharedAgentIdentity.make(
            address: Self.address,
            rosterAgent: roster,
            workspace: workspace,
            paired: paired,
            localAgent: local,
            localEffectiveModel: localEffectiveModel,
            liveEffectiveModel: liveEffectiveModel,
            lastKnownName: lastKnownName,
            isMine: isMine
        )
    }

    // MARK: - Name precedence

    @Test func name_teammate_prefersRosterDisplayNameOverPairedName() throws {
        // The "shared as Dinoki" bug: the pairing recorded a stale name but
        // the roster says what the sharer typed.
        let identity = make(roster: try Self.rosterAgent(name: "Editorial Writer"), paired: Self.paired(name: "Dinoki"))
        #expect(identity.name == "Editorial Writer")
        #expect(identity.ownerName == "Alice")
        #expect(!identity.isMine)
    }

    @Test func name_teammate_fallsBackToPairedThenLastKnownThenShortAddress() throws {
        #expect(make(paired: Self.paired(name: "Dinoki")).name == "Dinoki")
        #expect(make(lastKnownName: "Old Name").name == "Old Name")
        let bare = make()
        #expect(bare.name == SharedAgentIdentity.shortAddress(Self.address))
        #expect(bare.name.contains("…"))
        // Whitespace-only roster names don't win.
        #expect(make(roster: try Self.rosterAgent(name: "   "), paired: Self.paired(name: "Dinoki")).name == "Dinoki")
    }

    @Test func name_mine_isLocalAgentNameAndExposesSharedAsWhenRosterDiffers() throws {
        var local = Agent(name: "Editorial Writer")
        local.agentAddress = Self.address
        let identity = make(roster: try Self.rosterAgent(name: "Dinoki"), local: local, isMine: true)
        #expect(identity.name == "Editorial Writer")
        #expect(identity.sharedAsName == "Dinoki")
        #expect(identity.ownerName == nil)
        #expect(identity.isMine)
        #expect(!identity.isMissingLocally)

        let same = make(roster: try Self.rosterAgent(name: "Editorial Writer"), local: local, isMine: true)
        #expect(same.sharedAsName == nil)
    }

    @Test func mine_withoutLocalRecord_isMissingLocally() throws {
        let identity = make(roster: try Self.rosterAgent(), isMine: true)
        #expect(identity.isMissingLocally)
        #expect(identity.localAgent == nil)
        // Still named from the roster so the row isn't a bare address.
        #expect(identity.name == "Editorial Writer")
    }

    // MARK: - Model precedence

    @Test func model_teammate_liveBeatsPairedAndPairedBeatsNil() {
        #expect(make(paired: Self.paired(model: "paired-model"), liveEffectiveModel: "live-model").model == "live-model")
        #expect(make(paired: Self.paired(model: "paired-model"), liveEffectiveModel: "").model == "paired-model")
        #expect(make(paired: Self.paired(model: nil)).model == nil)
        #expect(make().modelLabel == nil)
    }

    @Test func model_mine_usesEffectiveModelThenDefaultModel() {
        var local = Agent(name: "Mine", defaultModel: "default-model")
        local.agentAddress = Self.address
        #expect(make(local: local, localEffectiveModel: "effective", isMine: true).model == "effective")
        #expect(make(local: local, isMine: true).model == "default-model")
    }

    // MARK: - Workspace / avatar / description

    @Test func workspace_fromRosterMatchElsePairedWorkspaceId() throws {
        let withRoster = make(workspace: try Self.workspace(id: "ws-1", name: "One"), paired: Self.paired(workspaceId: "ws-2"))
        #expect(withRoster.workspaceId == "ws-1")
        #expect(withRoster.workspaceName == "One")

        let pairedOnly = make(paired: Self.paired(workspaceId: "ws-2"))
        #expect(pairedOnly.workspaceId == "ws-2")
        #expect(pairedOnly.workspaceName == nil)
    }

    @Test func avatar_mineUsesLocal_teammateUsesPairedLiveAvatar() {
        var local = Agent(name: "Mine")
        local.avatar = "rex"
        #expect(make(local: local, isMine: true).avatar == "rex")
        #expect(make(paired: Self.paired(avatar: "dino")).avatar == "dino")
        #expect(make(paired: Self.paired(avatar: "dino"), local: local).avatar == "dino")
    }

    @Test func description_rosterFirstThenPairedThenLocal() throws {
        let identity = make(roster: try Self.rosterAgent(description: "Writes copy"), paired: Self.paired())
        #expect(identity.description == "Writes copy")
        let empty = make(roster: try Self.rosterAgent(description: "  "))
        #expect(empty.description == nil)
    }

    @Test func address_isLowercasedAndShortAddressKeepsShortInputs() {
        #expect(make().address == Self.address.lowercased())
        #expect(SharedAgentIdentity.shortAddress("0xabc") == "0xabc")
        #expect(SharedAgentIdentity.shortAddress(Self.address) == "0xAAAA…0001")
    }

    // MARK: - Status derivation

    private func derive(
        served: Bool = false,
        caller: String? = nil,
        workspaceId: String = "ws-acme",
        rosterLists: Bool = true,
        rosterHasLoaded: Bool = true,
        routerEnabled: Bool = true,
        workspaceName: String? = "Acme",
        presence: WorkspaceRosterStore.Presence = .online,
        isPaired: Bool = true,
        isBound: Bool = true,
        isPairing: Bool = false,
        failure: String? = nil,
        hasAttempted: Bool = false,
        phase: RemoteAgentConnectionPhase = .connected
    ) -> SharedAgentStatus {
        SharedAgentStatus.derive(
            isServedForTeammate: served,
            callerLabel: caller,
            workspaceId: workspaceId,
            rosterLists: rosterLists,
            rosterHasLoaded: rosterHasLoaded,
            routerEnabled: routerEnabled,
            workspaceName: workspaceName,
            presence: presence,
            isPaired: isPaired,
            isBoundToProvider: isBound,
            isPairing: isPairing,
            connectFailure: failure,
            hasAttempted: hasAttempted,
            phase: phase
        )
    }

    @Test func status_connectedPairedAgent_isReadyAndCanSend() {
        let status = derive()
        #expect(status == .ready)
        #expect(status.canSend)
        #expect(status.actionLabel == nil)
        #expect(!status.offersRetry)
    }

    @Test func status_pairedButHostRejected_isNotReady() {
        let status = derive(failure: "Host rejected the request", phase: .connected)
        #expect(!status.canSend)
        #expect(status == .notConnected(reason: "Host rejected the request", hasAttempted: true))
    }

    @Test func status_teammateServed_isReadOnlyRegardlessOfEverythingElse() {
        let status = derive(served: true, caller: "Bob", rosterLists: false, presence: .offline(lastSeen: nil), isPaired: false)
        #expect(status == .readOnlyTeammate(callerName: "Bob"))
        #expect(!status.canSend)
    }

    @Test func status_unavailable_whenRosterLoadedAndAgentGone() {
        if case .unavailable(_, let fix) = derive(rosterLists: false) {
            #expect(fix == .openWorkspaces)
        } else {
            Issue.record("expected unavailable")
        }
        // Router off is the reason when the roster can't list anything.
        if case .unavailable(_, let fix) = derive(rosterLists: false, routerEnabled: false) {
            #expect(fix == .enableRouter)
        } else {
            Issue.record("expected unavailable with enableRouter fix")
        }
    }

    @Test func status_neverUnavailableBeforeRosterLoadsOrForDirectShares() {
        #expect(derive(rosterLists: false, rosterHasLoaded: false, isPaired: false, phase: .idle)
            == .notConnected(reason: nil, hasAttempted: false))
        // Empty workspaceId = directly shared (invite link): roster never lists it.
        #expect(derive(workspaceId: "", rosterLists: false) == .ready)
    }

    @Test func status_offlineBeatsPairingAndStaleFailure() {
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let status = derive(presence: .offline(lastSeen: seen), isPaired: false, failure: "boom", hasAttempted: true)
        #expect(status == .offline(lastSeen: seen))
        #expect(status.offersRetry)
        #expect(status.actionLabel == L("Retry"))
    }

    @Test func status_unknownPresence_isNotOffline() {
        #expect(derive(presence: .unknown, isPaired: false, phase: .idle) == .checking)
        #expect(!derive(presence: .unknown).canSend)
    }

    @Test func status_unpaired_connectVersusRetry() {
        let fresh = derive(isPaired: false, phase: .idle)
        #expect(fresh == .notConnected(reason: nil, hasAttempted: false))
        #expect(fresh.actionLabel == L("Connect"))

        // Any recorded failure (manual OR automatic) surfaces and flips to Retry.
        let failed = derive(isPaired: false, failure: "Host refused", phase: .idle)
        #expect(failed == .notConnected(reason: "Host refused", hasAttempted: true))
        #expect(failed.actionLabel == L("Retry"))

        // Attempted with no reason recorded still reads as Retry.
        #expect(derive(isPaired: false, hasAttempted: true, phase: .idle).actionLabel == L("Retry"))

        // Mid-pairing is connecting.
        #expect(derive(isPaired: false, isPairing: true, phase: .idle) == .connecting)
        // Paired but not bound to a provider is still not connected.
        #expect(derive(isBound: false, phase: .idle) == .notConnected(reason: nil, hasAttempted: false))
    }

    @Test func status_pairedWindowPhase_mapsConnectingFailedConnected() {
        #expect(derive(phase: .connecting) == .connecting)
        #expect(derive(phase: .idle) == .connecting)
        let failed = derive(phase: .failed("The connection timed out."))
        #expect(failed == .notConnected(reason: "The connection timed out.", hasAttempted: true))
        #expect(failed.actionLabel == L("Retry"))
        #expect(derive(phase: .connected) == .ready)
    }

    // MARK: - Own-agent relay mapping

    @Test func forOwnAgent_mapsRelayTunnelState() {
        #expect(SharedAgentStatus.forOwnAgent(relayStatus: .connected(url: "https://x")) == .ready)
        #expect(SharedAgentStatus.forOwnAgent(relayStatus: .connecting) == .connecting)
        #expect(SharedAgentStatus.forOwnAgent(relayStatus: .error("Tunnel rejected")) == .notConnected(reason: "Tunnel rejected", hasAttempted: true))
        if case .notConnected(let reason, let attempted) = SharedAgentStatus.forOwnAgent(relayStatus: nil) {
            #expect(attempted == false)
            #expect(reason?.isEmpty == false)
        } else {
            Issue.record("relay off should read as notConnected")
        }
        #expect(SharedAgentStatus.forOwnAgent(relayStatus: .disconnected) == SharedAgentStatus.forOwnAgent(relayStatus: nil))
    }

    // MARK: - Presentation contract (badge mapping)

    @Test func presentation_eachStatusOwnsOneGlyphTintAndBadgeCopy() {
        let seen = Date()
        let cases: [(SharedAgentStatus, String, SharedAgentStatus.Tint)] = [
            (.ready, "lock.fill", .success),
            (.connecting, "arrow.triangle.2.circlepath", .accent),
            (.offline(lastSeen: seen), "moon.zzz.fill", .muted),
            (.notConnected(reason: nil, hasAttempted: false), "link.badge.plus", .warning),
            (.unavailable(reason: "gone", fix: .none), "person.crop.circle.badge.xmark", .muted),
            (.readOnlyTeammate(callerName: nil), "rectangle.3.group.fill", .muted),
        ]
        for (status, glyph, tint) in cases {
            #expect(status.symbolName == glyph)
            #expect(status.tint == tint)
            #expect(!status.shortLabel.isEmpty)
        }
        #expect(SharedAgentStatus.ready.shortLabel == L("End-to-end encrypted"))
        #expect(SharedAgentStatus.connecting.shortLabel == L("Connecting…"))
        #expect(SharedAgentStatus.notConnected(reason: nil, hasAttempted: true).shortLabel == L("Not connected"))
        #expect(SharedAgentStatus.unavailable(reason: "x", fix: .none).shortLabel == L("Unavailable"))
    }

    /// The lock notice splits into a one-line title and a reason caption; a
    /// failed attempt leads with "Couldn't connect", a never-attempted agent
    /// with "isn't connected yet", and reasons are normalized to sentences.
    @Test func noticeTitleAndDetail_splitByAttemptAndNormalizeReason() {
        let failed = SharedAgentStatus.notConnected(
            reason: "remote agent rejected the connection (check pairing and authorization)", hasAttempted: true
        )
        #expect(failed.title(agentName: "Weather Agent") == "Couldn't connect to Weather Agent")
        #expect(
            failed.detail(agentName: "Weather Agent", hostName: "Maggie")
                == "Remote agent rejected the connection (check pairing and authorization)."
        )

        let fresh = SharedAgentStatus.notConnected(reason: nil, hasAttempted: false)
        #expect(fresh.title(agentName: "Weather Agent") == "Weather Agent isn't connected yet")
        #expect(fresh.detail(agentName: "Weather Agent", hostName: nil) == L("Connect to start chatting over the encrypted relay."))

        let offline = SharedAgentStatus.offline(lastSeen: nil)
        #expect(offline.title(agentName: "Writer") == "Writer is offline")
        #expect(offline.detail(agentName: "Writer", hostName: "Alice")?.contains("Alice's Osaurus") == true)

        #expect(SharedAgentStatus.connecting.detail(agentName: "X", hostName: nil) == nil)
        #expect(SharedAgentStatus.ready.title(agentName: "X").isEmpty)

        // The tooltip sentence is title + detail.
        #expect(
            failed.message(agentName: "Weather Agent", hostName: nil)
                == "Couldn't connect to Weather Agent — Remote agent rejected the connection (check pairing and authorization)."
        )
    }
}
