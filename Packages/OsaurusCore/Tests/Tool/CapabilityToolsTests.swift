//
//  CapabilityToolsTests.swift
//  osaurus
//
//  Tests for capabilities_search, capabilities_load, and CapabilityLoadBuffer.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - CapabilityLoadBuffer

struct CapabilityLoadBufferTests {

    @Test func drainReturnsAndClearsPendingTools() async {
        let buffer = CapabilityLoadBuffer()
        let tool1 = Tool(
            type: "function",
            function: ToolFunction(name: "test_tool_1", description: "A test", parameters: nil)
        )
        let tool2 = Tool(
            type: "function",
            function: ToolFunction(name: "test_tool_2", description: "Another test", parameters: nil)
        )

        await buffer.add(tool1)
        await buffer.add(tool2)

        let drained = await buffer.drain()
        #expect(drained.count == 2)
        #expect(drained[0].function.name == "test_tool_1")
        #expect(drained[1].function.name == "test_tool_2")

        let empty = await buffer.drain()
        #expect(empty.isEmpty)
    }

    @Test func drainOnEmptyBufferReturnsEmpty() async {
        let buffer = CapabilityLoadBuffer()
        let result = await buffer.drain()
        #expect(result.isEmpty)
    }
}

// MARK: - CapabilitiesSearchTool

@Suite(.serialized)
struct CapabilitiesSearchToolTests {

