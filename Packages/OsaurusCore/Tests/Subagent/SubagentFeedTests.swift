//
//  SubagentFeedTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Coverage for the generalized feed surface that every sub-agent kind emits
//  onto: the feed event stream + terminal status, the process-wide registry
//  lookup, and the interrupt center. Generalized from the computer-use feed
//  tests so the four sub-agent paths share one verified surface.
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
