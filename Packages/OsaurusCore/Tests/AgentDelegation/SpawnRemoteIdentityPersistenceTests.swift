//
//  SpawnRemoteIdentityPersistenceTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Spawn remote target persistence", .serialized)
struct SpawnRemoteIdentityPersistenceTests {
    private let target = SpawnRemoteModelIdentity.make(
        providerId: UUID(uuidString: "C9412118-D6C8-4BC0-90D9-5C686C5A54C8")!,
        modelId: "vendor/frontier-model"
    )!

    @Test("main-chat pool, note, and override survive store reload")
    func mainChatStoreRoundTrip() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-remote-identity-store")
        defer { lease.release() }

        SubagentConfigurationStore.save(
            SubagentConfiguration(
                subagentModelOverrides: [
                    SubagentCapabilityRegistry.spawn.id: target
                ]
            )
        )
        SubagentConfigurationStore.flushPendingWrites()
        SubagentConfigurationStore.invalidateSnapshot()

        let decoded = SubagentConfigurationStore.snapshot()
        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id]
                == target
        )
    }

    @Test("custom-agent remote override survives Codable round-trip")
    func agentSettingsRoundTrip() throws {
        var settings = AgentSettings.defaultDisabled
        settings.spawnDelegationEnabled = true
        settings.subagentModelOverrides = [
            SubagentCapabilityRegistry.spawn.id: target
        ]

        let decoded = try JSONDecoder().decode(
            AgentSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id]
                == target
        )
    }
}
