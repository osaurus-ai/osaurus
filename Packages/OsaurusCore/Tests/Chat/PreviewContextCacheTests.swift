//
//  PreviewContextCacheTests.swift
//  osaurusTests
//
//  Pins the cross-session preview coalescing that keeps N open chat windows
//  from each running a full main-thread compose on the same debounced
//  prompt-shape signal (APPLE-MACOS-3E9 app hang).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct PreviewContextCacheTests {
    private static let testNotification = Notification.Name("PreviewContextCacheTests.promptShape")

    private func compose() -> ComposedContext {
        SystemPromptComposer.composePreviewContext(agentId: Agent.defaultId, executionMode: .none)
    }

    @Test func identicalKeysInOneBurstComposeOnce() {
        let cache = PreviewContextCache(notificationNames: [Self.testNotification])
        let key = PreviewContextCache.key(
            agentId: Agent.defaultId, executionMode: .none, model: "m", modelType: nil, source: .chat)
        var calls = 0
        let now = Date()
        let first = cache.context(forKey: key, now: now) { calls += 1; return compose() }
        let second = cache.context(forKey: key, now: now.addingTimeInterval(0.1)) { calls += 1; return compose() }
        #expect(calls == 1)
        #expect(first.prompt == second.prompt)
        #expect(first.cacheHint == second.cacheHint)
    }

    @Test func differentInputsDoNotShareEntries() {
        let a = PreviewContextCache.key(
            agentId: Agent.defaultId, executionMode: .none, model: "a", modelType: nil, source: .chat)
        let b = PreviewContextCache.key(
            agentId: Agent.defaultId, executionMode: .none, model: "b", modelType: nil, source: .chat)
        let c = PreviewContextCache.key(
            agentId: Agent.defaultId, executionMode: .sandbox, model: "a", modelType: nil, source: .chat)
        #expect(a != b)
        #expect(a != c)
    }

    @Test func promptShapeNotificationForcesRecompose() {
        let cache = PreviewContextCache(notificationNames: [Self.testNotification])
        let key = PreviewContextCache.key(
            agentId: Agent.defaultId, executionMode: .none, model: nil, modelType: nil, source: .chat)
        var calls = 0
        let now = Date()
        _ = cache.context(forKey: key, now: now) { calls += 1; return compose() }
        NotificationCenter.default.post(name: Self.testNotification, object: nil)
        _ = cache.context(forKey: key, now: now) { calls += 1; return compose() }
        #expect(calls == 2)
    }

    @Test func entriesExpireAfterLifetime() {
        let cache = PreviewContextCache(notificationNames: [Self.testNotification])
        let key = PreviewContextCache.key(
            agentId: Agent.defaultId, executionMode: .none, model: nil, modelType: nil, source: .chat)
        var calls = 0
        let now = Date()
        _ = cache.context(forKey: key, now: now) { calls += 1; return compose() }
        _ = cache.context(
            forKey: key,
            now: now.addingTimeInterval(PreviewContextCache.entryLifetime + 0.01)
        ) { calls += 1; return compose() }
        #expect(calls == 2)
    }

    @Test func routingJSONMemoReturnsIdenticalOutput() {
        let first = AgentDescriptionPolicy.routingJSON(id: "x", name: "Helper", description: "Reviews code.")
        let second = AgentDescriptionPolicy.routingJSON(id: "x", name: "Helper", description: "Reviews code.")
        let edited = AgentDescriptionPolicy.routingJSON(id: "x", name: "Helper", description: "Writes docs.")
        #expect(first == second)
        #expect(first != edited)
    }
}
