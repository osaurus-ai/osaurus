//
//  SchemaSnapshotPreviewTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SchemaSnapshotPreviewTests {
    @Test
    func cachedPreviewDoesNotWaitForSlowSQLiteRefresh() async throws {
        let agentId = UUID()
        let bridge = LocalAgentBridge.shared
        bridge.forget(agentId: agentId)

        LocalAgentBridge.schemaSnapshotOverrideForTests = { requestedId in
            #expect(requestedId == agentId)
            Thread.sleep(forTimeInterval: 0.25)
            return "slow-schema-marker"
        }
        defer {
            LocalAgentBridge.schemaSnapshotOverrideForTests = nil
            bridge.forget(agentId: agentId)
        }

        let started = ContinuousClock.now
        let first = SystemPromptComposer.renderSchemaSnapshot(
            agentId: agentId,
            cachedOnly: true
        )
        let elapsed = started.duration(to: .now)

        #expect(first == SchemaSnapshot.emptyStateBlock)
        #expect(elapsed < .milliseconds(100))

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var cached: String?
        while ContinuousClock.now < deadline {
            cached = bridge.cachedSchemaSnapshot(agentId: agentId)
            if cached == "slow-schema-marker" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(cached == "slow-schema-marker")
    }
}
