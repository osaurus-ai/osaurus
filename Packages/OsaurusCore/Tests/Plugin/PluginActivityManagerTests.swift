//
//  PluginActivityManagerTests.swift
//  osaurusTests
//
//  Lifecycle coverage for `PluginActivityManager`. Drives the manager
//  directly (no plugin host involvement) so the assertions run synchronously
//  on the main actor.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PluginActivityManagerTests {

    private func freshManager() -> PluginActivityManager {
        let mgr = PluginActivityManager.shared
        for id in mgr.active.keys { mgr.end(id) }
        return mgr
    }

    @Test
    func begin_addsRecord_endRemovesIt() {
        let mgr = freshManager()
        let id = UUID()
        mgr.begin(
            id: id,
            pluginId: "com.example.plugin",
            pluginDisplayName: "Example",
            kind: .completeStream
        )
        #expect(mgr.active.count == 1)
        #expect(mgr.hasActive)
        #expect(mgr.active[id]?.pluginDisplayName == "Example")
        #expect(mgr.active[id]?.kind == .completeStream)

        mgr.end(id)
        #expect(mgr.active.isEmpty)
        #expect(!mgr.hasActive)
    }

    @Test
    func observeChunk_updatesLastChunkAtForStreaming() {
        let mgr = freshManager()
        let id = UUID()
        mgr.begin(
            id: id,
            pluginId: "p",
            pluginDisplayName: "p",
            kind: .completeStream
        )
        #expect(mgr.active[id]?.lastChunkAt == nil)
        mgr.observeChunk(id)
        #expect(mgr.active[id]?.lastChunkAt != nil)
        mgr.end(id)
    }

    @Test
    func topActivity_returnsMostRecentlyStarted() async throws {
        let mgr = freshManager()
        let first = UUID()
        let second = UUID()

        mgr.begin(id: first, pluginId: "p", pluginDisplayName: "first", kind: .complete)
        try await Task.sleep(for: .milliseconds(5))
        mgr.begin(id: second, pluginId: "p", pluginDisplayName: "second", kind: .complete)

        #expect(mgr.topActivity?.id == second)
        mgr.end(second)
        #expect(mgr.topActivity?.id == first)
        mgr.end(first)
    }

    @Test
    func end_isIdempotent() {
        let mgr = freshManager()
        let id = UUID()
        mgr.begin(id: id, pluginId: "p", pluginDisplayName: "p", kind: .embed)
        mgr.end(id)
        mgr.end(id)  // second call is a no-op
        #expect(mgr.active.isEmpty)
    }
}
