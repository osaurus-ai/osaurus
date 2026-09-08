//
//  OsaurusRelayPresenceSignalTests.swift
//  osaurusTests
//
//  The relay answers `502 {"error":"agent_offline"}` when a shared agent's
//  host has no tunnel; any response that reached the host means it is up.
//  Those verdicts must flip `WorkspaceRosterStore` presence immediately (the
//  router poll can lag by the relay's 120 s claim TTL), and must never be
//  confused with a host-side `{"error":{…}}` envelope or a non-relay URL.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OsaurusRelayPresenceSignalTests {

    private static let address = "0x" + String(repeating: "ab", count: 20)
    private static let relayURL = URL(string: "https://\(address).agent.osaurus.ai/v1/chat/completions")!
    private static let offlineBody = Data(#"{"error":"agent_offline"}"#.utf8)

    @Test func agentAddress_onlyForRelayAgentSubdomains() {
        #expect(OsaurusRelayPresenceSignal.agentAddress(fromRelayURL: Self.relayURL) == Self.address)
        #expect(
            OsaurusRelayPresenceSignal.agentAddress(
                fromRelayURL: URL(string: "https://\(Self.address.uppercased()).agent.osaurus.ai/x")!
            )
                == Self.address,
            "address is normalised to lowercase"
        )
        #expect(
            OsaurusRelayPresenceSignal.agentAddress(fromRelayURL: URL(string: "https://router.osaurus.ai/v1")!) == nil
        )
        #expect(
            OsaurusRelayPresenceSignal.agentAddress(fromRelayURL: URL(string: "https://agent.osaurus.ai/health")!)
                == nil
        )
        #expect(
            OsaurusRelayPresenceSignal.agentAddress(
                fromRelayURL: URL(string: "https://notanaddress.agent.osaurus.ai/")!
            )
                == nil
        )
        #expect(OsaurusRelayPresenceSignal.agentAddress(fromRelayURL: nil) == nil)
    }

    @Test func unreachable_isOnlyTheRelaysOwnVerdict() {
        #expect(OsaurusRelayPresenceSignal.indicatesHostUnreachable(statusCode: 502, body: Self.offlineBody))
        #expect(
            OsaurusRelayPresenceSignal.indicatesHostUnreachable(
                statusCode: 502,
                body: Data(#"{"error":"tunnel_send_failed"}"#.utf8)
            )
        )
        #expect(
            OsaurusRelayPresenceSignal.indicatesHostUnreachable(
                statusCode: 504,
                body: Data(#"{"error":"gateway_timeout"}"#.utf8)
            )
        )
        // A host-side error envelope (object-valued `error`) is the host
        // talking — it is online, whatever the status.
        #expect(
            !OsaurusRelayPresenceSignal.indicatesHostUnreachable(
                statusCode: 502,
                body: Data(#"{"error":{"message":"upstream","code":"BAD"}}"#.utf8)
            )
        )
        // Other relay tokens (rate limit, body too large) are not presence.
        #expect(
            !OsaurusRelayPresenceSignal.indicatesHostUnreachable(
                statusCode: 429,
                body: Data(#"{"error":"rate_limited"}"#.utf8)
            )
        )
        #expect(!OsaurusRelayPresenceSignal.indicatesHostUnreachable(statusCode: 502, body: nil))
        #expect(OsaurusRelayPresenceSignal.unreachableMessage(statusCode: 502, body: Self.offlineBody) != nil)
        #expect(OsaurusRelayPresenceSignal.unreachableMessage(statusCode: 200, body: nil) == nil)
    }

    /// Asserts on the force-offline mark rather than derived presence: the
    /// shared store's rosters are also driven by other suites running in
    /// parallel, but only relay verdicts (and `resetForTesting`) touch the
    /// mark for this synthetic address.
    @Test @MainActor func observe_flipsRosterPresenceBothWays() async throws {
        let store = WorkspaceRosterStore.shared
        store.noteHostReachable(agentAddress: Self.address)
        #expect(store.forcedOffline[Self.address] == nil)

        // Relay says no tunnel → offline now, no poll needed.
        OsaurusRelayPresenceSignal.observe(url: Self.relayURL, statusCode: 502, body: Self.offlineBody)
        for _ in 0 ..< 50 where store.forcedOffline[Self.address] == nil { await Task.yield() }
        #expect(store.forcedOffline[Self.address] != nil)

        // A 4xx from the host still means the tunnel is up → mark cleared.
        OsaurusRelayPresenceSignal.observe(
            url: Self.relayURL,
            statusCode: 401,
            body: Data(#"{"error":{"message":"bad key"}}"#.utf8)
        )
        for _ in 0 ..< 50 where store.forcedOffline[Self.address] != nil { await Task.yield() }
        #expect(store.forcedOffline[Self.address] == nil)

        // Non-relay URLs never touch presence.
        OsaurusRelayPresenceSignal.observe(
            url: URL(string: "https://router.osaurus.ai/v1/chat/completions")!,
            statusCode: 502,
            body: Self.offlineBody
        )
        for _ in 0 ..< 10 { await Task.yield() }
        #expect(store.forcedOffline[Self.address] == nil)
    }
}
