import Combine
import Foundation
import Testing
@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkspaceCollaborationRegressionTests {
    @Test func pairingAndTabsSeparateWorkspaceAndDirectShare() async throws {
        try await ChatHistoryTestStorage.run {
            let manager = RemoteAgentManager.shared
            let address = "0x00000000000000000000000000000000abcabcab"
            var pairings: [RemoteAgent] = []
            defer { for pairing in pairings { _ = manager.remove(id: pairing.id) } }
            let workspaceIds: [String?] = ["workspace-a", "workspace-b", nil]
            for id in workspaceIds {
                pairings.append(
                    manager.upsertPairedAgent(
                        agentAddress: address,
                        name: id ?? "Direct",
                        description: "",
                        relayBaseURL: "https://test.invalid",
                        apiKey: "test-key",
                        note: nil,
                        workspaceId: id
                    )
                )
            }
            #expect(Set(pairings.map(\.providerId)).count == 3)
            for pairing in pairings {
                #expect(manager.remoteAgent(forAddress: address, workspaceId: pairing.workspaceId)?.id == pairing.id)
            }
            let renewed = manager.upsertPairedAgent(
                agentAddress: address,
                name: "Renamed",
                description: "",
                relayBaseURL: "https://test.invalid",
                apiKey: "renewed",
                note: nil,
                workspaceId: "workspace-a"
            )
            #expect(renewed.providerId == pairings[0].providerId)
            #expect(manager.remoteAgent(forAddress: address, workspaceId: "workspace-b")?.id == pairings[1].id)
            let a = ChatSession()
            let b = ChatSession()
            a.workspaceContext = .init(workspaceId: "workspace-a", agentAddress: address)
            b.workspaceContext = .init(workspaceId: "workspace-b", agentAddress: address)
            #expect(ChatTabScope.of(a) != ChatTabScope.of(b))
        }
    }

    @Test func successfulHostResponseOverridesOldOfflineRosterButExpiredVerificationPauses() throws {
        let store = WorkspaceRosterStore(observeAppActivation: false)
        let summary = try JSONDecoder().decode(
            OsaurusRouterWorkspaceSummary.self,
            from: Data(#"{"id":"a","name":"A","role":"member"}"#.utf8)
        )
        let agent = try JSONDecoder().decode(
            OsaurusRouterWorkspaceAgent.self,
            from: Data(#"{"agent_address":"0xabc","online":false}"#.utf8)
        )
        let now = Date()
        store.now = { now }
        store.apply(rosters: [.init(workspace: summary, agents: [agent])])
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a").isOffline)
        store.noteHostReachable(agentAddress: "0xabc")
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .online)
        #expect(store.presence(forAddress: "0xabc", workspaceId: "b") == .unknown)
        store.renewVerification()
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a").isOffline)
        store.noteHostReachable(agentAddress: "0xabc")
        store.now = { now.addingTimeInterval(WorkspaceRosterStore.verificationLifetime + 1) }
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .unknown)
    }

    /// `/workspaces/sync` heartbeats every few seconds. A heartbeat that
    /// changes nothing visible (every roster still verified, no evidence to
    /// drop) must not publish, or every roster observer re-renders on each
    /// one. It still publishes when a workspace flips back to verified or
    /// when host-reachable evidence is superseded.
    @Test func heartbeatPublishesOnlyWhenVisibleStateChanges() throws {
        let store = WorkspaceRosterStore(observeAppActivation: false)
        let summary = try JSONDecoder().decode(
            OsaurusRouterWorkspaceSummary.self,
            from: Data(#"{"id":"a","name":"A","role":"member"}"#.utf8)
        )
        let agent = try JSONDecoder().decode(
            OsaurusRouterWorkspaceAgent.self,
            from: Data(#"{"agent_address":"0xabc","online":true}"#.utf8)
        )
        var now = Date()
        store.now = { now }
        store.apply(rosters: [.init(workspace: summary, agents: [agent])])

        var publishes = 0
        let subscription = store.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        // Steady state: repeated heartbeats within the lease are silent.
        store.renewVerification()
        now = now.addingTimeInterval(15)
        store.renewVerification()
        #expect(publishes == 0)
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .online)

        // Expired, then re-verified: one publish for the expiry, one for the flip back.
        now = now.addingTimeInterval(WorkspaceRosterStore.verificationLifetime + 1)
        store.expireVerification()
        #expect(publishes == 1)
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .unknown)
        store.renewVerification()
        #expect(publishes == 2)
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .online)

        // Host-reachable evidence superseded by the router's verdict: publishes once.
        store.noteHostReachable(agentAddress: "0xabc")
        let before = publishes
        store.renewVerification()
        #expect(publishes == before + 1)
        store.renewVerification()
        #expect(publishes == before + 1)
    }

    /// The router can list a shared agent with no presence verdict at all
    /// (`online: null`). Our own evidence that the host answered through
    /// the relay must then survive every snapshot and heartbeat, or the
    /// composer stays on "Checking access…" for a host that is reachable.
    @Test func nullRosterVerdictKeepsHostReachablePresence() throws {
        let store = WorkspaceRosterStore(observeAppActivation: false)
        let summary = try JSONDecoder().decode(
            OsaurusRouterWorkspaceSummary.self,
            from: Data(#"{"id":"a","name":"A","role":"member"}"#.utf8)
        )
        let undecided = try JSONDecoder().decode(
            OsaurusRouterWorkspaceAgent.self,
            from: Data(#"{"agent_address":"0xabc"}"#.utf8)
        )
        let now = Date()
        store.now = { now }
        store.apply(rosters: [.init(workspace: summary, agents: [undecided])])
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .unknown)

        store.noteHostReachable(agentAddress: "0xabc")
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .online)

        // Heartbeat and a fresh snapshot with the same null verdict.
        store.renewVerification()
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .online)
        store.apply(rosters: [.init(workspace: summary, agents: [undecided])])
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .online)

        // Idle for longer than the old evidence lifetime, still verified.
        store.now = { now.addingTimeInterval(WorkspaceRosterStore.verificationLifetime + 5) }
        store.renewVerification()
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a") == .online)

        // A real relay failure still wins.
        store.noteHostUnreachable(agentAddress: "0xabc")
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a").isOffline)

        // And a definite router verdict replaces our evidence.
        store.noteHostReachable(agentAddress: "0xabc")
        let offline = try JSONDecoder().decode(
            OsaurusRouterWorkspaceAgent.self,
            from: Data(#"{"agent_address":"0xabc","online":false}"#.utf8)
        )
        store.apply(rosters: [.init(workspace: summary, agents: [offline])])
        #expect(store.presence(forAddress: "0xabc", workspaceId: "a").isOffline)
    }
}

