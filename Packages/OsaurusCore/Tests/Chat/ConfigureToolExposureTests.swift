//
//  ConfigureToolExposureTests.swift
//  OsaurusCoreTests
//
//  Composer contract for the Default (configuration) agent's tool surface
//  after the consolidation:
//
//   * For the Default agent (`Agent.defaultId`), `resolveTools` returns
//     EXACTLY `defaultAgentAllowedToolNames` — the consolidated configure
//     surface (`osaurus_status` / `osaurus_list` / `osaurus_describe` reads
//     + the per-domain `osaurus_*` write tools) plus the three agent-loop
//     tools. The writes load DIRECTLY (no `capabilities_load` step), and the
//     capability-search gateway (`capabilities_discover` /
//     `capabilities_load`) is NOT present for the Default agent.
//   * For every other agent, every configure tool (reads + writes) is
//     stripped from the resolved schema, even when a registration path leaks
//     one into the always-loaded surface.
//
//  Tests build an `AgentConfigSnapshot` directly so we can pin the agent id
//  deterministically without provisioning custom agents through
//  `AgentManager`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ConfigureToolExposureTests {

    private static func makeSnapshot(agentId: UUID) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: false,
            memoryDisabled: false,
            autonomousConfig: nil,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false
        )
    }

    private static func ensureBootstrapped() {
        ConfigurationDomainBootstrap.registerBuiltIns()
    }

    @Test
    func defaultAgent_seesExactlyConsolidatedConfigureSurface() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names == ToolRegistry.defaultAgentAllowedToolNames)
        // Structural: the allowed set is the configure surface (reads +
        // writes) plus exactly the three agent-loop tools, with no overlap.
        #expect(names.count == ToolRegistry.configureToolNames.count + 3)
    }

    @Test
    func defaultAgent_includesEveryConsolidatedWriteDirectly() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        // The consolidated writes are now loaded DIRECTLY — no capability
        // search round-trip. Each per-domain tool must be in the schema.
        for write in ToolRegistry.configureWriteToolNames {
            #expect(names.contains(write), "consolidated write \(write) missing from default-agent schema")
        }
        // And the three generic reads.
        #expect(names.contains("osaurus_status"))
        #expect(names.contains("osaurus_list"))
        #expect(names.contains("osaurus_describe"))
    }

    @Test
    func defaultAgent_includesTheConsolidatedSixWrites() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        let expectedWrites: Set<String> = [
            "osaurus_provider", "osaurus_model", "osaurus_mcp",
            "osaurus_plugin", "osaurus_schedule", "osaurus_agent",
        ]
        #expect(
            expectedWrites.isSubset(of: names),
            "expected the six consolidated write tools; got \(names.sorted())"
        )
        // The pre-consolidation write set is gone — no `osaurus_*_<verb>`.
        #expect(!names.contains("osaurus_provider_add"))
        #expect(!names.contains("osaurus_model_download"))
        #expect(!names.contains("osaurus_schedule_create"))
    }

    @Test
    func defaultAgent_excludesCapabilitySearchGateway() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        // The Default agent no longer uses capability search — it loads its
        // configure tools directly. Those tools stay available to custom
        // agents, but must not appear in the Default agent's schema.
        #expect(!names.contains("capabilities_discover"))
        #expect(!names.contains("capabilities_load"))
    }

    @Test
    func defaultAgent_excludesNonConfigureCapabilities() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        // Hard isolation: folder / sandbox / db / chart / speak / memory /
        // scheduler / computer-use families never reach the Default agent,
        // regardless of what else is registered globally.
        for forbidden in [
            "file_read", "file_write", "sandbox_exec", "db_query",
            "render_chart", "speak", "search_memory", "schedule_next_run",
            "computer_use",
        ] {
            #expect(!names.contains(forbidden), "\(forbidden) leaked into default-agent schema")
        }
    }

    @Test
    func customAgent_isStrippedOfEveryConfigureTool() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: UUID())
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        for configure in ToolRegistry.configureToolNames {
            #expect(
                !names.contains(configure),
                "configure tool \(configure) leaked into non-default-agent schema"
            )
        }
    }

    @Test
    func customAgent_excludesReadsTooSinceTheyAreDefaultAgentOnly() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: UUID())
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        // osaurus_status / osaurus_list / osaurus_describe live in
        // ToolRegistry as built-ins for indexing, but the composer
        // strips them from custom-agent schemas. Verifying this so
        // future "make them globally available" changes are forced
        // to come through a review.
        #expect(!names.contains("osaurus_status"))
        #expect(!names.contains("osaurus_list"))
        #expect(!names.contains("osaurus_describe"))
    }
}
