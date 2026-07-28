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
                ],
                spawnableModelNames: [target],
                spawnableModelNotes: [target: "Use for difficult remote work"]
            )
        )
        SubagentConfigurationStore.flushPendingWrites()
        SubagentConfigurationStore.invalidateSnapshot()

        let decoded = SubagentConfigurationStore.snapshot()
        #expect(decoded.spawnableModelNames == [target])
        #expect(decoded.spawnableModelNotes[target] == "Use for difficult remote work")
        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id]
                == target
        )
    }

    @Test("custom-agent pool, note, and override survive Codable round-trip")
    func agentSettingsRoundTrip() throws {
        var settings = AgentSettings.defaultDisabled
        settings.spawnDelegationEnabled = true
        settings.spawnableModelNames = [target]
        settings.spawnableModelNotes = [target: "Use for difficult remote work"]
        settings.subagentModelOverrides = [
            SubagentCapabilityRegistry.spawn.id: target
        ]

        let decoded = try JSONDecoder().decode(
            AgentSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.spawnableModelNames == [target])
        #expect(decoded.spawnableModelNotes[target] == "Use for difficult remote work")
        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id]
                == target
        )
    }
}
