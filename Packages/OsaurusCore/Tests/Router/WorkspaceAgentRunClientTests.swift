//
//  WorkspaceAgentRunClientTests.swift
//  osaurusTests
//
//  `WorkspaceAgentRunClient.prepare`: the headless preflight every trigger
//  (spawn, schedule, watcher, channel) runs before a shared workspace agent
//  is admitted. Exercised through its seams so no relay, keychain or
//  provider connection is involved.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkspaceAgentRunClientTests {

    private static let address = "0xaaaa0000000000000000000000000000000000c1"
    private static let ref = WorkspaceAgentRef(workspaceId: "ws-run", agentAddress: address)

    /// Call counters; every seam runs on the main actor (the client is
    /// `@MainActor`) so plain fields are safe, but the probe closure is
    /// `@Sendable` and needs a Sendable capture.
    private final class Trace: @unchecked Sendable {
        var pairs = 0
        var probes = 0
        var connects = 0
    }

    private static func remote(providerId: UUID, model: String? = nil) -> RemoteAgent {
        RemoteAgent(
            agentAddress: address,
            name: "Research",
            description: "",
            relayBaseURL: "https://\(address).agent.osaurus.ai",
            providerId: providerId,
            model: model,
            workspaceId: "ws-run"
        )
    }

    private static func provider(id: UUID) -> RemoteProvider {
        RemoteProvider(
            id: id,
            name: "Research (workspace)",
            host: "\(address).agent.osaurus.ai",
            providerProtocol: .https,
            port: nil,
            basePath: "",
            authType: .none,
            providerType: .osaurus,
            remoteAgentAddress: address
        )
    }

    /// A client whose every external touch is stubbed to the happy path;
    /// tests override the one seam under test.
    private static func makeClient(
        trace: Trace,
        paired: RemoteAgent? = nil,
        verdicts: [WorkspaceAgentLiveness.Verdict] = [.live(nil)],
        connected: Bool = true
    ) -> WorkspaceAgentRunClient {
        let providerId = paired?.providerId ?? UUID()
        let providerRecord = provider(id: providerId)
        let client = WorkspaceAgentRunClient()
        client.routerEnabled = { true }
        client.identityExists = { true }
        client.isOwnAgent = { _ in false }
        client.rosterKnows = { _ in true }
        client.lastSeen = { _ in nil }
        client.pairedAgent = { _ in paired }
        client.pair = { _, _ in
            trace.pairs += 1
            return Self.remote(providerId: providerId)
        }
        client.pairFailure = { _ in nil }
        client.provider = { id in id == providerId ? providerRecord : nil }
        client.isProviderConnected = { _ in connected }
        client.connectProvider = { _ in trace.connects += 1 }
        let queue = CallRecorderBox(verdicts)
        client.probe = { _ in
            let next = queue.withLock { list -> WorkspaceAgentLiveness.Verdict in
                list.isEmpty ? .failed("no more scripted verdicts") : list.removeFirst()
            }
            trace.probes += 1
            return next
        }
        return client
    }

    private static func prepareError(_ client: WorkspaceAgentRunClient) async -> WorkspaceAgentRunError? {
        do {
            _ = try await client.prepare(ref)
            return nil
        } catch let error as WorkspaceAgentRunError {
            return error
        } catch {
            Issue.record("unexpected error type \(error)")
            return nil
        }
    }

    // MARK: - Preflight refusals (no network at all)

    @Test func prepare_refusesBeforeAnyProbeWhenPreconditionsFail() async {
        let trace = Trace()

        let routerOff = Self.makeClient(trace: trace)
        routerOff.routerEnabled = { false }
        #expect(await Self.prepareError(routerOff) == .routerDisabled)

        let noIdentity = Self.makeClient(trace: trace)
        noIdentity.identityExists = { false }
        #expect(await Self.prepareError(noIdentity) == .noIdentity)

        let own = Self.makeClient(trace: trace)
        own.isOwnAgent = { _ in true }
        #expect(await Self.prepareError(own) == .ownAgent)

        // Not paired AND not on any roster: unshared / left the workspace.
        let unshared = Self.makeClient(trace: trace)
        unshared.rosterKnows = { _ in false }
        #expect(await Self.prepareError(unshared) == .notShared)

        #expect(trace.probes == 0)
        #expect(trace.pairs == 0)
        #expect(trace.connects == 0)
    }

    // MARK: - Pair if missing

    @Test func prepare_pairsWhenNoPairingExistsThenProbesAndConnects() async throws {
        let trace = Trace()
        let client = Self.makeClient(trace: trace, paired: nil, connected: false)
        let prepared = try await client.prepare(Self.ref)
        #expect(trace.pairs == 1)
        #expect(trace.probes == 1)
        #expect(trace.connects == 1)
        #expect(prepared.ref == Self.ref)
        #expect(prepared.displayName == "Research")
    }

    @Test func prepare_pairingFailureIsTyped() async {
        let trace = Trace()
        let client = Self.makeClient(trace: trace, paired: nil)
        client.pair = { _, _ in
            trace.pairs += 1
            return nil
        }
        client.pairFailure = { _ in "attestation expired" }
        #expect(await Self.prepareError(client) == .pairingFailed("attestation expired"))
        #expect(trace.probes == 0, "no probe without a pairing")
    }

    // MARK: - Liveness verdicts

    @Test func prepare_existingPairingSkipsHandshakeAndPinsHostModel() async throws {
        let trace = Trace()
        let paired = Self.remote(providerId: UUID(), model: "old")
        let client = Self.makeClient(
            trace: trace,
            paired: paired,
            verdicts: [
                .live(
                    RemoteProviderService.RemoteAgentMetadata(
                        effectiveModel: "mlx/qwen3", name: nil, description: nil, avatar: nil, quickActions: nil
                    )
                )
            ]
        )
        let prepared = try await client.prepare(Self.ref)
        #expect(trace.pairs == 0)
        #expect(trace.connects == 0, "already connected")
        #expect(prepared.providerId == paired.providerId)
        #expect(prepared.effectiveModel == "mlx/qwen3", "the host's reported model wins for attribution")
    }

    @Test func prepare_offlineVerdictBecomesTypedErrorWithLastSeenAndNoConnect() async {
        let trace = Trace()
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let client = Self.makeClient(trace: trace, paired: Self.remote(providerId: UUID()), verdicts: [.offline], connected: false)
        client.lastSeen = { _ in seen }
        let error = await Self.prepareError(client)
        #expect(error == .offline(lastSeen: seen))
        #expect(trace.connects == 0, "an offline host must not churn provider state")
        #expect(trace.pairs == 0)
        let copy = error?.message(agentName: "Research", now: seen.addingTimeInterval(120)) ?? ""
        #expect(copy.contains("offline"))
        #expect(copy.contains("2 min ago"))
    }

    @Test func prepare_unreachableNotFoundAndFailedMapToTypedErrors() async {
        let trace = Trace()
        for (verdict, expected) in [
            (WorkspaceAgentLiveness.Verdict.unreachable("dns"), WorkspaceAgentRunError.hostUnreachable("dns")),
            (.notFound, .agentMissing),
            (.failed("HTTP 500"), .other("HTTP 500")),
        ] {
            let client = Self.makeClient(trace: trace, paired: Self.remote(providerId: UUID()), verdicts: [verdict])
            #expect(await Self.prepareError(client) == expected, "\(verdict)")
        }
        #expect(trace.connects == 0)
    }

    /// A stale attestation gets exactly one repair: re-pair, re-probe. A
    /// second refusal is final and no further handshake is attempted.
    @Test func prepare_rejectedVerdictRepairsPairingOnceThenReprobes() async throws {
        let trace = Trace()
        let providerId = UUID()
        let recovered = Self.makeClient(
            trace: trace, paired: Self.remote(providerId: providerId), verdicts: [.rejected, .live(nil)]
        )
        let prepared = try await recovered.prepare(Self.ref)
        #expect(trace.pairs == 1, "one repair handshake")
        #expect(trace.probes == 2, "probe, repair, re-probe")
        #expect(prepared.providerId == providerId)

        let again = Trace()
        let stillRejected = Self.makeClient(
            trace: again, paired: Self.remote(providerId: providerId), verdicts: [.rejected, .rejected]
        )
        #expect(await Self.prepareError(stillRejected) == .rejected)
        #expect(again.pairs == 1, "never more than one repair")
        #expect(again.probes == 2)
        #expect(again.connects == 0)
    }

    @Test func prepare_connectFailureAfterLiveVerdictIsTyped() async {
        let trace = Trace()
        struct Boom: Error {}
        let client = Self.makeClient(trace: trace, paired: Self.remote(providerId: UUID()), connected: false)
        client.connectProvider = { _ in throw Boom() }
        let error = await Self.prepareError(client)
        guard case .connectFailed = error else {
            Issue.record("expected connectFailed, got \(String(describing: error))")
            return
        }
        #expect(trace.probes == 1)
    }

    // MARK: - Copy / audit tokens

    @Test func errors_haveStableAuditReasonsAndNameTheAgent() {
        let cases: [WorkspaceAgentRunError] = [
            .routerDisabled, .noIdentity, .notShared, .ownAgent, .offline(lastSeen: nil),
            .hostUnreachable("x"), .pairingFailed("x"), .connectFailed("x"), .rejected, .agentMissing, .other("x"),
        ]
        var reasons = Set<String>()
        for error in cases {
            #expect(reasons.insert(error.auditReason).inserted, "duplicate audit reason \(error.auditReason)")
            #expect(error.message(agentName: "Research").contains("Research"), "\(error)")
        }
        #expect(WorkspaceAgentRunClient.message(for: URLError(.timedOut), agentName: "Research").contains("Research"))
    }
}
