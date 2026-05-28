//
//  DefaultAgentConfigurationStoreTests.swift
//  OsaurusCoreTests
//
//  Validates the Phase-B store that splits the built-in Default
//  agent's settings out of `ChatConfiguration` into its own
//  `~/.osaurus/config/default-agent.json` file:
//
//   * round-trip — `save(_:)` followed by `load()` returns the same
//     value with the cache invalidated, so the next live read sees
//     the new on-disk state.
//   * one-shot migration — on first load with no `default-agent.json`
//     present, the relevant fields are copied off `ChatConfiguration`
//     so the user's existing persona / model / autonomous-exec
//     selection survives the split. `migrateFromChatConfiguration`
//     is invoked directly to keep this test source-only and avoid
//     touching the global `ChatConfigurationStore` cache.
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

    // MARK: - Migration

    @Test
    @MainActor
    func migration_copiesPhaseAFieldsFromChatConfiguration() {
        // Use the synchronous helper directly to keep this test off
        // the live `ChatConfigurationStore` (which would write to
        // `chat.json` in the real Osaurus config directory).
        var chat = ChatConfiguration.default
        chat.systemPrompt = "Migrated persona"
        chat.defaultModel = "mlx-community/Phi-3-mini"
        chat.temperature = 0.7
        chat.maxTokens = 2048
        chat.disableTools = true
        chat.defaultAutonomousExec = AutonomousExecConfig(enabled: true)
        chat.defaultToolSelectionMode = .manual
        chat.defaultManualToolNames = ["osaurus_describe", "osaurus_list"]
        chat.defaultManualSkillNames = ["coder"]

        let migrated = DefaultAgentConfigurationStore.migrateFromChatConfiguration(chat)

        #expect(migrated.systemPrompt == "Migrated persona")
        #expect(migrated.defaultModel == "mlx-community/Phi-3-mini")
        #expect(migrated.temperature == 0.7)
        #expect(migrated.maxTokens == 2048)
        #expect(migrated.disableTools == true)
        #expect(migrated.autonomousExec?.enabled == true)
        #expect(migrated.toolSelectionMode == .manual)
        #expect(migrated.manualToolNames == ["osaurus_describe", "osaurus_list"])
        #expect(migrated.manualSkillNames == ["coder"])
    }

    @Test
    @MainActor
    func migration_handlesEmptyChatConfiguration() {
        let chat = ChatConfiguration.default
        let migrated = DefaultAgentConfigurationStore.migrateFromChatConfiguration(chat)

        // A clean install must yield a clean default-agent config —
        // no garbage values, no implicit prompts. `disableTools`
        // tracks the chat-side default which is currently `false`.
        #expect(migrated.systemPrompt == chat.systemPrompt)
        #expect(migrated.defaultModel == chat.defaultModel)
        #expect(migrated.temperature == chat.temperature)
        #expect(migrated.maxTokens == chat.maxTokens)
        #expect(migrated.disableTools == chat.disableTools)
        #expect(migrated.autonomousExec == nil)
        #expect(migrated.toolSelectionMode == nil)
        #expect(migrated.manualToolNames == nil)
        #expect(migrated.manualSkillNames == nil)
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
}
