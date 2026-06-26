//
//  MCPToolEnablementPersistenceTests.swift
//  OsaurusCoreTests
//
//  Pins the per-tool enablement contract for MCP provider tools: a tool the
//  user disabled must STAY disabled across re-discovery (which runs on every
//  launch / autoConnect). The bug this guards against was an unconditional
//  re-enable in the discovery loop that overwrote the saved `false` on every
//  reconnect; the fix relies on `registerMCPTool` auto-enabling only on first
//  registration. The test drives the real registration path
//  (`registerDiscoveredTools`), so re-introducing a force-enable there fails.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct MCPToolEnablementPersistenceTests {

    /// Redirect tool-config persistence to a throwaway directory so the test
    /// never touches the user's real `tools.json`, then restore it.
    private func withTempToolConfig<T>(_ body: () throws -> T) rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-mcp-tool-enable-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let previous = ToolConfigurationStore.overrideDirectory
        ToolConfigurationStore.overrideDirectory = tmp
        defer {
            ToolConfigurationStore.overrideDirectory = previous
            try? FileManager.default.removeItem(at: tmp)
        }
        return try body()
    }

    private func makeTool(_ name: String) -> MCP.Tool {
        MCP.Tool(name: name, description: "test", inputSchema: ["type": "object"])
    }

    @Test
    func rediscoveryPreservesUserDisable() {
        withTempToolConfig {
            let manager = MCPProviderManager.shared
            let registry = ToolRegistry.shared
            // Unique provider/tool names so we never collide with real tools.
            let suffix = UUID().uuidString.prefix(8)
            let provider = MCPProvider(
                name: "enable_probe_\(suffix)",
                url: "https://example.invalid/mcp"
            )
            let mcpTools = [makeTool("alpha_\(suffix)"), makeTool("beta_\(suffix)")]

            // First discovery: both tools auto-enable on first registration.
            let registered = manager.registerDiscoveredTools(
                mcpTools,
                for: provider.id,
                provider: provider
            )
            let alpha = registered[0].name
            let beta = registered[1].name
            defer { registry.unregister(names: [alpha, beta]) }

            #expect(registry.isGlobalEnabled(alpha))
            #expect(registry.isGlobalEnabled(beta))

            // User disables one of them.
            registry.setEnabled(false, for: beta)
            #expect(registry.isGlobalEnabled(beta) == false)

            // Simulate quit + relaunch: the registry is torn down on disconnect
            // (tools unregistered) but the persisted enabled map survives —
            // `unregister` never clears config keys.
            registry.unregister(names: [alpha, beta])

            // Re-discovery on relaunch / autoConnect must NOT re-enable the tool
            // the user disabled, and must leave the other one enabled.
            _ = manager.registerDiscoveredTools(
                mcpTools,
                for: provider.id,
                provider: provider
            )
            #expect(registry.isGlobalEnabled(alpha))
            #expect(registry.isGlobalEnabled(beta) == false)
        }
    }
}
