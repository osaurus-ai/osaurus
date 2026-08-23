//
//  AgentChannelPluginToolPreloadTests.swift
//  OsaurusCoreTests
//
//  Channel dispatches start each message with an empty loaded-tools set, so
//  the inbound relay pre-loads the agent's granted plugin tools into the
//  dispatched session (#2443). These tests cover the grant intersection.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("AgentChannel plugin tool preload")
struct AgentChannelPluginToolPreloadTests {
    @Test("nil grant means every registered plugin tool preloads")
    func nilGrantPreloadsAllRegistered() {
        let names = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: ["get_events", "list_calendars", "create_event"],
            granted: nil
        )
        #expect(names == ["create_event", "get_events", "list_calendars"])
    }

    @Test("manual grant narrows the preload to the intersection")
    func grantIntersectsRegistered() {
        let names = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: ["get_events", "list_calendars", "create_event"],
            granted: ["get_events", "web_search", "todo"]
        )
        #expect(names == ["get_events"])
    }

    @Test("grant naming no registered plugin tool preloads nothing")
    func disjointGrantPreloadsNothing() {
        let names = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: ["get_events"],
            granted: ["web_search"]
        )
        #expect(names.isEmpty)
    }

    @Test("no registered plugin tools preloads nothing regardless of grant")
    func emptyRegistryPreloadsNothing() {
        #expect(
            AgentChannelInboundRelay.preloadedPluginToolNames(registered: [], granted: nil).isEmpty
        )
    }

    @Test("output is sorted for stable accumulation across reattached dispatches")
    func outputIsSorted() {
        let names = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: ["zeta_tool", "alpha_tool", "mid_tool"],
            granted: nil
        )
        #expect(names == ["alpha_tool", "mid_tool", "zeta_tool"])
    }
}
