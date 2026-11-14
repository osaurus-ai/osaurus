//
//  ArchitectConfigurationStoreTests.swift
//  OsaurusCoreTests
//
//  The Architect's settings at `~/.osaurus/config/architect.json`:
//
//   * an older model-only file still decodes, with no custom identity;
//   * saved name and avatar render on `Agent.architect`, and resetting
//     puts back the stock "Architect" and blue dino;
//   * extra instructions follow the built-in persona without replacing it;
//   * its draft and test tools go through the tool permission gate.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ArchitectConfigurationStoreTests {

    @MainActor
    private static func withTempOverride<T>(
        body: @MainActor () throws -> T
    ) async rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-architect-cfg-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let previous = ArchitectConfigurationStore.overrideDirectory
        ArchitectConfigurationStore.overrideDirectory = tmp
        ArchitectConfigurationStore.resetCacheForTests()
        defer {
            ArchitectConfigurationStore.overrideDirectory = previous
            ArchitectConfigurationStore.resetCacheForTests()
            try? FileManager.default.removeItem(at: tmp)
        }
        return try body()
    }

    @Test
    func decode_modelOnlyFile_keepsTheStockIdentity() throws {
        let decoded = try JSONDecoder().decode(
            ArchitectConfiguration.self,
            from: Data(#"{"model": "foundation"}"#.utf8)
        )
        #expect(decoded.model == "foundation")
        #expect(decoded.runtime == nil)
        #expect(decoded.claudeCode == nil)
        #expect(decoded.displayName == nil)
        #expect(decoded.avatar == nil)
        #expect(decoded.customAvatarFilename == nil)
        #expect(decoded.systemPrompt == "")
        #expect(decoded.resolvedDisplayName == nil)
    }

    @Test
    @MainActor
    func pickerModelAndRuntimeChoicesPersistWithoutReplacingArchitectSettings() async throws {
        try await StoragePathsTestLock.shared.run {
            try await Self.withTempOverride {
                ArchitectConfigurationStore.save(ArchitectConfiguration(
                    displayName: "Blueprint", systemPrompt: "Keep these instructions."))
                let manager = AgentManager.shared
                let runtime = AgentRuntime.harness(UUID())
                var claude = ClaudeCodeAgentConfig.default
                claude.model = "opus"
                manager.updateDefaultModel(for: Agent.architectId, model: "local-test-model")
                manager.updateClaudeCodeConfig(claude, for: Agent.architectId)
                manager.updateRuntime(runtime, for: Agent.architectId)
                ArchitectConfigurationStore.resetCacheForTests()
                let saved = ArchitectConfigurationStore.load()
                #expect(saved.model == "local-test-model")
                #expect(saved.runtime == runtime)
                #expect(saved.claudeCode == claude)
                #expect(saved.displayName == "Blueprint")
                #expect(saved.systemPrompt == "Keep these instructions.")
                #expect(manager.effectiveRuntime(for: Agent.architectId) == runtime)
                #expect(manager.effectiveClaudeCodeConfig(for: Agent.architectId) == claude)
                manager.updateRuntime(.builtIn, for: Agent.architectId)
                ArchitectConfigurationStore.resetCacheForTests()
                #expect(ArchitectConfigurationStore.load().runtime == nil)
                #expect(manager.effectiveRuntime(for: Agent.architectId) == .builtIn)
            }
        }
    }

    @Test
    func blankName_resolvesToTheStockName() {
        #expect(ArchitectConfiguration(displayName: "   ").resolvedDisplayName == nil)
        #expect(ArchitectConfiguration(displayName: " Blueprint ").resolvedDisplayName == "Blueprint")
    }

    @Test
    @MainActor
    func savedIdentity_rendersOnTheArchitect_andResetRestoresIt() async throws {
        try await StoragePathsTestLock.shared.run {
            try await Self.withTempOverride {
                ArchitectConfigurationStore.update {
                    $0.displayName = "Blueprint"
                    $0.avatar = "purple"
                    $0.systemPrompt = "Prefer local models."
                }
                #expect(Agent.architect.name == "Blueprint")
                #expect(Agent.architect.avatar == "purple")

                ArchitectConfigurationStore.resetCacheForTests()
                #expect(Agent.architect.name == "Architect")
                #expect(Agent.architect.avatar == Agent.architectStockAvatar)

                let reloaded = ArchitectConfigurationStore.load()
                #expect(reloaded.displayName == "Blueprint")
                #expect(reloaded.systemPrompt == "Prefer local models.")
                #expect(Agent.architect.name == "Blueprint", "loading mirrors the saved identity again")
            }
        }
    }

    @Test
    @MainActor
    func update_touchesOnlyTheChangedField() async throws {
        try await StoragePathsTestLock.shared.run {
            try await Self.withTempOverride {
                ArchitectConfigurationStore.save(ArchitectConfiguration(model: "foundation", displayName: "Blueprint"))
                ArchitectConfigurationStore.update { $0.systemPrompt = "Keep it short." }
                ArchitectConfigurationStore.resetCacheForTests()
                let reloaded = ArchitectConfigurationStore.load()
                #expect(reloaded.model == "foundation")
                #expect(reloaded.displayName == "Blueprint")
                #expect(reloaded.systemPrompt == "Keep it short.")
            }
        }
    }

    @Test
    func prompt_addsNameAndInstructionsAfterThePersona() {
        let base = ArchitectSystemPromptBuilder.render()
        #expect(ArchitectSystemPromptBuilder.render(displayName: nil, instructions: "  ") == base)

        let custom = ArchitectSystemPromptBuilder.render(displayName: "Blueprint", instructions: "Prefer local models.")
        #expect(custom.hasPrefix(base), "the built-in persona stays first and unchanged")
        #expect(custom.contains("Blueprint"))
        #expect(custom.contains("Prefer local models."))
    }

    @Test
    @MainActor
    func draftAndTestTools_runWithoutAsking_untilAPolicyChangesIt() async throws {
        let registry = ToolRegistry.shared
        for name in [WorkflowDraftTool.toolName, WorkflowTestTool.toolName] {
            let info = try #require(registry.policyInfo(for: name))
            #expect(info.isPermissioned)
            #expect(info.defaultPolicy == .auto)
        }

        let name = WorkflowTestTool.toolName
        registry.setPolicy(.deny, for: name)
        defer { registry.clearPolicy(for: name) }
        #expect(registry.policyInfo(for: name)?.effectivePolicy == .deny)
        do {
            try await registry.resolvePermissionGate(name: name, argumentsJSON: "{}")
            Issue.record("a denied workflow_test should not pass the permission gate")
        } catch {
            #expect((error as NSError).localizedDescription.contains(name))
        }
    }
}
