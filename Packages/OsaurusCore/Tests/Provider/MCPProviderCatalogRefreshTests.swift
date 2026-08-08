//
//  MCPProviderCatalogRefreshTests.swift
//  OsaurusCoreTests
//
//  Regression coverage for replacing live MCP catalogs and deciding when a
//  successful Settings probe may refresh the executable provider connection.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct MCPProviderCatalogRefreshTests {
    private enum FixtureError: Error {
        case discoveryFailed
    }

    private func makeProvider(enabled: Bool = true) -> MCPProvider {
        MCPProvider(
            name: "catalog_refresh_\(UUID().uuidString.prefix(8))",
            url: "https://example.invalid/mcp",
            enabled: enabled,
            customHeaders: ["X-Test": "value"],
            streamingEnabled: true,
            discoveryTimeout: 9,
            toolCallTimeout: 12,
            autoConnect: false,
            authType: .none
        )
    }

    private func makeTool(_ name: String, propertyType: String) -> MCP.Tool {
        switch propertyType {
        case "integer":
            return MCP.Tool(
                name: name,
                description: "Catalog refresh fixture",
                inputSchema: [
                    "type": "object",
                    "properties": ["value": ["type": "integer"]],
                    "required": ["value"],
                ]
            )
        case "boolean":
            return MCP.Tool(
                name: name,
                description: "Catalog refresh fixture",
                inputSchema: [
                    "type": "object",
                    "properties": ["value": ["type": "boolean"]],
                    "required": ["value"],
                ]
            )
        default:
            return MCP.Tool(
                name: name,
                description: "Catalog refresh fixture",
                inputSchema: [
                    "type": "object",
                    "properties": ["value": ["type": "string"]],
                    "required": ["value"],
                ]
            )
        }
    }

    @Test
    func rediscoveryReplacesSchemasAndRemovesMissingTools() async {
        let manager = MCPProviderManager.shared
        let registry = ToolRegistry.shared
        let provider = makeProvider()

        let first = manager.replaceDiscoveredTools(
            [
                makeTool("kept", propertyType: "string"),
                makeTool("removed", propertyType: "string"),
            ],
            for: provider.id,
            provider: provider
        )
        let keptName = first[0].name
        let removedName = first[1].name
        let oldParameters = registry.parametersForTool(name: keptName)

        let replacement = manager.replaceDiscoveredTools(
            [
                makeTool("kept", propertyType: "integer"),
                makeTool("added", propertyType: "boolean"),
            ],
            for: provider.id,
            provider: provider
        )

        #expect(replacement[0].name == keptName)
        #expect(registry.parametersForTool(name: keptName) == replacement[0].parameters)
        #expect(registry.parametersForTool(name: keptName) != oldParameters)
        #expect(registry.entry(named: removedName) == nil)
        #expect(registry.entry(named: replacement[1].name) != nil)

        manager.replaceDiscoveredTools([], for: provider.id, provider: provider)
    }

    @Test
    func failedDiscoveryKeepsPreviousCatalog() async {
        let manager = MCPProviderManager.shared
        let registry = ToolRegistry.shared
        let provider = makeProvider()
        let first = manager.replaceDiscoveredTools(
            [makeTool("stable", propertyType: "string")],
            for: provider.id,
            provider: provider
        )
        let stableName = first[0].name
        let stableParameters = first[0].parameters

        var didThrow = false
        do {
            try await manager.refreshDiscoveredTools(for: provider.id, provider: provider) {
                throw FixtureError.discoveryFailed
            }
        } catch FixtureError.discoveryFailed {
            didThrow = true
        } catch {
            Issue.record("Unexpected refresh error: \(error)")
        }

        #expect(didThrow)
        #expect(registry.parametersForTool(name: stableName) == stableParameters)

        manager.replaceDiscoveredTools([], for: provider.id, provider: provider)
    }

    @Test
    func probeRefreshPolicyOnlyAcceptsUnchangedSavedEnabledProvider() {
        let saved = makeProvider()

        #expect(
            MCPProviderCatalogRefreshPolicy.shouldRefresh(
                savedProvider: saved,
                configuredProvider: saved,
                hasCredentialEdits: false
            )
        )
        #expect(
            !MCPProviderCatalogRefreshPolicy.shouldRefresh(
                savedProvider: nil,
                configuredProvider: saved,
                hasCredentialEdits: false
            )
        )

        var edited = saved
        edited.url = "https://edited.example.invalid/mcp"
        #expect(
            !MCPProviderCatalogRefreshPolicy.shouldRefresh(
                savedProvider: saved,
                configuredProvider: edited,
                hasCredentialEdits: false
            )
        )
        #expect(
            !MCPProviderCatalogRefreshPolicy.shouldRefresh(
                savedProvider: saved,
                configuredProvider: saved,
                hasCredentialEdits: true
            )
        )

        var disabled = saved
        disabled.enabled = false
        #expect(
            !MCPProviderCatalogRefreshPolicy.shouldRefresh(
                savedProvider: disabled,
                configuredProvider: disabled,
                hasCredentialEdits: false
            )
        )
    }
}