    @Test func rejectsEmptyQueries() async throws {
        let tool = CapabilitiesSearchTool()
        let result = try await tool.execute(argumentsJSON: "{\"queries\": []}")
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("queries"))
    }

    @Test func rejectsMissingQueries() async throws {
        let tool = CapabilitiesSearchTool()
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("queries"))
    }

    @Test @MainActor
    func registryAcceptsLegacySingularQueryAlias() async throws {
        let result = try await ToolRegistry.shared.execute(
            name: "capabilities_search",
            argumentsJSON: "{\"query\": \"zzz_capability_alias_probe_\(UUID().uuidString)\"}"
        )
        #expect(!ToolEnvelope.isError(result))
        #expect(result.contains("No capabilities found") || result.contains("Found"))
    }

    @Test @MainActor
    func registryAcceptsStringifiedQueriesFromSmallModels() async throws {
        let result = try await ToolRegistry.shared.execute(
            name: "capabilities_search",
            argumentsJSON:
                "{\"queries\": \"[<|\\\"|>zzz_capability_string_probe_\(UUID().uuidString)<|\\\"|>]\"}"
        )
        #expect(!ToolEnvelope.isError(result))
        #expect(result.contains("No capabilities found") || result.contains("Found"))
    }

    @Test func returnsNoMatchMessage() async throws {
        let tool = CapabilitiesSearchTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"queries\": [\"zzz_completely_nonexistent_capability_xyz\"]}"
        )
        #expect(result.contains("No capabilities found") || result.contains("capability"))
    }

    @Test @MainActor
    func searchFiltersDynamicToolsOutsideAgentGrant() async throws {
        try await StoragePathsTestLock.shared.run {
            try await DynamicCatalogTestLock.shared.run {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-capability-search-root-\(UUID().uuidString)",
                    isDirectory: true
                )
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let previousRoot = OsaurusPaths.overrideRoot
                OsaurusPaths.overrideRoot = root
                AgentManager.shared.refresh()
                defer {
                    OsaurusPaths.overrideRoot = previousRoot
                    AgentManager.shared.refresh()
                    try? FileManager.default.removeItem(at: root)
                }

                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-capability-search-grant-\(UUID().uuidString)",
                    isDirectory: true
                )
                let previousOverride = ToolConfigurationStore.overrideDirectory
                ToolConfigurationStore.overrideDirectory = tempDir
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { ToolConfigurationStore.overrideDirectory = previousOverride }

                let dbWasOpen = ToolDatabase.shared.isOpen
                if !dbWasOpen {
                    try ToolDatabase.shared.openInMemory()
                }
                defer {
                    try? ToolDatabase.shared.deleteEntry(id: CapabilityPolicyFixtureTool.allowedName)
                    try? ToolDatabase.shared.deleteEntry(id: CapabilityPolicyFixtureTool.deniedName)
                    if !dbWasOpen {
                        ToolDatabase.shared.close()
                    }
                }

                let allowed = CapabilityPolicyFixtureTool(
                    name: CapabilityPolicyFixtureTool.allowedName,
                    description: "Search the web for current headlines and online results"
                )
                let denied = CapabilityPolicyFixtureTool(
                    name: CapabilityPolicyFixtureTool.deniedName,
                    description: "Search the web for current headlines and online results"
                )
                ToolRegistry.shared.registerPluginTool(allowed)
                ToolRegistry.shared.registerPluginTool(denied)
                ToolRegistry.shared.setEnabled(true, for: allowed.name)
                ToolRegistry.shared.setEnabled(true, for: denied.name)
                defer { ToolRegistry.shared.unregister(names: [allowed.name, denied.name]) }

                await ToolIndexService.shared.onToolRegistered(
                    name: allowed.name,
                    description: allowed.description,
                    runtime: .native,
                    tokenCount: 12,
                    parameters: allowed.parameters
                )
                await ToolIndexService.shared.onToolRegistered(
                    name: denied.name,
                    description: denied.description,
                    runtime: .native,
                    tokenCount: 12,
                    parameters: denied.parameters
                )
                // Seed AgentManager's async known-tool snapshot before the fixture
                // agent exists, so unrelated parallel tests cannot auto-grow its
                // explicit allowlist with the denied fixture tool.
                NotificationCenter.default.post(name: .toolsListChanged, object: nil)
                await Task.yield()

                let agent = Agent(
                    name: "CapabilitySearchGrant-\(UUID().uuidString.prefix(6))",
                    agentAddress: "capability-search-grant-\(UUID().uuidString)",
                    manualToolNames: [allowed.name]
                )
                AgentManager.shared.add(agent)
                AgentManager.shared.updateEnabledToolNames([allowed.name], for: agent.id)
                #expect(AgentManager.shared.effectiveEnabledToolNames(for: agent.id) == [allowed.name])

                let (rawResults, diagnostic) = await ToolSearchService.shared.searchHybridWithDiagnostic(
                    query: "current headline web search",
                    topK: 5,
                    minFusedScore: CapabilitySearch.minimumFusedScore,
                    allowedNames: [allowed.name]
                )
                #expect(rawResults.contains { $0.entry.name == allowed.name })
                #expect(!rawResults.contains { $0.entry.name == denied.name })
                #expect(diagnostic.filteredByAllowlist.count == 1)
                #expect(diagnostic.filteredByAllowlist.contains(denied.name))

                let tool = CapabilitiesSearchTool(agentId: agent.id)
                let result = try await tool.execute(
                    argumentsJSON: "{\"queries\": [\"current headline web search\"]}"
                )
                #expect(result.contains(allowed.name))
                #expect(!result.contains(denied.name))

                AgentManager.shared.setActiveAgent(agent.id)
                defer { AgentManager.shared.setActiveAgent(Agent.defaultId) }
                let unscopedTool = CapabilitiesSearchTool()
                let unscopedResult = try await unscopedTool.execute(
                    argumentsJSON: "{\"queries\": [\"current headline web search\"]}"
                )
                #expect(unscopedResult.contains(allowed.name))
                #expect(
                    unscopedResult.contains(denied.name),
                    "Direct capabilities_search calls without explicit/task-local agent context must keep global-enabled results"
                )

                _ = await AgentManager.shared.delete(id: agent.id)
            }
        }
    }
}

// MARK: - CapabilitiesLoadTool

@Suite(.serialized)
struct CapabilitiesLoadToolTests {

