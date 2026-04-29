//
//  PluginCreatorInjectionTests.swift
//  osaurusTests
//
//  Covers the "Sandbox Plugin Creator" backstop at two levels:
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
//     shape so downstream "contains Sandbox Plugin Creator" /
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
            canCreatePlugins: true,
            dynamicCatalogIsEmpty: true,
            hasResolvedDynamicTools: false,
            skillEnabled: true
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

    @Test
    func shouldInject_rejectsWhenCatalogHasOtherTools() {
        var inputs = baseInputs()
        inputs.dynamicCatalogIsEmpty = false
        #expect(PluginCreatorGate.shouldInject(inputs) == false)
    }

    @Test
    func shouldInject_rejectsWhenThisTurnResolvedDynamicTools() {
        var inputs = baseInputs()
        inputs.hasResolvedDynamicTools = true
        #expect(PluginCreatorGate.shouldInject(inputs) == false)
    }

    @Test
    func shouldInject_rejectsWhenUserDisabledTheSkill() {
        var inputs = baseInputs()
        inputs.skillEnabled = false
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
        inputs.skillEnabled = false
        #expect(PluginCreatorGate.shouldInject(inputs) == false)
    }

    // MARK: - section formatter

    @Test
    func section_includesSkillNameAndInstructions() {
        let rendered = PluginCreatorGate.section(
            skillName: "Sandbox Plugin Creator",
            instructions: "Write a plugin.json and call sandbox_plugin_register."
        )
        #expect(rendered.contains("Sandbox Plugin Creator"))
        #expect(rendered.contains("sandbox_plugin_register"))
        // The opening fallback message is the load-bearing signal to
        // the model that "no existing tools match" — assert it's there
        // so future template edits can't silently drop it.
        #expect(rendered.contains("No existing tools match this request"))
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
        await SandboxTestLock.shared.run {
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
}
