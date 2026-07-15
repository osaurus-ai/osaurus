//
//  RemoteProviderSessionLifecycleTests.swift
//  osaurusTests
//
//  Pins the session-lifecycle guard that closes the invalidate-vs-`bytes(for:)`
//  TOCTOU: task-creation windows are bracketed by begin/end, and
//  `invalidateSession()` defers `invalidateAndCancel()` until in-flight
//  requests drain instead of invalidating the session under them (which
//  raises an uncatchable Obj-C exception and aborts the process).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct RemoteProviderSessionLifecycleTests {

    private func makeService() -> RemoteProviderService {
        let provider = RemoteProvider(
            name: "Lifecycle Test",
            host: "127.0.0.1",
            basePath: "/v1",
            authType: .none,
            providerType: .openaiLegacy
        )
        return RemoteProviderService(provider: provider, models: [], resolvedHeaders: [:])
    }

    @Test func beginSucceedsBeforeInvalidation_andIsRefusedAfter() async {
        let service = makeService()
        #expect(service.beginSessionRequest())
        service.endSessionRequest()

        await service.invalidateSession()
        #expect(service.isSessionInvalidated)
        #expect(!service.beginSessionRequest(), "no new task-creation windows after invalidation")
    }

    @Test func invalidationIsDeferredWhileRequestInFlight() async {
        let service = makeService()

        // Open a task-creation window, then request invalidation while it is
        // still open: the flag must flip immediately (new begins refused) but
        // the actual invalidateAndCancel must wait for the matching end.
        #expect(service.beginSessionRequest())
        await service.invalidateSession()
        #expect(service.isSessionInvalidated)
        #expect(!service.beginSessionRequest())

        // Closing the window runs the deferred invalidation; this must be
        // safe to call from a nonisolated context and must not crash.
        service.endSessionRequest()
        #expect(service.isSessionInvalidated)
        #expect(!service.beginSessionRequest())
    }

    @Test func doubleInvalidationIsIdempotent() async {
        let service = makeService()
        await service.invalidateSession()
        await service.invalidateSession()
        #expect(service.isSessionInvalidated)
    }

    @Test func concurrentBeginEndAndInvalidateDoNotRace() async {
        // Hammer begin/end from many tasks while invalidation lands midway.
        // The guard must never let a begin succeed after invalidation and the
        // in-flight count must drain cleanly (no crash, no negative counts).
        let service = makeService()
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 200 {
                group.addTask {
                    if service.beginSessionRequest() {
                        await Task.yield()
                        service.endSessionRequest()
                    }
                }
                if i == 100 {
                    group.addTask { await service.invalidateSession() }
                }
            }
        }
        #expect(service.isSessionInvalidated)
        #expect(!service.beginSessionRequest())
    }
}
