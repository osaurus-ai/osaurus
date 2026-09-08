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

private final class DelayedWorkspaceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var gate: DelayedWorkspaceGate?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            let data = await Self.gate!.response(for: request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

extension WorkspaceCollaborationRegressionTests {
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
    @Test func subscriptionRenewalRetainsOnlyTheLastVerifiedLease() {
        let lastFrame = Date(timeIntervalSince1970: 1_000)
        #expect(WorkspaceSyncService.verificationIsFresh(lastFrameAt: lastFrame, now: lastFrame.addingTimeInterval(1)))
        #expect(!WorkspaceSyncService.verificationIsFresh(lastFrameAt: lastFrame, now: lastFrame.addingTimeInterval(3)))
        #expect(!WorkspaceSyncService.verificationIsFresh(lastFrameAt: .distantPast, now: lastFrame))
    }
}
