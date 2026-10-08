//
//  AgentToolPatchTests.swift
//  OsaurusCoreTests
//
//  Parsing `PATCH /agents/{id}/tools/{name}` bodies from the Osaurus Connect
//  phone (docs/MOBILE_PROTOCOL.md §14.7).
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentToolPatchTests {
    private func patch(_ json: String) -> HTTPHandler.ToolPatch? {
        HTTPHandler.toolPatch(from: Data(json.utf8))
    }

    @Test func readsEitherFieldOnItsOwn() throws {
        let off = try #require(patch(#"{"enabled":false}"#))
        #expect(off.enabled == false)
        #expect(off.policy == nil)

        let ask = try #require(patch(#"{"policy":"ask"}"#))
        #expect(ask.enabled == nil)
        #expect(ask.policy == .ask)
    }

    @Test func readsBothTogether() throws {
        let both = try #require(patch(#"{"enabled":true,"policy":"deny"}"#))
        #expect(both.enabled == true)
        #expect(both.policy == .deny)
    }

    @Test func rejectsEmptyAndUnknownPolicies() {
        // Nothing to apply.
        #expect(patch(#"{}"#) == nil)
        #expect(patch(#"{"title":"nope"}"#) == nil)
        // Not one of auto / ask / deny.
        #expect(patch(#"{"policy":"maybe"}"#) == nil)
        #expect(patch(#"{"policy":"AUTO"}"#) == nil)
        // Not JSON at all.
        #expect(patch("enabled=false") == nil)
    }

    @Test func readsTheAgentSwitchAlongsideTheMacWideOnes() throws {
        let own = try #require(patch(#"{"agent_enabled":false}"#))
        #expect(own == HTTPHandler.ToolPatch(enabled: nil, policy: nil, agentEnabled: false))

        let all = try #require(patch(#"{"enabled":true,"policy":"auto","agent_enabled":true}"#))
        #expect(all == HTTPHandler.ToolPatch(enabled: true, policy: .auto, agentEnabled: true))
    }

    @Test func oneBadFieldRejectsTheWholeBody() {
        // A valid agent switch must not carry an invalid Mac-wide field through.
        #expect(patch(#"{"agent_enabled":true,"policy":"bogus"}"#) == nil)
        #expect(patch(#"{"agent_enabled":true,"enabled":"yes"}"#) == nil)
        #expect(patch(#"{"agent_enabled":"yes"}"#) == nil)
    }
}
