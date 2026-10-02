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

    @Test func isHostedHere_matchesLocalAgentAddressCaseInsensitively() {
        var mine = Agent(name: "Mine")
        mine.agentAddress = "0xMyAgent"
        let other = Agent(name: "Other")

        #expect(WorkspaceRosterStore.isHostedHere(address: "0xmyagent", localAgents: [mine, other]))
        #expect(WorkspaceRosterStore.isHostedHere(address: "0XMYAGENT", localAgents: [mine]))
        #expect(!WorkspaceRosterStore.isHostedHere(address: "0xsomeoneelse", localAgents: [mine, other]))
        #expect(!WorkspaceRosterStore.isHostedHere(address: "0xmyagent", localAgents: []))
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

    // MARK: - Orchestrator spawn-pool auto-join hook

    /// `apply` hands the reconciler the shared agents not hosted here and
    /// the workspaces whose membership is known: the verified ones plus any
    /// workspace that vanished from the list (left / deleted). Without an
    /// installed reconciler nothing is called — roster fixtures in other
    /// suites never touch the delegation store.
    @Test func apply_reportsSharedAgentsAndKnownWorkspacesToSpawnPoolReconciler() throws {
        let store = makeStore()
        let previous = WorkspaceRosterStore.spawnPoolReconciler
        defer { WorkspaceRosterStore.spawnPoolReconciler = previous }

        final class Box: @unchecked Sendable {
            var calls: [(refs: [WorkspaceAgentRef], loaded: Set<String>)] = []
        }
        let box = Box()
        WorkspaceRosterStore.spawnPoolReconciler = { refs, loaded in
            box.calls.append((refs, loaded))
        }

        let ws1 = WorkspaceRosterStore.WorkspaceRoster(
            workspace: try Self.workspace(id: "ws-1", name: "Acme"),
            agents: [try Self.agent(address: "0xaa", online: "true")]
        )
        let ws2 = WorkspaceRosterStore.WorkspaceRoster(
            workspace: try Self.workspace(id: "ws-2", name: "Beta"),
            agents: [try Self.agent(address: "0xbb", online: "false")]
        )
        // Full refresh where only ws-1's agent list was fetched.
        store.apply(rosters: [ws1, ws2], verifiedWorkspaceIds: ["ws-1"])
        #expect(box.calls.count == 1)
        #expect(
            Set(box.calls[0].refs)
                == [
                    WorkspaceAgentRef(workspaceId: "ws-1", agentAddress: "0xaa"),
                    WorkspaceAgentRef(workspaceId: "ws-2", agentAddress: "0xbb"),
                ]
        )
        #expect(box.calls[0].loaded == ["ws-1"], "unverified ws-2 is not reported as known")

        // The user leaves ws-2: it disappears from the list, so it is known
        // (its refs must prune) even though nothing loaded for it.
        store.apply(rosters: [ws1])
        #expect(box.calls.count == 2)
        #expect(box.calls[1].loaded == ["ws-1", "ws-2"])
        #expect(box.calls[1].refs.map(\.workspaceId) == ["ws-1"])

        // No reconciler installed → no call.
        WorkspaceRosterStore.spawnPoolReconciler = nil
        store.apply(rosters: [ws1, ws2])
        #expect(box.calls.count == 2)
    }

    // MARK: - Default pool-billing hook

    /// `apply` hands the pool-billing reconciler only the rosters the router
    /// just VERIFIED: a workspace whose agent fetch failed keeps stale agents
    /// and must not seed a billing binding. Nothing is called without an
    /// installed reconciler, so roster fixtures never touch UserDefaults.
    @Test func apply_reportsOnlyVerifiedRostersToDefaultPoolBillingReconciler() throws {
        let store = makeStore()
        let previous = WorkspaceRosterStore.defaultPoolBillingReconciler
        defer { WorkspaceRosterStore.defaultPoolBillingReconciler = previous }

        final class Box: @unchecked Sendable {
            var calls: [[String]] = []
        }
        let box = Box()
        WorkspaceRosterStore.defaultPoolBillingReconciler = { rosters in
            box.calls.append(rosters.map(\.id))
        }

        let ws1 = WorkspaceRosterStore.WorkspaceRoster(
            workspace: try Self.workspace(id: "ws-1", name: "Acme"),
            agents: [try Self.agent(address: "0xaa", online: "true")]
        )
        let ws2 = WorkspaceRosterStore.WorkspaceRoster(
            workspace: try Self.workspace(id: "ws-2", name: "Beta"),
            agents: [try Self.agent(address: "0xbb", online: "false")]
        )

        store.apply(rosters: [ws1, ws2], verifiedWorkspaceIds: ["ws-1"])
        #expect(box.calls == [["ws-1"]])

        // Full refresh: every roster is verified.
        store.apply(rosters: [ws1, ws2])
        #expect(box.calls.count == 2)
        #expect(Set(box.calls[1]) == ["ws-1", "ws-2"])

        // Targeted `update` verifies just that one workspace.
        store.update(workspaceId: "ws-2", agents: [try Self.agent(address: "0xcc", online: "true")])
        #expect(box.calls.count == 3)
        #expect(box.calls[2] == ["ws-2"])

        // Nothing verified → nothing to seed from.
        store.apply(rosters: [ws1], verifiedWorkspaceIds: [])
        #expect(box.calls.count == 3)

        // No reconciler installed → no call.
        WorkspaceRosterStore.defaultPoolBillingReconciler = nil
        store.apply(rosters: [ws1, ws2])
        #expect(box.calls.count == 3)
    }

    // MARK: - Activation refresh budget

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var paths: [String] = []
        func record(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }
        func count(of path: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return paths.filter { $0 == path }.count
        }
    }

    /// A store over a stubbed Router that lists one workspace with one agent.
    /// The agent is offline so the refresh's auto-connect pass (through the
    /// shared connect service) has no candidate and never attempts a handshake.
    private func makeNetworkedStore() throws -> (WorkspaceRosterStore, CallLog, () -> Void) {
        let log = CallLog()
        RosterURLProtocol.handler = { request in
            let path = request.url?.path ?? "?"
            log.record(path)
            switch path {
            case "/workspaces":
                return (200, Data(#"{"data":[{"id":"ws-1","name":"Acme","role":"member","source":"subscription","active":true}]}"#.utf8))
            case "/workspaces/ws-1/agents":
                return (200, Data(#"{"data":[{"agent_address":"0xaa","display_name":"Research Agent","owner":{"account_id":"acct-1","wallet_address":"0xowner","display_name":"Alice"},"relay_url":"wss://relay.example","online":false,"last_seen":"2026-01-01T00:00:00Z","shared_at":"2026-01-01T00:00:00Z"}]}"#.utf8))
            default:
                return (404, Data(#"{"error":{"code":"NOT_FOUND","message":"nope"}}"#.utf8))
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RosterURLProtocol.self]
        let client = OsaurusRouterAPIClient(
            baseURL: try #require(URL(string: "https://router.test")),
            session: URLSession(configuration: config),
            authOverride: { request, _ in
                request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
            }
        )
        let previous = UserDefaults.standard.object(forKey: OsaurusRouter.enabledDefaultsKey)
        OsaurusRouter.setEnabled(true)
        let store = WorkspaceRosterStore(client: client, observeAppActivation: false)
        store.hasIdentity = { true }
        let restore: () -> Void = {
            if let previous {
                UserDefaults.standard.set(previous, forKey: OsaurusRouter.enabledDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: OsaurusRouter.enabledDefaultsKey)
            }
        }
        return (store, log, restore)
    }

    /// While the sync stream is verified, activation has nothing to add:
    /// no `GET /workspaces`, no per-workspace agents fetch.
    @Test func activationRefresh_isSkippedWhileSyncStreamVerified() async throws {
        let (store, log, restore) = try makeNetworkedStore()
        defer { restore() }
        store.isSyncVerified = { true }

        for _ in 0..<3 {
            await store.refresh(reason: .activation)
        }
        #expect(log.paths.isEmpty)
        #expect(store.rosters.isEmpty)

        // Other reasons still run (one list + one agents call).
        await store.refresh(reason: .manual)
        #expect(log.count(of: "/workspaces") == 1)
        #expect(log.count(of: "/workspaces/ws-1/agents") == 1)
        #expect(store.rosters.map(\.id) == ["ws-1"])
    }

    /// Without a verified stream, activation refreshes at most every 15 min.
    @Test func activationRefresh_withoutStream_isThrottledToFifteenMinutes() async throws {
        let (store, log, restore) = try makeNetworkedStore()
        defer { restore() }
        #expect(WorkspaceRosterStore.activationRefreshInterval == 15 * 60)
        store.isSyncVerified = { false }
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        store.now = { clock }

        await store.refresh(reason: .activation)
        #expect(log.count(of: "/workspaces") == 1)

        for _ in 0..<14 {
            clock = clock.addingTimeInterval(60)
            await store.refresh(reason: .activation)
        }
        #expect(log.count(of: "/workspaces") == 1)

        clock = clock.addingTimeInterval(61)
        await store.refresh(reason: .activation)
        #expect(log.count(of: "/workspaces") == 2)
    }

    /// Every fetched list is handed to the installed reconciler so the
    /// Settings surface never fetches its own copy on the same trigger.
    @Test func refresh_handsFetchedListToWorkspaceListReconciler() async throws {
        let (store, log, restore) = try makeNetworkedStore()
        defer { restore() }
        let previous = WorkspaceRosterStore.workspaceListReconciler
        defer { WorkspaceRosterStore.workspaceListReconciler = previous }

        final class Box: @unchecked Sendable { var lists: [[String]] = [] }
        let box = Box()
        WorkspaceRosterStore.workspaceListReconciler = { box.lists.append($0.map(\.id)) }

        await store.refresh(reason: .launch)
        #expect(box.lists == [["ws-1"]])
        #expect(log.count(of: "/workspaces") == 1)

        WorkspaceRosterStore.workspaceListReconciler = nil
        await store.refresh(reason: .manual)
        #expect(box.lists.count == 1)
    }

    @Test func refresh_withoutIdentityOrRouter_makesNoRequest() async throws {
        let (store, log, restore) = try makeNetworkedStore()
        defer { restore() }

        store.hasIdentity = { false }
        await store.refresh(reason: .launch)
        #expect(log.paths.isEmpty)

        store.hasIdentity = { true }
        OsaurusRouter.setEnabled(false)
        await store.refresh(reason: .manual)
        #expect(log.paths.isEmpty)
    }
}

private final class RosterURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Sync stream policy

@Suite("Workspace sync stream policy", .serialized)
@MainActor
struct WorkspaceSyncServicePolicyTests {
    typealias Decision = WorkspaceSyncService.StreamDecision

    @Test func stream_runsOnlyForKnownMembership() {
        #expect(
            WorkspaceSyncService.streamDecision(
                wanted: true, routerEnabled: true, hasKnownMembership: true, alreadyProbed: false, hasIdentity: true
            ) == .stream)
        #expect(
            WorkspaceSyncService.streamDecision(
                wanted: true, routerEnabled: true, hasKnownMembership: true, alreadyProbed: true, hasIdentity: true
            ) == .stream)
    }

    @Test func zeroWorkspaces_probesOncePerLaunchThenStaysOff() {
        #expect(
            WorkspaceSyncService.streamDecision(
                wanted: true, routerEnabled: true, hasKnownMembership: false, alreadyProbed: false, hasIdentity: true
            ) == .probe)
        #expect(
            WorkspaceSyncService.streamDecision(
                wanted: true, routerEnabled: true, hasKnownMembership: false, alreadyProbed: true, hasIdentity: true
            ) == .stop)
        // No identity: nothing to sign the probe with.
        #expect(
            WorkspaceSyncService.streamDecision(
                wanted: true, routerEnabled: true, hasKnownMembership: false, alreadyProbed: false, hasIdentity: false
            ) == .stop)
    }

    @Test func notWantedOrRouterOff_stopsRegardlessOfMembership() {
        #expect(
            WorkspaceSyncService.streamDecision(
                wanted: false, routerEnabled: true, hasKnownMembership: true, alreadyProbed: false, hasIdentity: true
            ) == .stop)
        #expect(
            WorkspaceSyncService.streamDecision(
                wanted: true, routerEnabled: false, hasKnownMembership: true, alreadyProbed: false, hasIdentity: true
            ) == .stop)
    }

    @Test func membershipFlag_persistsAcrossInstances() {
        let suite = "sync-membership-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = WorkspaceSyncService(defaults: defaults)
        #expect(!service.hasKnownMembership)
        service.noteMembership(hasWorkspaces: true)
        #expect(service.hasKnownMembership)
        #expect(defaults.bool(forKey: WorkspaceSyncService.membershipDefaultsKey))

        // A relaunch reads the flag back without a probe.
        #expect(WorkspaceSyncService(defaults: defaults).hasKnownMembership)

        service.noteMembership(hasWorkspaces: false)
        #expect(!WorkspaceSyncService(defaults: defaults).hasKnownMembership)
        #expect(!service.isStreaming)
    }

    @Test func fallbackDelay_doublesFromTenSecondsToFiveMinutes() {
        #expect(WorkspaceSyncService.fallbackInitialDelay == 10)
        #expect(WorkspaceSyncService.fallbackMaxDelay == 300)
        var delay = WorkspaceSyncService.fallbackInitialDelay
        var schedule: [TimeInterval] = []
        for _ in 0..<7 {
            delay = WorkspaceSyncService.nextFallbackDelay(after: delay)
            schedule.append(delay)
        }
        #expect(schedule == [20, 40, 80, 160, 300, 300, 300])
        // A reset (any frame) restarts from the floor; sub-floor input clamps up.
        #expect(WorkspaceSyncService.nextFallbackDelay(after: 0) == 10)
        #expect(WorkspaceSyncService.nextFallbackDelay(after: 3) == 10)
    }
}
