//
//  PluginCreatorInjectionTests.swift
//  osaurusTests
//
//  Covers the plugin-creator backstop (the `## Building new tools`
//  section) at two levels:
//
//  1. `PluginCreatorGate.shouldInject` — pure gate. Unit tests exhaust
//     every input combination with zero globals / zero async hops.
//     These replace the previous integration test that fought
//     `ToolRegistry.shared` + `SkillManager.shared` via stacked locks
//     and temp storage overrides. Every regression that test ever
//     caught is now either a gate-logic bug (fully covered here) or a
//     wiring bug in the composer (covered by the composer's own tests
//     — the injection call site is three lines).
//
//  2. `PluginCreatorGate.section` — pure formatter. Locks the output
//     shape so the "Building new tools" heading and
//     "contains sandbox_plugin_register" assertions don't silently
//     break if the template text drifts.
//
//  3. `SystemPromptComposer.composeChatContext` negative-path wiring
//     test — when autonomous exec is off, the section must NOT appear.
//     This one doesn't depend on catalog state and is hence stable.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct PluginCreatorGateTests {

    private func baseInputs() -> PluginCreatorGate.Inputs {
        // A passing baseline — flipping any one field to its failure
        // state should flip `shouldInject` to false. That's the shape
        // every test below relies on.
        PluginCreatorGate.Inputs(
            effectiveToolsOff: false,
            sandboxAvailable: true,
            canCreatePlugins: true
        )
    }

    @Test
    func shouldInject_baselineAllowsInjection() {
        #expect(PluginCreatorGate.shouldInject(baseInputs()))
    }

    @Test
    func shouldInject_rejectsWhenToolsOff() {
        var inputs = baseInputs()
        inputs.effectiveToolsOff = true
        #expect(PluginCreatorGate.shouldInject(inputs) == false)
    }

    @Test
    func shouldInject_rejectsWhenSandboxUnavailable() {
        var inputs = baseInputs()
        inputs.sandboxAvailable = false
        #expect(PluginCreatorGate.shouldInject(inputs) == false)
    }

    @Test
    func shouldInject_rejectsWhenAgentCannotCreatePlugins() {
        var inputs = baseInputs()
        inputs.canCreatePlugins = false
        #expect(PluginCreatorGate.shouldInject(inputs) == false)
    }

    // Sanity check: multiple failing conditions still fail (no weird
    // cancellation). Locks the "all gates must pass" contract instead
    // of just "any one gate failing kills it".
    @Test
    func shouldInject_rejectsWhenMultipleConditionsFail() {
        var inputs = baseInputs()
        inputs.effectiveToolsOff = true
        inputs.sandboxAvailable = false
        inputs.canCreatePlugins = false
        #expect(PluginCreatorGate.shouldInject(inputs) == false)
    }

    // MARK: - section formatter

    @Test
    func section_includesHeadingAndInstructions() {
        let rendered = PluginCreatorGate.section(
            instructions: "Write a plugin.json and call sandbox_plugin_register."
        )
        #expect(rendered.contains("sandbox_plugin_register"))
        // The opening header + the "plugin creation is enabled" framing are the
        // load-bearing signal to the model that it can build new tools — assert
        // both are there so future template edits can't silently drop them.
        #expect(rendered.contains("## Building new tools"))
        #expect(rendered.contains("Plugin creation is enabled"))
    }

    @Test
    func compactInstructions_keepActionableRegistrationContract() {
        let compact = SystemPromptTemplates.pluginCreatorInstructionsCompactBody()
        let full = SystemPromptTemplates.pluginCreatorInstructions

        #expect(compact.contains("plugins/{service}/"))
        #expect(compact.contains("`name` and `description`"))
        #expect(compact.contains("`id`"))
        #expect(compact.contains("simplified `parameters`"))
        #expect(compact.contains("`run`"))
        #expect(compact.contains("file_write"))
        #expect(compact.contains("sandbox_plugin_register"))
        #expect(compact.contains("immediately call the returned prefixed tool"))
        #expect(TokenEstimator.estimate(compact) < TokenEstimator.estimate(full))
        #expect(
            SystemPromptComposer.pluginCreatorInstructions(
                prefersCompactPrompt: true,
                hostWritableCombined: false
            ) == compact
        )
        #expect(
            SystemPromptComposer.pluginCreatorInstructions(
                prefersCompactPrompt: false,
                hostWritableCombined: false
            ) == full
        )
    }
}

// MARK: - Composer wiring (negative path only)
//
// The positive path (`Plugin Creator` section appears) is covered by
// the unit tests above via `PluginCreatorGate.shouldInject`. The only
// thing left to pin at the composer level is the negative case:
// outside sandbox / without autonomous, the section MUST stay out of
// the prompt. This test is stable because it doesn't depend on the
// dynamic catalog being empty — none of the gates it fails against
// read shared mutable state.

@Suite(.serialized)
@MainActor
struct PluginCreatorComposerWiringTests {

    @Test
    func composeChatContext_skipsPluginCreatorOutsideSandbox() async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "Plugin Creator Non-Sandbox Agent",
                agentAddress: "test-plugin-creator-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: false, pluginCreate: true)
            )
            AgentManager.shared.add(agent)

            let context = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .none
            )
            let labels = context.manifest.sections.map(\.label)
            #expect(labels.contains("Plugin Creator") == false)

            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("enabling plugin creation updates a frozen running-sandbox session")
    func enablingPluginCreationUpdatesFrozenSession() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let registrar = SandboxToolRegistrar.shared
            let registry = ToolRegistry.shared
            let originalStatus = SandboxManager.State.shared.status
            let originalProvisionOverride = registrar.provisionAgentOverride

            let initialConfig = AutonomousExecConfig(
                enabled: true,
                pluginCreate: false
            )
            let agent = Agent(
                name: "Plugin Creator Toggle \(UUID().uuidString)",
                agentAddress: "test-plugin-creator-toggle-\(UUID().uuidString)",
                autonomousExec: initialConfig
            )
            manager.add(agent)
            SandboxManager.State.shared.status = .running
            registrar.provisionAgentOverride = { _ in }
            registry.unregisterAllBuiltinSandboxTools()
            await registrar.registerTools(for: agent.id)

            let before = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox,
                model: "gpt-5"
            )
            #expect(
                !before.tools.contains { $0.function.name == "sandbox_plugin_register" }
            )
            #expect(!before.manifest.sections.map(\.id).contains("pluginCreator"))

            var enabledConfig = initialConfig
            enabledConfig.pluginCreate = true
            try await manager.updateAutonomousExec(enabledConfig, for: agent.id)
            await registrar.registerTools(for: agent.id)

            let after = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox,
                model: "gpt-5",
                frozenAlwaysLoadedNames: before.alwaysLoadedNames,
                frozenToolSpecs: before.initialToolSpecs,
                frozenManifest: before.enabledManifest,
                frozenSoul: before.soul
            )
            #expect(
                after.tools.contains { $0.function.name == "sandbox_plugin_register" }
            )
            #expect(after.manifest.sections.map(\.id).contains("pluginCreator"))
            #expect(after.prompt.contains("sandbox_plugin_register"))

            registry.unregisterAllSandboxTools()
            registrar.provisionAgentOverride = originalProvisionOverride
            SandboxManager.State.shared.status = originalStatus
            _ = await manager.delete(id: agent.id)
        }
    }
}
