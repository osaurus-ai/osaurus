//
//  InsightsPresenceTests.swift
//  osaurusTests
//

import Combine
import Foundation
import Testing

@testable import OsaurusCore

/// `knownHasLog` backs the Credits timeline's Insights links. It must answer
/// from memory on the main thread (APPLE-MACOS-3QQ: per-row store reads in
/// the body hung the app while appends held the store queue) and still
/// surface rows that only the store has.
@MainActor
struct InsightsPresenceTests {
    private func row(requestId: String, turnId: UUID = UUID()) -> RequestLog {
        RequestLog(
            source: .chatUI,
            turnId: turnId,
            requestId: requestId,
            method: "POST",
            path: "/chat/completions",
            statusCode: 200,
            durationMs: 1
        )
    }

    private func makeService() throws -> (InsightsService, ActivityLogStore) {
        let store = ActivityLogStore()
        try store.openInMemory()
        return (InsightsService(store: store, openStore: false), store)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 80 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    @Test func storeOnlyRowReadsFalseThenPublishesTrue() async throws {
        let (service, store) = try makeService()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let turnId = UUID()
        try store.append(row(requestId: "req-store-only", turnId: turnId))

        var changes = 0
        let watch = service.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }

        #expect(service.knownHasLog(requestId: "req-store-only") == false)
        #expect(service.knownHasLog(turnId: turnId) == false)
        #expect(await eventually { service.knownHasLog(requestId: "req-store-only") })
        #expect(service.knownHasLog(turnId: turnId))
        #expect(changes > 0)
        #expect(service.knownHasLog(requestId: "req-missing") == false)
    }

    @Test func storeChangeKeepsFoundAnswersAndRereadsMissingOnes() async throws {
        let (service, store) = try makeService()
        try store.append(row(requestId: "req-found"))

        _ = service.knownHasLog(requestId: "req-found")
        _ = service.knownHasLog(requestId: "req-late")
        #expect(await eventually { service.knownHasLog(requestId: "req-found") })

        try store.append(row(requestId: "req-late"))
        #expect(service.knownHasLog(requestId: "req-late") == false)

        service.noteExternalStoreChange()
        #expect(service.knownHasLog(requestId: "req-found"))
        #expect(await eventually { service.knownHasLog(requestId: "req-late") })
    }

    @Test func clearDropsFoundAnswers() async throws {
        let (service, store) = try makeService()
        try store.append(row(requestId: "req-cleared"))
        _ = service.knownHasLog(requestId: "req-cleared")
        #expect(await eventually { service.knownHasLog(requestId: "req-cleared") })

        service.clear()
        #expect(service.knownHasLog(requestId: "req-cleared") == false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = service.knownHasLog(requestId: "req-cleared")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(service.knownHasLog(requestId: "req-cleared") == false)
    }
}