    @Test func rejectsEmptyIds() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{\"ids\": []}")
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("ids"))
    }

    @Test func rejectsMissingIds() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("ids"))
    }

    @Test func handlesInvalidIdFormat() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{\"ids\": [\"no-slash\"]}")
        #expect(result.contains("Warning"))
        #expect(result.contains("Invalid ID format"))
    }

    @Test func handlesUnknownTypePrefix() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{\"ids\": [\"widget/abc\"]}")
        #expect(result.contains("Warning"))
        #expect(result.contains("Unknown type"))
    }

    @Test func methodNotFoundReturnsError() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"method/nonexistent-method-id\"]}"
        )
        #expect(result.contains("Error") || result.contains("not found"))
    }

    @Test func toolNotFoundReturnsError() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"tool/zzz_nonexistent_tool\"]}"
        )
        #expect(result.contains("Error") || result.contains("not found"))
    }

    @Test func skillNotFoundReturnsError() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"skill/zzz_nonexistent_skill\"]}"
        )
        #expect(result.contains("Error") || result.contains("not found"))
    }

    @Test func dispatchesByTypePrefix() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: """
                {"ids": ["method/fake-m", "tool/fake-t", "skill/fake-s"]}
                """
        )
        #expect(result.contains("method") || result.contains("Method"))
        #expect(result.contains("tool") || result.contains("Tool"))
        #expect(result.contains("skill") || result.contains("Skill"))
    }

    @Test func toolLoadBuffersSpec() async throws {
        await MainActor.run {
            ToolRegistry.shared.setEnabled(true, for: "capabilities_search")
        }

        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"tool/capabilities_search\"]}"
        )

        #expect(result.contains("loaded") || result.contains("available"))

        let buffered = await CapabilityLoadBuffer.shared.drain()
        #expect(buffered.contains(where: { $0.function.name == "capabilities_search" }))
    }

    @Test @MainActor
    func toolLoadRejectsDynamicToolOutsideAgentGrant() async throws {
        try await StoragePathsTestLock.shared.run {
            try await DynamicCatalogTestLock.shared.run {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-capability-load-root-\(UUID().uuidString)",
                    isDirectory: true
                )
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let previousRoot = OsaurusPaths.overrideRoot
                OsaurusPaths.overrideRoot = root
                AgentManager.shared.refresh()
                defer {
                    OsaurusPaths.overrideRoot = previousRoot
                    AgentManager.shared.refresh()
                    try? FileManager.default.removeItem(at: root)
                }

                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-capability-load-grant-\(UUID().uuidString)",
                    isDirectory: true
                )
                let previousOverride = ToolConfigurationStore.overrideDirectory
                ToolConfigurationStore.overrideDirectory = tempDir
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { ToolConfigurationStore.overrideDirectory = previousOverride }

                let denied = CapabilityPolicyFixtureTool(
                    name: CapabilityPolicyFixtureTool.deniedName,
                    description: "Search the web for current headlines and online results"
                )
                ToolRegistry.shared.registerPluginTool(denied)
                ToolRegistry.shared.setEnabled(true, for: denied.name)
                defer { ToolRegistry.shared.unregister(names: [denied.name]) }

                let agent = Agent(
                    name: "CapabilityLoadGrant-\(UUID().uuidString.prefix(6))",
                    agentAddress: "capability-load-grant-\(UUID().uuidString)",
                    manualToolNames: []
                )
                AgentManager.shared.add(agent)
                _ = await CapabilityLoadBuffer.shared.drain()

                let tool = CapabilitiesLoadTool()
                let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                    try await tool.execute(
                        argumentsJSON: "{\"ids\": [\"tool/\(denied.name)\"]}"
                    )
                }
                #expect(result.contains("not enabled for this agent"))
                let buffered = await CapabilityLoadBuffer.shared.drain()
                #expect(!buffered.contains(where: { $0.function.name == denied.name }))

                _ = await AgentManager.shared.delete(id: agent.id)
            }
        }
    }
}

private struct CapabilityPolicyFixtureTool: OsaurusTool {
    static let allowedName = "lane_b_allowed_search_tool"
    static let deniedName = "lane_b_denied_search_tool"

    let name: String
    let description: String
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Search query for current web results"),
            ])
        ]),
        "required": .array([.string("query")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        argumentsJSON
    }
}