private actor DelayedWorkspaceGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func response(for request: URLRequest) async -> Data {
        let path = request.url!.path
        if path == "/workspaces/a" {
            await withCheckedContinuation { continuation in
                pending = continuation
                arrival?.resume()
                arrival = nil
            }
        }
        if path == "/workspaces/a" || path == "/workspaces/b" {
            return Data("{\"id\":\"\(path.hasSuffix("a") ? "a" : "b")\",\"name\":\"Team\",\"role\":\"member\"}".utf8)
        }
        return Data(#"{"data":[]}"#.utf8)
    }
    func waitForA() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func releaseA() { pending?.resume(); pending = nil }
}

// URLProtocol is explicitly non-Sendable in the macOS 26.4 SDK. Only this
// serialized delivery handle crosses into the asynchronous gate task, not
// the protocol instance. stopLoading invalidates delivery under the same lock.
private final class DelayedWorkspaceDelivery: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private weak var target: URLProtocol?

    init(_ target: URLProtocol) { self.target = target }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        target = nil
    }

    func deliver(_ data: Data, for request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        guard let target else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        target.client?.urlProtocol(target, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard self.target != nil else { return }
        target.client?.urlProtocol(target, didLoad: data)
        guard self.target != nil else { return }
        self.target = nil
        target.client?.urlProtocolDidFinishLoading(target)
    }
}

