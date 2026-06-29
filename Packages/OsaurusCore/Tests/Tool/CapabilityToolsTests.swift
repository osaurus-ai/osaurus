//
//  CapabilityToolsTests.swift
//  osaurus
//
//  Tests for capabilities_discover, capabilities_load, and CapabilityLoadBuffer.
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
            function: ToolFunction(
                name: "test_tool_1",
                description: "A test",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            )
        )
        let tool2 = Tool(
            type: "function",
            function: ToolFunction(
                name: "test_tool_2",
                description: "Another test",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            )
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

    @Test func duplicateAddsAreIdempotentWithinOneTurn() async {
        let buffer = CapabilityLoadBuffer()
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "duplicate_loaded_tool",
                description: "A test",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            )
        )

        await buffer.add(tool)
        await buffer.add(tool)

        let drained = await buffer.drain()
        #expect(drained.map { $0.function.name } == ["duplicate_loaded_tool"])
        #expect(await buffer.drain().isEmpty)
    }

    @Test func noArgumentDynamicSchemaBuffersAsEmptyObjectTool() async {
        let buffer = CapabilityLoadBuffer()
        let noArgumentTool = Tool(
            type: "function",
            function: ToolFunction(
                name: "no_argument_loaded_tool",
                description: "A test",
                parameters: nil
            )
        )

        let diagnostic = await buffer.add(noArgumentTool)

        #expect(diagnostic == nil)
        let drained = await buffer.drain()
        #expect(drained.map { $0.function.name } == ["no_argument_loaded_tool"])
        #expect(drained.first?.function.parameters == nil)
    }

    @Test func malformedDynamicSchemaFailsClosedBeforeBuffering() async {
        let buffer = CapabilityLoadBuffer()
        let malformed = Tool(
            type: "function",
            function: ToolFunction(
                name: "malformed_schema_tool",
                description: "A test",
                parameters: .string("not an object")
            )
        )

        let diagnostic = await buffer.add(malformed)

        #expect(diagnostic?.kind == .invalidArgs)
        #expect(diagnostic?.field == "parameters")
        #expect(await buffer.drain().isEmpty)
    }
}

// MARK: - CapabilitiesDiscoverTool

@Suite(.serialized)
struct CapabilitiesDiscoverToolTests {

