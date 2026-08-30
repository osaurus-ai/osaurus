//
//  ConfigureToolExposureTests.swift
//  OsaurusCoreTests
//
//  Composer contract for the Default (configuration) agent's tool surface
//  after the consolidation:
//
//   * For the Default agent (`Agent.defaultId`), `resolveTools` returns
//     EXACTLY `orchestratorAllowedToolNames` — the consolidated configure
//     surface (the `osaurus_inspect` read
//     + the single declarative `osaurus_config` write) plus the three
//     agent-loop tools, `get_current_time`, and the native search pair
//     (`web_search` / `search_and_extract`) for quick lookups. Worker-owned
//     tools (`share_artifact`) are NEVER present — workers deliver their own
//     artifacts. The writes load
//     DIRECTLY (no `capabilities_load` step), and the
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
        #expect(names == ToolRegistry.orchestratorAllowedToolNames)
        // Structural: the allowed set is the configure surface (reads +
        // writes) plus exactly the three agent-loop tools,
        // `get_current_time`, and the two native search tools, with no
        // overlap.
        #expect(names.count == ToolRegistry.configureToolNames.count + 6)
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
        // And the consolidated generic read.
        #expect(names.contains("osaurus_inspect"))
    }

    @Test
    func defaultAgent_includesTheDeclarativeWrite() async {
        Self.ensureBootstrapped()
        let snapshot = Self.makeSnapshot(agentId: Agent.defaultId)
        let tools = SystemPromptComposer.resolveTools(
            snapshot: snapshot,
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(
            names.contains("osaurus_config"),
            "expected the declarative write tool; got \(names.sorted())"
        )
        // The pre-consolidation per-domain write tools are gone.
        for legacy in [
            "osaurus_provider", "osaurus_model", "osaurus_mcp",
            "osaurus_search", "osaurus_plugin", "osaurus_schedule",
            "osaurus_watcher", "osaurus_agent", "osaurus_settings",
        ] {
            #expect(!names.contains(legacy), "legacy write tool \(legacy) leaked into the schema")
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
