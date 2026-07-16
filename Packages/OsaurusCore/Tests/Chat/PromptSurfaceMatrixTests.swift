//
//  PromptSurfaceMatrixTests.swift
//
//  Scenario-level context audit for the production prompt composer. The
//  printed table is the before/after measurement surface for prompt tuning;
//  assertions pin feature gates so disabled capabilities cannot silently add
//  prompt sections or tool schemas.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PromptSurfaceMatrixTests {

    private struct Row {
        let name: String
        let context: ComposedContext

        var promptTokens: Int { context.manifest.totalEstimatedTokens }
        var toolTokens: Int { context.toolTokens }
        var totalTokens: Int { promptTokens + toolTokens }
        var toolNames: Set<String> { Set(context.tools.map(\.function.name)) }
        var sectionIds: Set<String> { Set(context.manifest.sections.map(\.id)) }
    }

    @Test("prompt and tool surface matrix")
    func promptAndToolSurfaceMatrix() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            try await DynamicCatalogTestLock.shared.run {
                let previousChannelDirectory = AgentChannelConfigurationStore.overrideDirectory
                let channelDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("prompt-surface-channels-\(UUID().uuidString)")
                AgentChannelConfigurationStore.overrideDirectory = channelDirectory
                defer {
                    AgentChannelConfigurationStore.overrideDirectory = previousChannelDirectory
                    try? FileManager.default.removeItem(at: channelDirectory)
                }

                let manager = AgentManager.shared
                let query = "Summarize the project status and identify next steps."

                let defaultAgent = Agent(
                    name: "PromptMatrix-Default",
                    systemPrompt: "Be concise and accurate.",
                    agentAddress: "test-prompt-matrix-default-\(UUID().uuidString)",
                    memoryEnabled: false
                )
                manager.add(defaultAgent)

                var enabledAgent = Agent(
                    name: "PromptMatrix-Enabled",
                    systemPrompt: "Be concise and accurate.",
                    agentAddress: "test-prompt-matrix-enabled-\(UUID().uuidString)",
                    memoryEnabled: false
                )
                enabledAgent.settings.renderChartEnabled = true
                enabledAgent.settings.speakEnabled = true
                enabledAgent.settings.searchMemoryEnabled = true
                enabledAgent.settings.selfSchedulingEnabled = true
                enabledAgent.settings.computerUseEnabled = true
                enabledAgent.settings.spawnDelegationEnabled = true
                enabledAgent.settings.spawnableAgentNames = ["Researcher"]
                manager.add(enabledAgent)

                let sandboxConfig = AutonomousExecConfig(enabled: true, pluginCreate: false)
                let sandboxAgent = Agent(
                    name: "PromptMatrix-Sandbox",
                    systemPrompt: "Be concise and accurate.",
                    agentAddress: "test-prompt-matrix-sandbox-\(UUID().uuidString)",
                    autonomousExec: sandboxConfig,
                    memoryEnabled: false
                )
                manager.add(sandboxAgent)
                BuiltinSandboxTools.register(
                    agentId: sandboxAgent.id.uuidString,
                    agentName: sandboxAgent.name,
                    config: sandboxConfig
                )

                let toolsOff = await SystemPromptComposer.composeChatContext(
                    agentId: defaultAgent.id,
                    executionMode: .none,
                    model: "google/gemma-4-4b-it",
                    query: query,
                    toolsDisabled: true
                )
                let trivial = await SystemPromptComposer.composeChatContext(
                    agentId: defaultAgent.id,
                    executionMode: .none,
                    model: "google/gemma-4-4b-it",
                    query: "hello"
                )
                let defaultContext = await SystemPromptComposer.composeChatContext(
                    agentId: defaultAgent.id,
                    executionMode: .none,
                    model: "google/gemma-4-4b-it",
                    query: query
                )
                let enabledContext = await SystemPromptComposer.composeChatContext(
                    agentId: enabledAgent.id,
                    executionMode: .none,
                    model: "google/gemma-4-4b-it",
                    query: query
                )
                let sandboxContext = await SystemPromptComposer.composeChatContext(
                    agentId: sandboxAgent.id,
                    executionMode: .sandbox(hostRead: nil),
                    model: "google/gemma-4-4b-it",
                    query: query
                )
                try AgentChannelConfigurationStore.save(
                    AgentChannelConfiguration(
                        connections: [
                            AgentChannelConnection(
                                id: "discord",
                                name: "Discord",
                                kind: .discord
                            )
                        ]
                    )
                )
                let channelsContext = await SystemPromptComposer.composeChatContext(
                    agentId: defaultAgent.id,
                    executionMode: .none,
                    model: "google/gemma-4-4b-it",
                    query: query
                )

                let rows = [
                    Row(name: "tools-off", context: toolsOff),
                    Row(name: "trivial-turn", context: trivial),
                    Row(name: "default-chat", context: defaultContext),
                    Row(name: "features-on", context: enabledContext),
                    Row(name: "sandbox", context: sandboxContext),
                    Row(name: "channels-on", context: channelsContext),
                ]
                print("[PromptSurfaceMatrix] scenario context cost")
                print("  scenario          prompt   tools   total  schemas  sections")
                for row in rows {
                    print(
                        String(
                            format: "  %-16@ %7d %7d %7d %8d %9d",
                            row.name as NSString,
                            row.promptTokens,
                            row.toolTokens,
                            row.totalTokens,
                            row.context.tools.count,
                            row.context.manifest.sections.count
                        )
                    )
                    let sections = row.context.manifest.sections.map {
                        "\($0.id)=\($0.estimatedTokens)"
                    }.joined(separator: ",")
                    let tools = row.context.tools.map(\.function.name).joined(separator: ",")
                    print("    sections: [\(sections)]")
                    print("    tools: [\(tools)]")
                    if let enabledManifest = row.context.enabledManifest {
                        print("    manifest:\n\(enabledManifest)")
                    }
                }

                let gatedTools: Set<String> = [
                    "render_chart", "speak", "search_memory",
                    "schedule_next_run", "cancel_next_run", "notify",
                    ComputerUseTool.toolName, "spawn_agent", "spawn_model", "image", "applescript",
                ]

                #expect(rows[0].context.tools.isEmpty)
                #expect(!rows[0].sectionIds.contains("grounding"))
                #expect(!rows[0].sectionIds.contains("agentLoopGuidance"))
                #expect(!rows[0].sectionIds.contains("capabilityNudge"))

                #expect(rows[1].context.tools.isEmpty)
                #expect(rows[1].toolTokens == 0)

                #expect(rows[2].toolNames.isDisjoint(with: gatedTools))
                #expect(rows[2].sectionIds.contains("computerUse") == false)
                #expect(rows[2].sectionIds.contains("spawn") == false)
                #expect(!(rows[2].context.enabledManifest ?? "").contains("agent_channel_"))

                for expected in [
                    "render_chart", "speak", "search_memory",
                    "schedule_next_run", "cancel_next_run", "notify",
                    ComputerUseTool.toolName, "spawn_agent",
                ] {
                    #expect(rows[3].toolNames.contains(expected), "missing enabled tool \(expected)")
                }
                #expect(rows[3].sectionIds.contains("computerUse"))
                #expect(rows[3].sectionIds.contains("spawn"))

                #expect(rows[4].sectionIds.contains("sandbox"))
                #expect(rows[4].toolNames.contains("sandbox_exec"))
                #expect(!rows[4].sectionIds.contains("skillsGovern"))
                #expect(rows[4].totalTokens > rows[2].totalTokens)

                #expect((rows[5].context.enabledManifest ?? "").contains("agent_channel_"))
                #expect(!rows[5].sectionIds.contains("skillsGovern"))

                ToolRegistry.shared.unregisterAllSandboxTools()
                _ = await manager.delete(id: defaultAgent.id)
                _ = await manager.delete(id: enabledAgent.id)
                _ = await manager.delete(id: sandboxAgent.id)
            }
        }
    }
}
