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

    @Test("preload above the cap truncates to a deterministic sorted prefix")
    func overCapTruncatesDeterministically() {
        let cap = AgentChannelInboundRelay.maxPreloadedPluginTools
        // 0...cap is cap+1 names; zero-padded so lexical order is numeric.
        let registered = Set((0...cap).map { String(format: "tool_%03d", $0) })
        let names = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: registered, granted: nil)
        #expect(names.count == cap)
        #expect(names == registered.sorted().prefix(cap).map { $0 })
        // Same inputs → same truncation, so reattached dispatches append a
        // stable set even while over the cap.
        let again = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: registered, granted: nil)
        #expect(names == again)
        #expect(
            AgentChannelInboundRelay.preloadOverflowCount(registered: registered, granted: nil) == 1
        )
    }

    @Test("preload at the cap still loads")
    func atCapPreloads() {
        let registered = Set((1...AgentChannelInboundRelay.maxPreloadedPluginTools).map { "tool_\($0)" })
        let names = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: registered,
            granted: nil
        )
        #expect(names.count == AgentChannelInboundRelay.maxPreloadedPluginTools)
        #expect(
            AgentChannelInboundRelay.preloadOverflowCount(registered: registered, granted: nil) == 0
        )
    }

    @Test("a narrowing grant can bring an over-cap registry back under the cap")
    func grantNarrowsBelowCap() {
        let registered = Set((0...100).map { "tool_\($0)" })
        let names = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: registered,
            granted: ["tool_5"]
        )
        #expect(names == ["tool_5"])
        #expect(
            AgentChannelInboundRelay.preloadOverflowCount(
                registered: registered, granted: ["tool_5"]) == 0
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
