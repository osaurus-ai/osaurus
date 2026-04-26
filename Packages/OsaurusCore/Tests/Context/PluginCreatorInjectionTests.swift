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

        let section = await PreflightCapabilitySearch.pluginCreatorSkillSection(
            for: agent.id
        )
        #expect(section == nil)

        // restore the skill synchronously before returning so the persisted
        // disabled state doesn't leak into later tests
        await ensurePluginCreatorSkill(enabled: true)
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

        // Hold the cross-suite lock around the whole catalog snapshot →
        // composeChatContext → assertion → restore window. Without it,
        // a sibling suite (e.g. `MCPHTTPHandlerTests`) can register a
        // dynamic tool while `composeChatContext` is suspended, flipping
        // `dynamicCatalogIsEmpty()` to false and skipping the
        // "Plugin Creator" injection. `@Suite(.serialized)` only
        // serializes within this suite.
        await DynamicCatalogTestLock.shared.run {
            // The test premise is a dynamic catalog that is empty. In an
            // app-hosted xctest, `AppDelegate.applicationDidFinishLaunching`
            // may have already called `PluginManager.shared.loadAll()` and
            // registered plugin tools. Temporarily disable them (under a
            // temp config dir so the user's real enablement isn't touched),
            // then restore synchronously before returning so later tests
            // see their plugin tools enabled again.
            let (restore, cleanupTempDir) = await self.temporarilyEmptyDynamicCatalog()

            let context = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox
            )
            let labels = context.manifest.sections.map(\.label)
            #expect(labels.contains("Plugin Creator"))
            #expect(context.prompt.contains("Sandbox Plugin Creator"))

            await restore()
            cleanupTempDir()
        }
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
        // The skill manager loads asynchronously on first access; ensure
        // the seeded skill is loaded before flipping its flag.
        if SkillManager.shared.skill(named: "Sandbox Plugin Creator") == nil {
            await SkillManager.shared.refresh()
        }
        guard let skill = SkillManager.shared.skill(named: "Sandbox Plugin Creator") else {
            Issue.record("Sandbox Plugin Creator built-in skill missing")
            return
        }
        if skill.enabled == enabled { return }
        await SkillManager.shared.setEnabled(enabled, for: skill.id)
    }

    /// Snapshot the currently-enabled dynamic tools, disable them, and
    /// return closures that restore their enablement and clean up the temp
    /// config dir. Redirects `ToolConfigurationStore` persistence to a temp
    /// directory for the duration so the user's real `tools.json` is never
    /// touched — only `ToolRegistry.shared`'s in-memory configuration
    /// mutates.
    private func temporarilyEmptyDynamicCatalog() async -> (
        restore: @Sendable () async -> Void,
        cleanup: @Sendable () -> Void
    ) {
        let enabledNames = ToolRegistry.shared.listDynamicTools().map(\.name)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-plugin-creator-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let previousOverride = ToolConfigurationStore.overrideDirectory
        ToolConfigurationStore.overrideDirectory = tempDir
        for name in enabledNames {
            ToolRegistry.shared.setEnabled(false, for: name)
        }
        let namesCopy = enabledNames
        let restore: @Sendable () async -> Void = {
            await MainActor.run {
                for name in namesCopy {
                    ToolRegistry.shared.setEnabled(true, for: name)
                }
                ToolConfigurationStore.overrideDirectory = previousOverride
            }
        }
        let cleanup: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: tempDir)
        }
        return (restore, cleanup)
    }
}
