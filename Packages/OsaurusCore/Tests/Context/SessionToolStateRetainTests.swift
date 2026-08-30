//
//  SessionToolStateRetainTests.swift
//  OsaurusCoreTests
//
//  Coverage for `SessionToolStateStore.retainLoadedTools`: a grant narrowed
//  between dispatches must drop revoked plugin tools from a reattached
//  session's accumulated loaded set, without touching loaded tools outside
//  the plugin universe.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("SessionToolStateStore retainLoadedTools")
struct SessionToolStateRetainTests {
    @Test("revoked plugin tools are dropped, granted ones survive")
    func revocationDropsOnlyRevoked() async {
        let store = SessionToolStateStore()
        await store.appendLoadedTools(
            "s1", names: ["get_events", "create_event", "web_search"],
            fallbackAlwaysLoadedNames: nil)
        let revoked = await store.retainLoadedTools(
            "s1",
            allowed: ["get_events"],
            among: ["get_events", "create_event", "list_calendars"]
        )
        #expect(revoked == ["create_event"])
        let loaded = await store.get("s1")?.loadedToolNames
        // `web_search` is outside the plugin universe → untouched.
        #expect(loaded == ["get_events", "web_search"])
    }

    @Test("no change returns empty and leaves the entry intact")
    func noOpWhenNothingRevoked() async {
        let store = SessionToolStateStore()
        await store.appendLoadedTools(
            "s1", names: ["get_events"], fallbackAlwaysLoadedNames: nil)
        let revoked = await store.retainLoadedTools(
            "s1", allowed: ["get_events"], among: ["get_events"])
        #expect(revoked.isEmpty)
        #expect(await store.get("s1")?.loadedToolNames == ["get_events"])
    }

    @Test("unknown session is a no-op")
    func unknownSessionNoOp() async {
        let store = SessionToolStateStore()
        let revoked = await store.retainLoadedTools("missing", allowed: [], among: ["x"])
        #expect(revoked.isEmpty)
        #expect(await store.get("missing") == nil)
    }

    @Test("reconcile then re-append models the dispatch order")
    func reconcileBeforeAppendKeepsCurrentRequestPicks() async {
        // dispatchChat reconciles BEFORE appending the current request's
        // names, so a tool that is both previously-loaded and still granted
        // this dispatch always survives, and a stale revoked one does not.
        let store = SessionToolStateStore()
        await store.appendLoadedTools(
            "s1", names: ["get_events", "create_event"], fallbackAlwaysLoadedNames: nil)
        _ = await store.retainLoadedTools(
            "s1", allowed: ["get_events"], among: ["get_events", "create_event"])
        await store.appendLoadedTools("s1", names: ["get_events"], fallbackAlwaysLoadedNames: nil)
        #expect(await store.get("s1")?.loadedToolNames == ["get_events"])
    }
}
