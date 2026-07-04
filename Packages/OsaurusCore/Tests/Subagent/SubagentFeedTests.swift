//
//  SubagentFeedTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Coverage for the generalized feed surface that every subagent kind emits
//  onto: the feed event stream + terminal status, the process-wide registry
//  lookup, and the interrupt center. Generalized from the computer-use feed
//  tests so the four subagent paths share one verified surface.
//

import Combine
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent feed + registry + interrupt")
struct SubagentFeedTests {

    @Test("the feed streams events and settles on a terminal status")
    func feedEventsAndStatus() {
        let feed = SubagentFeed(toolCallId: "call-1", kindId: "spawn", title: "do a thing")
        #expect(feed.currentEvents().isEmpty)
        #expect(feed.currentStatus() == .running)

        feed.emitPhase("resolving model")
        feed.emitProgress("step", fraction: 0.5, step: 1)
        #expect(feed.currentEvents().count == 2)
        #expect(feed.currentEvents().first?.kind == .phase)
        #expect(feed.currentEvents().last?.fraction == 0.5)

        feed.finish(success: true, summary: "done")
        #expect(feed.currentStatus() == .finished(success: true, summary: "done"))
        // finish is idempotent.
        feed.finish(success: false, summary: "ignored")
        #expect(feed.currentStatus() == .finished(success: true, summary: "done"))
    }

    @Test("consecutive same-title progress ticks update one row in place")
    func progressCoalescesInPlace() {
        let feed = SubagentFeed(toolCallId: "call-coalesce", kindId: "image", title: "a cat")

        feed.emitProgress("generating", fraction: 0.1, step: 1, detail: "step 1/30")
        let firstID = feed.currentEvents().first?.id
        #expect(feed.currentEvents().count == 1)

        feed.emitProgress("generating", fraction: 0.5, step: 15, detail: "step 15/30")
        feed.emitProgress("generating", fraction: 0.9, step: 27, detail: "step 27/30")

        // All three ticks collapse into ONE row that reflects the latest values
        // and keeps its original id so SwiftUI updates in place (no churn).
        #expect(feed.currentEvents().count == 1)
        let row = feed.currentEvents().first
        #expect(row?.id == firstID)
        #expect(row?.kind == .progress)
        #expect(row?.fraction == 0.9)
        #expect(row?.step == 27)
        #expect(row?.detail == "step 27/30")

        // A different progress title starts a fresh row.
        feed.emitProgress("finalizing", fraction: nil)
        #expect(feed.currentEvents().count == 2)

        // A non-progress phase emitted between progress ticks prevents
        // coalescing, so the next "generating" tick is its own row.
        feed.emitPhase("loading model")
        feed.emitProgress("generating", fraction: 0.2)
        #expect(feed.currentEvents().count == 4)
    }

    @Test("the registry resolves a registered feed by tool-call id")
    func registryLookup() {
        // Unique ids + targeted removal so this never races the shared
        // singleton under parallel test execution (clearAll() would wipe
        // feeds other suites legitimately registered).
        let registry = SubagentFeedRegistry.shared
        let id = "call-reg-\(UUID().uuidString)"
        let feed = SubagentFeed(toolCallId: id, kindId: "image", title: "a cat")
        registry.register(feed)
        #expect(registry.feed(for: id) === feed)
        #expect(registry.feed(for: "missing-\(UUID().uuidString)") == nil)
        registry.removeNow(toolCallId: id)
        #expect(registry.feed(for: id) == nil)
    }

    @Test("the feed observer windows a long history down to the rendered tail")
    @MainActor
    func observerWindowsLongHistory() {
        let feed = SubagentFeed(toolCallId: "call-window", kindId: "spawn", title: "long run")
        let total = SubagentFeedObserver.maxRenderedEvents + 50
        for i in 0 ..< total {
            feed.emit(SubagentActivityEvent(kind: .narrate, title: "step \(i)"))
        }
        // The feed itself keeps the full log; only rendering is windowed.
        #expect(feed.currentEvents().count == total)

        let observer = SubagentFeedObserver(feed: feed)
        #expect(observer.events.count == SubagentFeedObserver.maxRenderedEvents)
        #expect(observer.truncatedEventCount == 50)
        #expect(observer.events.first?.title == "step 50")
        #expect(observer.events.last?.title == "step \(total - 1)")
    }

    @Test("the feed observer passes a short history through untrimmed")
    @MainActor
    func observerKeepsShortHistory() {
        let feed = SubagentFeed(toolCallId: "call-short", kindId: "spawn", title: "short run")
        feed.emitPhase("resolving model")
        feed.emitPhase("running")
        let observer = SubagentFeedObserver(feed: feed)
        #expect(observer.events.count == 2)
        #expect(observer.truncatedEventCount == 0)
    }

    @Test("the interrupt center trips the right token")
    func interruptCenter() {
        let center = SubagentInterruptCenter.shared
        let token = InterruptToken()
        center.register(token, for: "call-int")
        #expect(token.isInterrupted == false)
        #expect(center.interrupt("call-int") == true)
        #expect(token.isInterrupted)
        // Unknown id reports no token found.
        #expect(center.interrupt("nope") == false)
        center.unregister("call-int")
        #expect(center.interrupt("call-int") == false)
    }
}
