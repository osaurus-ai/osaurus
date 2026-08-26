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

    @Test("insertion order of the registry set never changes the preload")
    func setInsertionOrderIndependence() {
        // Set iteration order is not guaranteed; the preload must not leak
        // it into the schema, or two launches could serialize different
        // tool orders and defeat cross-launch prefill reuse.
        var forward = Set<String>()
        var backward = Set<String>()
        let names = (0..<60).map { String(format: "tool_%03d", $0) }
        for n in names { forward.insert(n) }
        for n in names.reversed() { backward.insert(n) }
        #expect(
            AgentChannelInboundRelay.preloadedPluginToolNames(registered: forward, granted: nil)
                == AgentChannelInboundRelay.preloadedPluginToolNames(
                    registered: backward, granted: nil)
        )
    }

    @Test("successive dispatches into a reattached session leave the loaded set unchanged")
    func reattachedDispatchesAreIdempotent() async {
        // Models the dispatch sequence: preload names are appended into the
        // session store on every inbound message. With a stable config the
        // stored set — and therefore the composed tool schema — must be
        // identical after N dispatches, or every channel message would
        // re-prefill the whole session.
        let store = SessionToolStateStore()
        let preload = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: ["get_events", "create_event", "list_calendars"], granted: nil)
        await store.appendLoadedTools("s1", names: preload, fallbackAlwaysLoadedNames: nil)
        let afterFirst = await store.get("s1")?.loadedToolNames
        await store.appendLoadedTools("s1", names: preload, fallbackAlwaysLoadedNames: nil)
        await store.appendLoadedTools("s1", names: preload, fallbackAlwaysLoadedNames: nil)
        #expect(await store.get("s1")?.loadedToolNames == afterFirst)
    }

    @Test("a revocation between dispatches shrinks the set by exactly the revoked names")
    func revocationBetweenDispatches() async {
        // Dispatch 1 preloads under a wide grant; the operator narrows the
        // grant; dispatch 2 reconciles then re-appends its own (narrower)
        // preload. The stored set must be the original minus exactly the
        // revoked names — nothing else may churn.
        let registered: Set<String> = ["get_events", "create_event", "list_calendars"]
        let store = SessionToolStateStore()
        let wide = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: registered, granted: nil)
        await store.appendLoadedTools("s1", names: wide, fallbackAlwaysLoadedNames: nil)

        let narrowGrant = ["get_events"]
        let revoked = await store.retainLoadedTools(
            "s1", allowed: Set(narrowGrant), among: registered)
        let narrow = AgentChannelInboundRelay.preloadedPluginToolNames(
            registered: registered, granted: narrowGrant)
        await store.appendLoadedTools("s1", names: narrow, fallbackAlwaysLoadedNames: nil)

        #expect(revoked == ["create_event", "list_calendars"])
        #expect(await store.get("s1")?.loadedToolNames == ["get_events"])
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
