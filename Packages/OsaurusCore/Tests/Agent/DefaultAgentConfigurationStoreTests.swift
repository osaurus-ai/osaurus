//
//  DefaultAgentConfigurationStoreTests.swift
//  OsaurusCoreTests
//
//  Validates the store that holds the built-in Default agent's
//  settings in its own `~/.osaurus/config/default-agent.json` file:
//
//   * round-trip — `save(_:)` followed by `load()` returns the same
//     value with the cache invalidated, so the next live read sees
//     the new on-disk state.
//   * Codable defaults — missing fields fall back to clean defaults.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct DefaultAgentConfigurationStoreTests {

    @MainActor
    private static func withTempOverride<T>(
        body: @MainActor () throws -> T
    ) async rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-default-agent-cfg-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let previous = DefaultAgentConfigurationStore.overrideDirectory
        DefaultAgentConfigurationStore.overrideDirectory = tmp
        DefaultAgentConfigurationStore.resetCacheForTests()
        defer {
            DefaultAgentConfigurationStore.overrideDirectory = previous
            DefaultAgentConfigurationStore.resetCacheForTests()
            try? FileManager.default.removeItem(at: tmp)
        }
        return try body()
    }

    // MARK: - Round trip

    @Test
    @MainActor
    func roundTrip_savesAndLoads() async throws {
        try await StoragePathsTestLock.shared.run {
            try await Self.withTempOverride {
                let configured = DefaultAgentConfiguration(
                    systemPrompt: "Be terse.",
                    defaultModel: "mlx-community/Qwen3-4B-Instruct",
                    temperature: 0.42,
                    maxTokens: 9_001,
                    disableTools: true,
                    autonomousExec: nil,
                    toolSelectionMode: .manual,
                    manualToolNames: ["osaurus_status", "osaurus_list"],
                    manualSkillNames: ["greeting"]
                )

                DefaultAgentConfigurationStore.save(configured)
                DefaultAgentConfigurationStore.resetCacheForTests()

                let reloaded = DefaultAgentConfigurationStore.load()
                #expect(reloaded == configured)
            }
        }
    }

    // MARK: - Codable defaults

    @Test
    func decode_missingFields_fallsBackToDefaults() throws {
        let json = #"{}"#
        let decoded = try JSONDecoder().decode(
            DefaultAgentConfiguration.self,
            from: Data(json.utf8)
        )
        #expect(decoded.systemPrompt == "")
        #expect(decoded.defaultModel == nil)
        #expect(decoded.temperature == nil)
        #expect(decoded.maxTokens == nil)
        #expect(decoded.disableTools == false)
        #expect(decoded.autonomousExec == nil)
        #expect(decoded.toolSelectionMode == nil)
        #expect(decoded.manualToolNames == nil)
        #expect(decoded.manualSkillNames == nil)
    }

    @Test("Automatic persists as a setting but effectiveModel returns a concrete local route")
    @MainActor
    func automaticSettingResolvesConcreteLocalModel() async throws {
        try await StoragePathsTestLock.shared.run {
            try await Self.withTempOverride {
                var config = DefaultAgentConfigurationStore.load()
                config.defaultModel = AutomaticModelRoutingPolicy.modelId
                DefaultAgentConfigurationStore.save(config)

                let local = ModelPickerItem(
                    id: "local/compatible",
                    displayName: "Compatible",
                    source: .local,
                    estimatedMemoryGB: 4,
                    hardwareCompatibility: .compatible
                )
                let remote = ModelPickerItem.fromRemoteModel(
                    modelId: "cloud/frontier",
                    providerName: "Cloud",
                    providerId: UUID()
                )
                let previous = ModelPickerItemCache.shared._setItemsForTesting([remote, local])
                defer { ModelPickerItemCache.shared._setItemsForTesting(previous) }

                #expect(
                    AgentManager.shared.configuredModel(for: Agent.defaultId)
                        == AutomaticModelRoutingPolicy.modelId
                )
                #expect(AgentManager.shared.effectiveModel(for: Agent.defaultId) == local.id)
            }
        }
    }
}
