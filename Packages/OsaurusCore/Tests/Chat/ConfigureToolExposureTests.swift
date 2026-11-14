//
//  ConfigureToolExposureTests.swift
//  OsaurusCoreTests
//
//  Composer contract for the Orchestrator and the Configurator after the
//  split:
//
//   * For the Default agent (`Agent.defaultId`), `resolveTools` returns
//     EXACTLY `orchestratorAllowedToolNames`: the routing surface (`status`,
//     `state`, the two handoffs, `run_workflow`, `clarify`). No configure tool,
//     no folder tool, and no worker-owned tool reaches it.
//   * The Configurator's schema is the consolidated configure surface
//     (`osaurus_help`, `osaurus_inspect`, `osaurus_config`) and nothing
//     that acts outside Osaurus.
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
    func defaultAgent_seesExactlyTheRoutingSurface() async {
        Self.ensureBootstrapped()
        // Isolate the global delegation snapshot: the default-agent schema
        // gates `spawn_*` on `SubagentConfigurationStore.snapshot()`, so a
        // parallel suite that populates the main-chat pool would otherwise
        // leak spawn tools into this exact-equality baseline.
        let lease = await acquireSubagentStoreSandbox("configure-exposure-exact")
        defer { lease.release() }
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        // `run_workflow` joins only when a workflow is visible to the Orchestrator.
        #expect(names == ToolRegistry.orchestratorAllowedToolNames.subtracting([RunWorkflowTool.toolName]))
        #expect(names.isDisjoint(with: ToolRegistry.configureToolNames))
    }

    /// Orchestrator invariant: the Default agent's schema never carries the
    /// worker-owned tools — artifact delivery belongs to spawned helpers
    /// (see `ToolRegistry.orchestratorExcludedToolNames`).
    @Test
    func defaultAgent_neverCarriesWorkerOwnedTools() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        for excluded in ToolRegistry.orchestratorExcludedToolNames {
            #expect(
                !names.contains(excluded),
                "worker-owned tool \(excluded) leaked into the orchestrator schema"
            )
        }
    }

    /// A bound working folder adds nothing to the Orchestrator's schema:
    /// folder work, reading included, belongs to workers.
    @Test
    func defaultAgent_folderAddsNoTools() async {
        Self.ensureBootstrapped()
        let lease = await acquireSubagentStoreSandbox("configure-exposure-folder")
        defer { lease.release() }
        let folder = FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/osaurus-configure-exposure-\(UUID().uuidString)"),
            projectType: .swift,
            tree: "./\nREADME.md",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false
        )
        FolderToolManager.shared.ensureFolderToolsRegistered()
        defer { FolderToolManager.shared._unregisterAllForTesting() }
        let tools = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(agentId: Agent.defaultId),
            executionMode: .hostFolder(folder)
        )
        let names = Set(tools.map { $0.function.name })
        let folderTools = names.intersection(
            ToolRegistry.coreWorkspaceToolNames.union(ToolRegistry.hostFolderExtraToolNames)
        )
        #expect(folderTools.isEmpty, "got \(folderTools.sorted())")
    }

    /// Osaurus itself is the Configurator's: the Orchestrator carries the
    /// handoff, never a configure tool.
    @Test
    func defaultAgent_routesConfigurationThroughTheHandoff() async {
        Self.ensureBootstrapped()
        let tools = SystemPromptComposer.resolveTools(
            snapshot: Self.makeSnapshot(agentId: Agent.defaultId),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains(ConfiguratorHandoffTool.toolName))
        for configure in ToolRegistry.configureToolNames {
            #expect(!names.contains(configure), "\(configure) leaked into the Orchestrator schema")
        }
    }

    @Test
    func configurator_carriesTheConsolidatedConfigureSurfaceOnly() {
        Self.ensureBootstrapped()
        let names = ToolRegistry.configuratorAllowedToolNames
        for name in ["osaurus_help", "osaurus_inspect", "osaurus_config"] {
            #expect(names.contains(name), "Configurator schema misses \(name)")
        }
        for write in ToolRegistry.configureWriteToolNames {
            #expect(names.contains(write), "consolidated write \(write) missing from the Configurator")
        }
        for legacy in [
            "osaurus_provider", "osaurus_model", "osaurus_mcp",
            "osaurus_search", "osaurus_plugin", "osaurus_schedule",
            "osaurus_watcher", "osaurus_agent", "osaurus_settings",
        ] {
            #expect(!names.contains(legacy), "legacy write tool \(legacy) is back")
        }
        #expect(names.isDisjoint(with: ToolRegistry.orchestratorRoutingToolNames))
        #expect(!names.contains("spawn_agent"))
        #expect(!names.contains("file_read"))
    }

    @Test
    func configuratorChat_getsExactlyTheAgentCreationSurface() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.configuratorId)
        let tools = SystemPromptComposer.resolveTools(snapshot: snapshot, executionMode: .none)
        let names = Set(tools.map { $0.function.name })
        #expect(names.isSubset(of: ToolRegistry.configuratorCreationToolNames), "\(names.sorted())")
        #expect(names.contains(AgentDraftTool.toolName))
        #expect(!names.contains("osaurus_config"), "a New Agent chat must never write config directly")
    }

    @Test
    func agentDraft_neverReachesAnyOtherAgent() async {
        Self.ensureBootstrapped()
        for agentId in [Agent.defaultId, Agent.architectId, UUID()] {
            let tools = SystemPromptComposer.resolveTools(
                snapshot: Self.makeSnapshot(agentId: agentId), executionMode: .none)
            #expect(!tools.contains { $0.function.name == AgentDraftTool.toolName }, "\(agentId)")
        }
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
        // osaurus_inspect lives in ToolRegistry as a built-in for
        // indexing, but the composer strips it from custom-agent
        // schemas. Verifying this so future "make it globally
        // available" changes are forced to come through a review.
        #expect(!names.contains("osaurus_inspect"))
        // The pre-consolidation read names must never come back either.
        #expect(!names.contains("osaurus_status"))
        #expect(!names.contains("osaurus_list"))
        #expect(!names.contains("osaurus_describe"))
    }
}
