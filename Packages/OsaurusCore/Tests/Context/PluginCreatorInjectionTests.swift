//
//  PluginCreatorInjectionTests.swift
//  osaurusTests
//
//  Pins down the gates around the "Sandbox Plugin Creator" backstop:
//  - `PreflightCapabilitySearch.pluginCreatorSkillSection` checks both
//    `canCreatePlugins` and the skill's `enabled` flag.
//  - `SystemPromptComposer.composeChatContext` injects the section when
//    the dynamic catalog is empty for sandbox-enabled agents.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PluginCreatorInjectionTests {

    // MARK: - pluginCreatorSkillSection

    @Test
    func pluginCreatorSkillSection_returnsNilWhenAutonomousDisabled() async {
        let agent = Agent(name: "Plugin Creator Off Agent")
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let section = await PreflightCapabilitySearch.pluginCreatorSkillSection(
            for: agent.id
        )
        #expect(section == nil)
    }

    @Test
    func pluginCreatorSkillSection_returnsNilWhenPluginCreateDisabled() async {
        let agent = Agent(
            name: "Plugin Create Off Agent",
            autonomousExec: AutonomousExecConfig(enabled: true, pluginCreate: false)
        )
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let section = await PreflightCapabilitySearch.pluginCreatorSkillSection(
            for: agent.id
        )
        #expect(section == nil)
    }

    @Test
    func pluginCreatorSkillSection_returnsContentWhenSkillEnabled() async throws {
        let agent = Agent(
            name: "Plugin Creator Enabled Agent",
            autonomousExec: AutonomousExecConfig(enabled: true, pluginCreate: true)
        )
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        await ensurePluginCreatorSkill(enabled: true)

        let section = await PreflightCapabilitySearch.pluginCreatorSkillSection(
            for: agent.id
        )
        let content = try #require(section)
        #expect(content.contains("Sandbox Plugin Creator"))
        #expect(content.contains("sandbox_plugin_register"))
    }

    @Test
    func pluginCreatorSkillSection_returnsNilWhenUserDisablesSkill() async {
        let agent = Agent(
            name: "Plugin Creator Skill Disabled",
            autonomousExec: AutonomousExecConfig(enabled: true, pluginCreate: true)
        )
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        await ensurePluginCreatorSkill(enabled: false)
        defer { Task { await ensurePluginCreatorSkill(enabled: true) } }

        let section = await PreflightCapabilitySearch.pluginCreatorSkillSection(
            for: agent.id
        )
        #expect(section == nil)
    }

    // MARK: - SystemPromptComposer integration

    @Test
    func composeChatContext_injectsPluginCreatorWhenCatalogEmpty() async {
        let agent = Agent(
            name: "Plugin Creator Composer Agent",
            autonomousExec: AutonomousExecConfig(enabled: true, pluginCreate: true)
        )
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        await ensurePluginCreatorSkill(enabled: true)

        let context = await SystemPromptComposer.composeChatContext(
            agentId: agent.id,
            executionMode: .sandbox
        )
        // Plugin creator section is appended as a `dynamic` block with a
        // known label — assert via the manifest entry rather than scraping
        // the rendered prose.
        let labels = context.manifest.sections.map(\.label)
        #expect(labels.contains("Plugin Creator"))
        #expect(context.prompt.contains("Sandbox Plugin Creator"))
    }

    @Test
    func composeChatContext_skipsPluginCreatorOutsideSandbox() async {
        let agent = Agent(
            name: "Plugin Creator Non-Sandbox Agent",
            autonomousExec: AutonomousExecConfig(enabled: false, pluginCreate: true)
        )
        AgentManager.shared.add(agent)
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let context = await SystemPromptComposer.composeChatContext(
            agentId: agent.id,
            executionMode: .none
        )
        let labels = context.manifest.sections.map(\.label)
        #expect(labels.contains("Plugin Creator") == false)
    }

    // MARK: - Helpers

    /// Force the built-in "Sandbox Plugin Creator" skill into the desired
    /// enabled state. Persists across tests; callers should restore.
    private func ensurePluginCreatorSkill(enabled: Bool) async {
        // The skill manager loads asynchronously on first access; wait
        // until the seeded skill is present before flipping its flag.
        for _ in 0 ..< 20 {
            if SkillManager.shared.skill(named: "Sandbox Plugin Creator") != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let skill = SkillManager.shared.skill(named: "Sandbox Plugin Creator") else {
            Issue.record("Sandbox Plugin Creator built-in skill missing")
            return
        }
        if skill.enabled == enabled { return }
        await SkillManager.shared.setEnabled(enabled, for: skill.id)
    }
}