private final class DelayedWorkspaceProtocol: URLProtocol {
    nonisolated(unsafe) static var gate: DelayedWorkspaceGate?
    private let deliveryLock = NSLock()
    private var delivery: DelayedWorkspaceDelivery?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let gate = Self.gate!
        let delivery = DelayedWorkspaceDelivery(self)
        deliveryLock.lock()
        self.delivery = delivery
        deliveryLock.unlock()
        Task {
            let data = await gate.response(for: request)
            delivery.deliver(data, for: request)
        }
    }
    override func stopLoading() {
        deliveryLock.lock()
        let pending = delivery
        delivery = nil
        deliveryLock.unlock()
        pending?.cancel()
    }
}

extension WorkspaceCollaborationRegressionTests {
    @Test func cancelledWorkspaceRequestDoesNotCompleteAfterGateRelease() async throws {
        let gate = DelayedWorkspaceGate()
        DelayedWorkspaceProtocol.gate = gate
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedWorkspaceProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); DelayedWorkspaceProtocol.gate = nil }
        let request = Task {
            try await session.data(from: URL(string: "https://router.test/workspaces/a")!)
        }
        await gate.waitForA()
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Cancelled request unexpectedly completed")
        } catch {
            #expect((error as? URLError)?.code == .cancelled || error is CancellationError)
        }
        await gate.releaseA()
    }

    @Test func delayedPreviousWorkspaceCannotOverwriteCurrentSelection() async throws {
        let gate = DelayedWorkspaceGate()
        DelayedWorkspaceProtocol.gate = gate
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedWorkspaceProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); DelayedWorkspaceProtocol.gate = nil }
        let client = OsaurusRouterAPIClient(
            baseURL: URL(string: "https://router.test")!,
            session: session,
            authOverride: { _, _ in }
        )
        let suite = "workspace-selection-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = WorkspacesService(client: client, defaults: defaults)
        let previous = Task { await service.selectWorkspace(id: "a") }
        await gate.waitForA()
        await service.selectWorkspace(id: "b")
        #expect(service.detail?.id == "b")
        await gate.releaseA()
        await previous.value
        #expect(service.selectedWorkspaceId == "b")
        #expect(service.detail?.id == "b")
        #expect(!service.isLoadingDetail)
    }
}


extension WorkspaceCollaborationRegressionTests {
    @Test func automaticPairingBoundsConcurrencyWithoutSerializingHosts() async throws {
        let service = WorkspaceAgentConnectService.shared
        let previous = service.testHandshakeOverride
        defer { service.testHandshakeOverride = previous }
        var active = 0
        var maximum = 0
        var calls = 0
        service.testHandshakeOverride = { _, _ in
            active += 1
            calls += 1
            maximum = max(maximum, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(20))
            throw URLError(.cannotConnectToHost)
        }
        let agents = try (0..<7).map { index in
            try JSONDecoder().decode(
                OsaurusRouterWorkspaceAgent.self,
                from: Data("{\"agent_address\":\"parallel-test-\(index)\",\"online\":true}".utf8)
            )
        }
        await service.autoConnect(workspaceId: "parallel-test-\(UUID())", agents: agents)
        #expect(calls == 7)
        #expect(maximum == 4)
        #expect(active == 0)
    }
}