    @Test func rejectsEmptyQueries() async throws {
        let tool = CapabilitiesDiscoverTool()
        let result = try await tool.execute(argumentsJSON: "{\"queries\": []}")
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("queries"))
    }

    @Test func rejectsMissingQueries() async throws {
        let tool = CapabilitiesDiscoverTool()
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("queries"))
    }

    @Test @MainActor
    func registryAcceptsLegacySingularQueryAlias() async throws {
        let result = try await ToolRegistry.shared.execute(
            name: "capabilities_discover",
            argumentsJSON: "{\"query\": \"zzz_capability_alias_probe_\(UUID().uuidString)\"}"
        )
        #expect(!ToolEnvelope.isError(result))
        #expect(result.contains("No capabilities found") || result.contains("Found"))
    }

    @Test func capabilitiesSearchSchemaIsGemmaRenderable() throws {
        let spec = CapabilitiesDiscoverTool().asOpenAITool().toTokenizerToolSpec()
        let fn = try #require(spec["function"] as? [String: any Sendable])
        let parameters = try #require(fn["parameters"] as? [String: any Sendable])
        let properties = try #require(parameters["properties"] as? [String: any Sendable])
        let query = try #require(properties["query"] as? [String: any Sendable])

        #expect(query["type"] as? String == "string")
        #expect(query["anyOf"] == nil)
        #expect(query["oneOf"] == nil)
        #expect(query["items"] == nil)
        // Legacy `queries` is dropped from the schema so small models only see
        // one input field; `requireQueries` still accepts it server-side.
        #expect(properties["queries"] == nil)
    }

    @Test @MainActor
    func registryAcceptsStringifiedQueriesFromSmallModels() async throws {
        let result = try await ToolRegistry.shared.execute(
            name: "capabilities_discover",
            argumentsJSON:
                "{\"queries\": \"[<|\\\"|>zzz_capability_string_probe_\(UUID().uuidString)<|\\\"|>]\"}"
        )
        #expect(!ToolEnvelope.isError(result))
        #expect(result.contains("No capabilities found") || result.contains("Found"))
    }

    @Test func returnsNoMatchMessage() async throws {
        let tool = CapabilitiesDiscoverTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"queries\": [\"zzz_completely_nonexistent_capability_xyz\"]}"
        )
        #expect(result.contains("No capabilities found") || result.contains("capability"))
    }

    @Test func namedToolCandidateExtractionIsConservative() {
        let candidates = CapabilitiesDiscoverTool.namedToolCandidates(
            in: [
                "Can I use tool/share_artifact here?",
                "What about capabilities_discover and zzz_missing_tool?",
                "plain prose should stay quiet",
            ],
            registeredToolNames: ["share_artifact", "capabilities_discover", "notify"]
        )

        #expect(candidates == ["share_artifact", "capabilities_discover", "zzz_missing_tool"])
    }

    @Test @MainActor
    func exposureDiagnosticSeparatesLoadedSearchableAndMissingTools() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let dbWasOpen = ToolDatabase.shared.isOpen
            if !dbWasOpen {
                try ToolDatabase.shared.openInMemory()
            }
            defer {
                if !dbWasOpen {
                    ToolDatabase.shared.close()
                }
            }

            await ToolIndexService.shared.syncFromRegistry(rebuildVectorIndex: false)
            let diagnostic = await ToolIndexService.shared.exposureDiagnostic(
                forToolNames: [
                    "share_artifact",
                    "capabilities_discover",
                    "zzz_missing_tool",
                ]
            )
            let rows = Dictionary(
                uniqueKeysWithValues: diagnostic.rows.map { ($0.toolName, $0) }
            )

            let shareArtifact = try #require(rows["share_artifact"])
            #expect(shareArtifact.availability.reasonCodes.contains(.alreadyLoaded))
            #expect(shareArtifact.indexedForSearch)
            #expect(shareArtifact.searchableByCapabilitiesDiscover)
            #expect(shareArtifact.searchReasonCodes.contains(.searchable))

            let discover = try #require(rows["capabilities_discover"])
            #expect(discover.availability.reasonCodes.contains(.alreadyLoaded))
            #expect(!discover.searchableByCapabilitiesDiscover)
            #expect(discover.searchReasonCodes.contains(.excludedCapabilityInfrastructure))

            let missing = try #require(rows["zzz_missing_tool"])
            #expect(missing.availability.reasonCodes == [.notRegistered])
            #expect(!missing.searchableByCapabilitiesDiscover)
            #expect(missing.searchReasonCodes.contains(.notRegistered))
        }
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

                let tool = CapabilitiesDiscoverTool(agentId: agent.id)
                let result = try await tool.execute(
                    argumentsJSON: "{\"queries\": [\"current headline web search\"]}"
                )
                #expect(result.contains(allowed.name))
                #expect(!result.contains(denied.name))
                #expect(result.contains("availability: loadable_via_capabilities_load"))

                AgentManager.shared.setActiveAgent(agent.id)
                defer { AgentManager.shared.setActiveAgent(Agent.defaultId) }
                let unscopedTool = CapabilitiesDiscoverTool()
                let unscopedResult = try await unscopedTool.execute(
                    argumentsJSON: "{\"queries\": [\"current headline web search\"]}"
                )
                #expect(unscopedResult.contains(allowed.name))
                #expect(
                    unscopedResult.contains(denied.name),
                    "Direct capabilities_discover calls without explicit/task-local agent context must keep global-enabled results"
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

    /// Synthetic spec with a uniquely-marked parameter description so the
    /// full-vs-compact schema rendering is observable.
    private func schemaProbeTool() -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: "schema_probe_tool",
                description: "Probe tool. Extra prose that compact mode trims.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "city": .object([
                            "type": .string("string"),
                            "description": .string("UNIQUE_PARAM_PROSE_MARKER"),
                        ])
                    ]),
                    "required": .array([.string("city")]),
                ])
            )
        )
    }

    @Test func loadedSchemaBlockRendersFullSchemaForNonDefaultAgent() {
        // No agent context → not the Default agent → full schema (with the
        // parameter prose) rides in the load result so dynamically loaded
        // tools call correctly on the first attempt.
        let block = CapabilitiesLoadTool.loadedSchemaBlock(for: schemaProbeTool())
        #expect(block.contains("\"name\":\"schema_probe_tool\""))
        #expect(block.contains("city"))
        #expect(block.contains("UNIQUE_PARAM_PROSE_MARKER"))
        #expect(block.contains("\"required\":[\"city\"]"))
    }

    @Test func loadedSchemaBlockCompactsForDefaultAgent() {
        // The Default (configuration) agent gets the compact bootstrap
        // skeleton — field names + required kept, prose dropped — so the
        // suffix stays as lean as its turn-1 baseline.
        let block = ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            CapabilitiesLoadTool.loadedSchemaBlock(for: schemaProbeTool())
        }
        #expect(block.contains("\"name\":\"schema_probe_tool\""))
        #expect(block.contains("city"))
        #expect(block.contains("\"required\":[\"city\"]"))
        #expect(!block.contains("UNIQUE_PARAM_PROSE_MARKER"))
    }

    @Test func handlesInvalidIdFormat() async throws {
        // All-failed contract: a load where NOTHING succeeded returns a
        // real failure envelope (kind: invalid_args, field: ids), not
        // "Warning" prose inside a success envelope.
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{\"ids\": [\"no-slash\"]}")
        #expect(ToolEnvelope.isError(result))
        #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
        #expect(EnvelopeAssertions.failureField(result) == "ids")
        #expect(result.contains("Invalid ID format"))
    }

    @Test func handlesUnknownTypePrefix() async throws {
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{\"ids\": [\"widget/abc\"]}")
        #expect(ToolEnvelope.isError(result))
        #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
        #expect(result.contains("Unknown type"))
    }

    @Test func invalidIdIsNonRetryable() async throws {
        // The issue's repro: a wrong-prefix id is a deterministic invalid_args
        // failure. Capability ids are a closed vocabulary, so re-issuing the
        // identical call cannot succeed — it must NOT be advertised retryable.
        // `plugin/` is now a real loadable type, so use a genuinely-unknown
        // prefix to exercise the invalid_args path.
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(argumentsJSON: "{\"ids\": [\"widget/Scite.AI\"]}")
        #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
        #expect(EnvelopeAssertions.failureRetryable(result) == false)
    }

    @Test func notFoundIsNonRetryable() async throws {
        // A not_found capability id is equally deterministic within a turn; the
        // prior `kind != .rejected` rule wrongly advertised it as retryable.
        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"skill/zzz_nonexistent_skill\"]}"
        )
        #expect(EnvelopeAssertions.failureKind(result) == "not_found")
        #expect(EnvelopeAssertions.failureRetryable(result) == false)
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
        let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(
                argumentsJSON: "{\"ids\": [\"tool/zzz_nonexistent_tool\"]}"
            )
        }
        #expect(result.contains("Error") || result.contains("not found"))
        #expect(result.contains("availability: not_registered"))
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
            ToolRegistry.shared.setEnabled(true, for: "capabilities_discover")
        }

        let tool = CapabilitiesLoadTool()
        let result = try await tool.execute(
            argumentsJSON: "{\"ids\": [\"tool/capabilities_discover\"]}"
        )

        #expect(result.contains("loaded") || result.contains("available"))

        let buffered = await CapabilityLoadBuffer.shared.drain()
        #expect(buffered.contains(where: { $0.function.name == "capabilities_discover" }))
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
                #expect(result.contains("availability: hidden_by_agent_scope"))
                let buffered = await CapabilityLoadBuffer.shared.drain()
                #expect(!buffered.contains(where: { $0.function.name == denied.name }))

                _ = await AgentManager.shared.delete(id: agent.id)
            }
        }
    }

    @Test @MainActor
    func skillLoadAutoLoadsPluginToolGroup() async throws {
        try await StoragePathsTestLock.shared.run {
            try await DynamicCatalogTestLock.shared.run {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-skill-autoload-root-\(UUID().uuidString)",
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

                // A plugin tool whose group (plugin id) matches the skill below.
                let plugin = SandboxPlugin(
                    name: "AutoGroup \(UUID().uuidString.prefix(6))",
                    description: "Auto-load fixture plugin"
                )
                let groupTool = SandboxPluginTool(
                    spec: SandboxToolSpec(
                        id: "probe",
                        description: "Probe tool governed by the skill",
                        parameters: [
                            "mode": SandboxParameterSpec(
                                type: "string",
                                description: "Optional probe mode",
                                default: "default"
                            )
                        ],
                        run: "echo hi"
                    ),
                    plugin: plugin
                )
                ToolRegistry.shared.registerPluginTool(groupTool)
                ToolRegistry.shared.setEnabled(true, for: groupTool.name)
                defer { ToolRegistry.shared.unregister(names: [groupTool.name]) }

                // The governing skill, tagged with the plugin id.
                let skill = Skill(
                    id: UUID(),
                    name: "AutoGroup Skill \(UUID().uuidString.prefix(6))",
                    description: "Governs the AutoGroup tool group",
                    version: "1.0.0",
                    keywords: [],
                    enabled: true,
                    instructions: "Use the AutoGroup tools.",
                    isBuiltIn: false,
                    pluginId: plugin.id
                )
                await SkillManager.shared.registerPluginSkill(skill)

                let agent = Agent(
                    name: "SkillAutoLoad-\(UUID().uuidString.prefix(6))",
                    agentAddress: "skill-autoload-\(UUID().uuidString)",
                    manualToolNames: [groupTool.name]
                )
                AgentManager.shared.add(agent)
                _ = await CapabilityLoadBuffer.shared.drain()

                let tool = CapabilitiesLoadTool()
                let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                    try await tool.execute(
                        argumentsJSON: "{\"ids\": [\"skill/\(skill.name)\"]}"
                    )
                }

                // The display name may be re-derived on store round-trip, so
                // assert on the auto-load behavior (the point of the test)
                // rather than the exact skill name.
                #expect(result.contains("## Skill:"))
                #expect(result.contains("Auto-loaded tools"))
                #expect(result.contains(groupTool.name))
                let buffered = await CapabilityLoadBuffer.shared.drain()
                #expect(buffered.contains(where: { $0.function.name == groupTool.name }))

                await SkillManager.shared.unregisterPluginSkills(pluginId: plugin.id)
                _ = await AgentManager.shared.delete(id: agent.id)
            }
        }
    }

    @Test @MainActor
    func toolLoadReportsDisabledAvailability() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-capability-load-disabled-\(UUID().uuidString)",
                isDirectory: true
            )
            let previousOverride = ToolConfigurationStore.overrideDirectory
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                ToolConfigurationStore.overrideDirectory = previousOverride
                try? FileManager.default.removeItem(at: tempDir)
            }

            let toolName = "lane_b_disabled_search_tool_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
            let disabled = CapabilityPolicyFixtureTool(
                name: toolName,
                description: "Search the web for current headlines and online results"
            )
            ToolRegistry.shared.registerPluginTool(disabled)
            ToolRegistry.shared.setEnabled(false, for: disabled.name)
            defer { ToolRegistry.shared.unregister(names: [disabled.name]) }

            let tool = CapabilitiesLoadTool()
            let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
                try await tool.execute(
                    argumentsJSON: "{\"ids\": [\"tool/\(disabled.name)\"]}"
                )
            }

            #expect(result.contains("disabled"))
            #expect(result.contains("availability: disabled"))
            let buffered = await CapabilityLoadBuffer.shared.drain()
            #expect(!buffered.contains(where: { $0.function.name == disabled.name }))
        }
    }

    /// Idempotency guard-ordering regression (W4): a tool already in the
    /// session's schema must return success when re-loaded, EVEN IF it is
    /// globally disabled now. Before the fix, the `isEnabled` guard fired
    /// before the already-loaded check, so re-loading an already-callable
    /// tool returned `{"ok":false,"kind":"rejected","… is disabled"}` —
    /// telling the model a working capability failed, derailing the loop.
    @Test @MainActor
    func toolLoadIsIdempotentForAlreadyLoadedSessionToolEvenWhenDisabled() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-capability-load-idempotent-\(UUID().uuidString)",
                isDirectory: true
            )
            let previousOverride = ToolConfigurationStore.overrideDirectory
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                ToolConfigurationStore.overrideDirectory = previousOverride
                try? FileManager.default.removeItem(at: tempDir)
            }

            let toolName =
                "lane_b_already_loaded_tool_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
            let fixture = CapabilityPolicyFixtureTool(
                name: toolName,
                description: "Search the web for current headlines and online results"
            )
            ToolRegistry.shared.registerPluginTool(fixture)
            // Globally disabled: without the guard-ordering fix this would
            // reject at the `isEnabled` guard even though the tool is already
            // in the session's schema (and therefore already callable).
            ToolRegistry.shared.setEnabled(false, for: fixture.name)
            defer { ToolRegistry.shared.unregister(names: [fixture.name]) }

            // Mirror a tool the model loaded on an earlier turn, now frozen
            // into the session schema.
            let sessionId = "idempotent-load-\(UUID().uuidString)"
            await SessionToolStateStore.shared.appendLoadedTools(
                sessionId,
                names: [fixture.name],
                fallbackAlwaysLoadedNames: nil
            )

            _ = await CapabilityLoadBuffer.shared.drain()

            let tool = CapabilitiesLoadTool()
            let result = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
                    try await tool.execute(argumentsJSON: "{\"ids\": [\"tool/\(fixture.name)\"]}")
                }
            }

            // Idempotent SUCCESS, not a "disabled" rejection.
            #expect(!ToolEnvelope.isError(result))
            #expect(result.contains("already loaded and callable"))
            #expect(!result.contains("is disabled"))
            // And no re-buffering — an already-loaded tool must not re-enter
            // the deferred-schema buffer.
            let buffered = await CapabilityLoadBuffer.shared.drain()
            #expect(!buffered.contains(where: { $0.function.name == fixture.name }))

            await SessionToolStateStore.shared.invalidate(sessionId)
        }
    }

    @Test @MainActor
    func toolLoadRejectsMalformedDynamicSchemaWithTypedDiagnostic() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let toolName =
                "lane_b_malformed_schema_tool_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
            let fixture = MalformedSchemaFixtureTool(name: toolName)
            ToolRegistry.shared.registerPluginTool(fixture)
            ToolRegistry.shared.setEnabled(true, for: fixture.name)
            defer { ToolRegistry.shared.unregister(names: [fixture.name]) }

            _ = await CapabilityLoadBuffer.shared.drain()

            let tool = CapabilitiesLoadTool()
            let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
                try await tool.execute(argumentsJSON: "{\"ids\": [\"tool/\(fixture.name)\"]}")
            }

            #expect(ToolEnvelope.isError(result))
            #expect(EnvelopeAssertions.failureKind(result) == "invalid_args")
            #expect(EnvelopeAssertions.failureField(result) == "parameters")
            #expect(result.contains("non-object parameter schema"))
            #expect(await CapabilityLoadBuffer.shared.drain().isEmpty)
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

private struct MalformedSchemaFixtureTool: OsaurusTool {
    let name: String
    let description = "Fixture with a malformed schema"
    let parameters: JSONValue? = .string("not an object")

    func execute(argumentsJSON: String) async throws -> String {
        argumentsJSON
    }
}
