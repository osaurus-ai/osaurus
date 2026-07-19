//
//  MCPCapabilityLoadFlowTests.swift
//  OsaurusCoreTests
//
//  Pins the custom-agent → remote-MCP-tool path end to end at the seams a
//  live run crosses, WITHOUT a live server:
//
//   1. a freshly discovered MCP tool is deliberately absent from the
//      turn-1 always-loaded schema (lazy loading is the design — eagerly
//      exposing every remote schema would regress context size and the
//      KV-stable prefix);
//   2. `capabilities_load tool/<exposed_name>` succeeds for an agent whose
//      capability grant includes the tool, and the load RESULT carries the
//      full callable schema (deferred-schema contract: the frozen `<tools>`
//      block is never rewritten mid-run, so the model must be able to read
//      the schema from the tool result and call the tool by name);
//   3. the buffered spec drains and `ToolExecutionScope.activate` makes
//      exactly that tool callable — not its unloaded siblings;
//   4. an agent whose grant EXCLUDES the tool is refused with the
//      agent-scope availability diagnostic (the "connected but the agent
//      still can't call it" configuration users hit).
//
//  Together these pin why "the agent doesn't call existing tools" is a
//  selection/grant problem, not an MCP transport problem — and they fail
//  if the lazy-load contract, the schema-in-result delivery, or the grant
//  gating regresses.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct MCPCapabilityLoadFlowTests {

    @Test
    func discoveredMCPToolLoadsAndActivatesForGrantedAgent() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFixture { fixture in
                let exposedName = fixture.exposedName

                // (1) Lazy by design: never in the turn-1 baseline schema.
                let baseline = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)
                #expect(!baseline.contains(where: { $0.function.name == exposedName }))

                // Agent whose capability grant includes the MCP tool. Lives
                // in the fixture's temp root, so teardown's refresh drops it.
                let agent = Agent(
                    name: "MCPFlow-\(UUID().uuidString.prefix(6))",
                    agentAddress: "mcp-flow-\(UUID().uuidString)",
                    manualToolNames: [exposedName]
                )
                AgentManager.shared.add(agent)
                _ = await CapabilityLoadBuffer.shared.drain()

                // (2) Load by manifest id; schema must ride in the result.
                let load = CapabilitiesLoadTool()
                let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                    try await load.execute(
                        argumentsJSON: "{\"ids\": [\"tool/\(exposedName)\"]}"
                    )
                }
                #expect(result.contains("callable NOW"))
                #expect(result.contains("Schema for `\(exposedName)`"))
                // The MCP argument contract survives into the delivered schema.
                #expect(result.contains("query"))

                // (3) Drain + activate: the run's execution scope now permits
                // exactly the loaded tool.
                let buffered = await CapabilityLoadBuffer.shared.drain()
                #expect(buffered.contains(where: { $0.function.name == exposedName }))

                let scope = ToolExecutionScope(exposed: [
                    Tool(
                        type: "function",
                        function: ToolFunction(
                            name: "capabilities_load", description: "load", parameters: nil
                        )
                    )
                ])
                #expect(!scope.permits(exposedName))
                scope.activate(buffered.map { $0.function.name })
                #expect(scope.permits(exposedName))
                #expect(!scope.permits(fixture.siblingExposedName))
            }
        }
    }

    @Test
    func loadRefusesMCPToolOutsideAgentGrant() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withFixture { fixture in
                // Grant deliberately excludes the MCP tool. Lives in the
                // fixture's temp root, so teardown's refresh drops it.
                let agent = Agent(
                    name: "MCPDenied-\(UUID().uuidString.prefix(6))",
                    agentAddress: "mcp-denied-\(UUID().uuidString)",
                    manualToolNames: []
                )
                AgentManager.shared.add(agent)
                _ = await CapabilityLoadBuffer.shared.drain()

                let load = CapabilitiesLoadTool()
                let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                    try await load.execute(
                        argumentsJSON: "{\"ids\": [\"tool/\(fixture.exposedName)\"]}"
                    )
                }
                #expect(result.contains("not enabled for this agent"))

                let buffered = await CapabilityLoadBuffer.shared.drain()
                #expect(!buffered.contains(where: { $0.function.name == fixture.exposedName }))
            }
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let exposedName: String
        let siblingExposedName: String
    }

    /// Register two fake remote MCP tools through the REAL discovery path
    /// (`registerDiscoveredTools`, provider-prefixed exposed names) against
    /// throwaway agent + tool-config storage, run `body`, then tear down.
    private func withFixture(
        _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-mcp-flow-root-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = OsaurusPaths.overrideRoot
        OsaurusPaths.overrideRoot = root
        AgentManager.shared.refresh()

        let toolConfigDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-mcp-flow-toolconfig-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: toolConfigDir, withIntermediateDirectories: true)
        let previousToolConfig = ToolConfigurationStore.overrideDirectory
        ToolConfigurationStore.overrideDirectory = toolConfigDir

        let suffix = UUID().uuidString.prefix(8)
        let provider = MCPProvider(
            name: "flow_probe_\(suffix)",
            url: "https://example.invalid/mcp"
        )
        let mcpTools = [
            MCP.Tool(
                name: "search_\(suffix)",
                description: "Search the remote fixture index",
                inputSchema: [
                    "type": "object",
                    "properties": ["query": ["type": "string"]],
                    "required": ["query"],
                ]
            ),
            MCP.Tool(
                name: "sibling_\(suffix)",
                description: "Unloaded sibling fixture tool",
                inputSchema: ["type": "object"]
            ),
        ]
        let registered = MCPProviderManager.shared.registerDiscoveredTools(
            mcpTools,
            for: provider.id,
            provider: provider
        )
        let names = registered.map(\.name)

        defer {
            ToolRegistry.shared.unregister(names: names)
            ToolConfigurationStore.overrideDirectory = previousToolConfig
            try? FileManager.default.removeItem(at: toolConfigDir)
            OsaurusPaths.overrideRoot = previousRoot
            AgentManager.shared.refresh()
            try? FileManager.default.removeItem(at: root)
        }

        try await body(
            Fixture(exposedName: names[0], siblingExposedName: names[1])
        )
    }
}
