//
//  NewAgentHighlightStoreTests.swift
//  osaurusTests
//
//  The chat sidebar marks agents that appeared during this app run until
//  the user opens them once. The store is diff-based over the agent
//  sources; these tests pin the baseline / diff / seen rules on a detached
//  store so no live manager is involved.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct NewItemTrackerTests {
    @Test("the first observation is the baseline, later arrivals are new")
    func baselineThenDiff() {
        var tracker = NewItemTracker<String>()
        tracker.observe(["a", "b"])
        #expect(tracker.newKeys.isEmpty)

        tracker.observe(["a", "b", "c"])
        #expect(tracker.newKeys == ["c"])

        // Re-publishing the same list changes nothing.
        tracker.observe(["a", "b", "c"])
        #expect(tracker.newKeys == ["c"])
    }

    @Test("a removed item is no longer new, and is not new again if it comes back")
    func removalClearsNew() {
        var tracker = NewItemTracker<String>()
        tracker.observe(["a"])
        tracker.observe(["a", "b"])
        #expect(tracker.newKeys == ["b"])

        tracker.observe(["a"])
        #expect(tracker.newKeys.isEmpty)

        tracker.observe(["a", "b"])
        #expect(tracker.newKeys.isEmpty)
    }

    @Test("treatAllAsNew makes the first observation a change over an empty baseline")
    func treatAllAsNewOnFirstObservation() {
        var tracker = NewItemTracker<String>()
        tracker.observe(["x"], treatAllAsNew: true)
        #expect(tracker.newKeys == ["x"])

        // Only the first observation is affected by the flag.
        tracker.observe(["x", "y"], treatAllAsNew: true)
        #expect(tracker.newKeys == ["x", "y"])
    }

    @Test("markSeen removes one key and keeps the rest")
    func markSeen() {
        var tracker = NewItemTracker<Int>()
        tracker.observe([1])
        tracker.observe([1, 2, 3])
        tracker.markSeen(2)
        #expect(tracker.newKeys == [3])

        // Seen stays seen on later publishes.
        tracker.observe([1, 2, 3])
        #expect(tracker.newKeys == [3])
    }
}

@Suite
@MainActor
struct NewAgentHighlightStoreTests {
    @Test("local agents created after baseline are new until opened")
    func localAgents() {
        let store = NewAgentHighlightStore(detached: ())
        let existing = UUID()
        let created = UUID()

        store.observeLocalAgents([existing])
        #expect(store.newLocalAgentIds.isEmpty)

        store.observeLocalAgents([existing, created])
        #expect(store.isNew(localAgentId: created))
        #expect(!store.isNew(localAgentId: existing))

        store.markSeen(localAgentId: created)
        #expect(!store.isNew(localAgentId: created))
        #expect(store.newLocalAgentIds.isEmpty)
    }

    @Test("teammate agents that join a roster after the first load are new")
    func rosterAgents() {
        let store = NewAgentHighlightStore(detached: ())
        // First real roster load: `lastRefreshedAt` is still nil when the
        // emission arrives, so this is the baseline.
        store.observeRosterAgents(["osa1teammate"], firstLoadAlreadyHappened: false)
        #expect(store.newSharedAgentAddresses.isEmpty)

        store.observeRosterAgents(["osa1teammate", "osa1newcomer"], firstLoadAlreadyHappened: true)
        #expect(store.isNew(sharedAgentAddress: "OSA1NEWCOMER"))
        #expect(!store.isNew(sharedAgentAddress: "osa1teammate"))

        store.markSeen(sharedAgentAddress: "osa1newcomer")
        #expect(store.newSharedAgentAddresses.isEmpty)
    }

    @Test("an empty first roster load leaves the next roster change as new")
    func rosterEmptyFirstLoad() {
        let store = NewAgentHighlightStore(detached: ())
        // An empty first load never emits (`rosters` didn't change), so the
        // first emission the store sees already has `lastRefreshedAt` set.
        store.observeRosterAgents(["osa1shared"], firstLoadAlreadyHappened: true)
        #expect(store.isNew(sharedAgentAddress: "osa1shared"))
    }

    @Test("direct shares paired after baseline are new; roster and direct sets merge")
    func remoteAgentsMergeWithRoster() {
        let store = NewAgentHighlightStore(detached: ())
        store.observeRemoteAgents(["osa1direct"])
        store.observeRosterAgents(["osa1team"], firstLoadAlreadyHappened: false)
        #expect(store.newSharedAgentAddresses.isEmpty)

        store.observeRemoteAgents(["osa1direct", "osa1invite"])
        store.observeRosterAgents(["osa1team", "osa1joined"], firstLoadAlreadyHappened: true)
        #expect(store.newSharedAgentAddresses == ["osa1invite", "osa1joined"])

        store.markSeen(sharedAgentAddress: "osa1invite")
        #expect(store.newSharedAgentAddresses == ["osa1joined"])
    }

    @Test("markSeen for an agent that is not new is a no-op")
    func markSeenUnknown() {
        let store = NewAgentHighlightStore(detached: ())
        store.observeLocalAgents([UUID()])
        store.markSeen(localAgentId: UUID())
        store.markSeen(sharedAgentAddress: "osa1nobody")
        #expect(store.newLocalAgentIds.isEmpty)
        #expect(store.newSharedAgentAddresses.isEmpty)
    }
}