extension WorkspaceCollaborationRegressionTests {
    /// The router's steady-state `/workspaces/sync` tick is 15 s ± 20 %, so a
    /// healthy stream can legitimately go 18 s without a frame. The lease
    /// must outlive that (a 3 s lease tore down and reconnected a healthy
    /// stream every ~9 s, republishing every roster on each reconnect) and
    /// agree with the roster store's own verification lifetime.
    @Test func subscriptionRenewalRetainsOnlyTheLastVerifiedLease() {
        let lastFrame = Date(timeIntervalSince1970: 1_000)
        #expect(WorkspaceSyncService.verificationIsFresh(lastFrameAt: lastFrame, now: lastFrame.addingTimeInterval(1)))
        // One late steady-state tick (15 s + 20 % jitter) must not expire it.
        #expect(WorkspaceSyncService.verificationIsFresh(lastFrameAt: lastFrame, now: lastFrame.addingTimeInterval(18)))
        // Two consecutive missed ticks still do.
        #expect(
            !WorkspaceSyncService.verificationIsFresh(
                lastFrameAt: lastFrame,
                now: lastFrame.addingTimeInterval(WorkspaceSyncService.verificationLease)
            )
        )
        #expect(!WorkspaceSyncService.verificationIsFresh(lastFrameAt: .distantPast, now: lastFrame))
        #expect(WorkspaceSyncService.verificationLease >= 36)
        #expect(WorkspaceSyncService.verificationLease == WorkspaceRosterStore.verificationLifetime)

        // A connection that never delivers its first snapshot still falls
        // back to polling quickly; only a *verified* stream gets the long lease.
        let started = lastFrame
        #expect(WorkspaceSyncService.connectionIsPending(startedAt: started, now: started.addingTimeInterval(3)))
        #expect(
            !WorkspaceSyncService.connectionIsPending(
                startedAt: started, now: started.addingTimeInterval(WorkspaceSyncService.firstFrameDeadline)
            )
        )
        #expect(WorkspaceSyncService.firstFrameDeadline < WorkspaceSyncService.verificationLease)
    }
}

extension WorkspaceCollaborationRegressionTests {
    @Test(arguments: ["Reviews supplied research sources.", ""])
    func credentialRefreshUpdatesDescriptionWithoutRePairing(description: String) async throws {
        try await ChatHistoryTestStorage.run {
            let service = WorkspaceAgentConnectService(observeAppActivation: false)
            let manager = RemoteAgentManager.shared
            let address = "0x00000000000000000000000000000000abcabcde"
            let workspace = "description-refresh-\(UUID())"
            let siblingWorkspace = "description-sibling-\(UUID())"
            let sibling = manager.upsertPairedAgent(
                agentAddress: address, name: "Other workspace", description: "Unchanged sibling description.",
                relayBaseURL: "https://test.invalid", apiKey: "test-key", note: nil,
                workspaceId: siblingWorkspace
            )
            var calls = 0
            service.testHandshakeOverride = { incomingWorkspace, incomingAddress in
                #expect(incomingWorkspace == workspace)
                #expect(incomingAddress == address)
                calls += 1
                return .init(
                    agentAddress: address, agentName: "Host name",
                    agentDescription: calls == 1 ? "Old description." : description,
                    agentModel: "test-model", apiKey: "test-key-\(calls)",
                    attestationExpiresAt: calls == 1 ? Date().addingTimeInterval(0.2) : nil
                )
            }
            defer {
                service.stopRefreshing(agentAddress: address, workspaceId: workspace)
                if let agent = manager.remoteAgent(forAddress: address, workspaceId: workspace) {
                    _ = manager.remove(id: agent.id)
                }
                _ = manager.remove(id: sibling.id)
            }
            let paired = try #require(await service.connect(
                workspaceId: workspace, agentAddress: address, displayName: "Shared display name", silent: true
            ))
            let deadline = Date().addingTimeInterval(3)
            while calls < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(calls == 2)
            let refreshed = try #require(manager.remoteAgent(forAddress: address, workspaceId: workspace))
            #expect(refreshed.id == paired.id)
            #expect(refreshed.providerId == paired.providerId)
            #expect(refreshed.name == "Shared display name")
            #expect(refreshed.description == description)
            #expect(manager.remoteAgent(forAddress: address, workspaceId: siblingWorkspace)?.description == "Unchanged sibling description.")
        }
    }
}
