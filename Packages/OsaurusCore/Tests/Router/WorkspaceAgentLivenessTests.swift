//
//  WorkspaceAgentLivenessTests.swift
//  osaurusTests
//
//  On-the-wire liveness for a shared workspace agent: the verdict matrix
//  from relay / host / transport answers, the probe budget, and the roster
//  presence side effects. None of this may ever reach the composed prompt;
//  see `PromptSurfaceMatrixTests` for that invariant.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct WorkspaceAgentLivenessTests {

    private static let address = "0xaaaa0000000000000000000000000000000000a1"

    private static func provider(address: String? = address) -> RemoteProvider {
        RemoteProvider(
            name: "Research (workspace)",
            host: "\(address ?? "x").agent.osaurus.ai",
            providerProtocol: .https,
            port: nil,
            basePath: "",
            authType: .none,
            providerType: .osaurus,
            remoteAgentAddress: address
        )
    }

    private static func relayBody(_ error: String) -> Data {
        Data(#"{"error":"\#(error)"}"#.utf8)
    }

    // MARK: - Classification

    @Test func classify_relayVerdicts() {
        #expect(WorkspaceAgentLiveness.classify(.relay(status: 502, body: Self.relayBody("agent_offline"))) == .offline)
        #expect(WorkspaceAgentLiveness.classify(.relay(status: 502, body: Self.relayBody("tunnel_send_failed"))) == .offline)
        #expect(WorkspaceAgentLiveness.classify(.relay(status: 504, body: Self.relayBody("gateway_timeout"))) == .offline)
        #expect(WorkspaceAgentLiveness.classify(.relay(status: 401, body: Data())) == .rejected)
        #expect(WorkspaceAgentLiveness.classify(.relay(status: 403, body: Data())) == .rejected)
        #expect(WorkspaceAgentLiveness.classify(.relay(status: 404, body: Data())) == .notFound)
        // A 502 without a relay token is NOT offline — something else broke.
        #expect(WorkspaceAgentLiveness.classify(.relay(status: 502, body: Data("<html>".utf8))) == .failed("relay: HTTP 502"))
        #expect(
            WorkspaceAgentLiveness.classify(.relay(status: 503, body: Self.relayBody("relay_busy")))
                == .failed("relay: relay_busy")
        )
    }

    @Test func classify_hostVerdicts() {
        let metadata = Data(#"{"id":"1","name":"Research","effective_model":"mlx/qwen"}"#.utf8)
        let live = WorkspaceAgentLiveness.classify(.host(status: 200, body: metadata))
        guard case .live(let meta) = live else {
            Issue.record("expected live, got \(live)")
            return
        }
        #expect(meta?.name == "Research")
        #expect(meta?.effectiveModel == "mlx/qwen")
        #expect(live.isLive)
        #expect(WorkspaceAgentLiveness.classify(.host(status: 204, body: Data())).isLive)
        #expect(WorkspaceAgentLiveness.classify(.host(status: 401, body: Data())) == .rejected)
        #expect(WorkspaceAgentLiveness.classify(.host(status: 403, body: Data())) == .rejected)
        #expect(WorkspaceAgentLiveness.classify(.host(status: 404, body: Data())) == .notFound)
        #expect(
            WorkspaceAgentLiveness.classify(.host(status: 500, body: Data("boom".utf8))) == .failed("HTTP 500: boom")
        )
    }

    @Test func classify_transportAndHandshakeAnswers() {
        #expect(WorkspaceAgentLiveness.classify(.transport("timed out")) == .unreachable("timed out"))
        // The Secure Channel handshake surfaces the relay's answer inside its
        // message; an `agent_offline` there still reads as offline.
        #expect(
            WorkspaceAgentLiveness.classify(.secureChannel(#"HTTP 502: {"error":"agent_offline"}"#)) == .offline
        )
        #expect(WorkspaceAgentLiveness.classify(.secureChannel("HTTP 401: {\"error\":\"unauthorized\"}")) == .rejected)
        #expect(
            WorkspaceAgentLiveness.classify(.secureChannel("peer predates secure channel"))
                == .failed("secure channel: peer predates secure channel")
        )
    }

    @Test func parseHandshakeHTTPFailure_recoversStatusAndBody() {
        let parsed = WorkspaceAgentLiveness.parseHandshakeHTTPFailure(#"handshakeFailed HTTP 502: {"error":"agent_offline"}"#)
        #expect(parsed?.status == 502)
        #expect(parsed.map { OsaurusRelayPresenceSignal.relayError(in: $0.body) } == "agent_offline")
        #expect(WorkspaceAgentLiveness.parseHandshakeHTTPFailure("no status here") == nil)
        #expect(WorkspaceAgentLiveness.parseHandshakeHTTPFailure("HTTP abc: x") == nil)
    }

    // MARK: - Copy

    @Test func message_offlineIncludesLastSeenAge() {
        let now = Date(timeIntervalSince1970: 10_000)
        let twelveMinutesAgo = now.addingTimeInterval(-12 * 60)
        let text = WorkspaceAgentLiveness.message(for: .offline, agentName: "Research", lastSeen: twelveMinutesAgo, now: now)
        #expect(text.contains("Research"))
        #expect(text.contains("12 min ago"))
        #expect(
            WorkspaceAgentLiveness.message(for: .offline, agentName: "Research", lastSeen: nil, now: now)
                .contains("offline")
        )
        #expect(WorkspaceAgentLiveness.relativeAge(from: now.addingTimeInterval(-30), to: now) == "moments ago")
        #expect(WorkspaceAgentLiveness.relativeAge(from: now.addingTimeInterval(-3600), to: now) == "1 hour ago")
        #expect(WorkspaceAgentLiveness.relativeAge(from: now.addingTimeInterval(-2 * 86_400), to: now) == "2 days ago")
    }

    // MARK: - Probe

    private final class RecordingTransport: WorkspaceAgentLivenessTransport, @unchecked Sendable {
        let response: WorkspaceAgentLivenessResponse
        let delay: Duration
        let calls = CallRecorderBox<[String]>([])

        init(_ response: WorkspaceAgentLivenessResponse, delay: Duration = .zero) {
            self.response = response
            self.delay = delay
        }

        func get(path: String, provider: RemoteProvider, timeout: TimeInterval) async -> WorkspaceAgentLivenessResponse {
            calls.withLock { $0.append(path) }
            if delay > .zero { try? await Task.sleep(for: delay) }
            return response
        }
    }

    @Test func probe_asksRelayForTheAgentAndFeedsPresence() async throws {
        let transport = RecordingTransport(.host(status: 200, body: Data("{}".utf8)))
        WorkspaceAgentLiveness.transportOverride = transport
        defer { WorkspaceAgentLiveness.transportOverride = nil }

        try await WorkspaceRosterTestLock.shared.run {
            let verdict = await WorkspaceAgentLiveness.probe(provider: Self.provider(), budget: 2)
            #expect(verdict.isLive)
            #expect(transport.calls.withLock { $0 } == ["/agents/\(Self.address)"])
            #expect(
                WorkspaceRosterStore.shared.hostReachableAt[Self.address] != nil,
                "a host answer must mark the tunnel reachable"
            )

            WorkspaceAgentLiveness.transportOverride = RecordingTransport(
                .relay(status: 502, body: Self.relayBody("agent_offline"))
            )
            let offline = await WorkspaceAgentLiveness.probe(provider: Self.provider(), budget: 2)
            #expect(offline == .offline)
            #expect(
                WorkspaceRosterStore.shared.forcedOffline[Self.address] != nil,
                "a relay offline verdict must force the agent offline in the roster"
            )
        }
    }

    @Test func probe_withoutAgentAddressFailsWithoutTouchingTransport() async {
        let transport = RecordingTransport(.host(status: 200, body: Data()))
        WorkspaceAgentLiveness.transportOverride = transport
        defer { WorkspaceAgentLiveness.transportOverride = nil }
        let verdict = await WorkspaceAgentLiveness.probe(provider: Self.provider(address: nil), budget: 1)
        #expect(verdict == .failed("provider has no agent address"))
        #expect(transport.calls.withLock { $0.isEmpty })
    }

    @Test func probe_budgetMissReadsAsUnreachable() async {
        WorkspaceAgentLiveness.transportOverride = RecordingTransport(
            .host(status: 200, body: Data()), delay: .seconds(5)
        )
        defer { WorkspaceAgentLiveness.transportOverride = nil }
        let started = Date()
        let verdict = await WorkspaceAgentLiveness.probe(provider: Self.provider(), budget: 0.2)
        #expect(verdict == .unreachable("timed out after 0 s"))
        #expect(Date().timeIntervalSince(started) < 3, "the probe must give up at the budget, not the transport")
    }

    /// A `spawn_batch` fanning out to the same agent probes the relay once.
    @Test func coalescer_sharesOneInFlightProbePerAgent() async {
        let transport = RecordingTransport(.host(status: 200, body: Data()), delay: .milliseconds(150))
        WorkspaceAgentLiveness.transportOverride = transport
        defer { WorkspaceAgentLiveness.transportOverride = nil }
        let coalescer = WorkspaceAgentLivenessCoalescer()
        let provider = Self.provider()
        let verdicts = await withTaskGroup(of: WorkspaceAgentLiveness.Verdict.self) { group in
            for _ in 0..<4 {
                group.addTask { await coalescer.probe(provider: provider, budget: 2) }
            }
            var out: [WorkspaceAgentLiveness.Verdict] = []
            for await v in group { out.append(v) }
            return out
        }
        #expect(verdicts.count == 4)
        #expect(verdicts.allSatisfy { $0.isLive })
        #expect(transport.calls.withLock { $0.count } == 1)
    }
}

/// Minimal lock box so the fake transport can record calls from any actor.
final class CallRecorderBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
