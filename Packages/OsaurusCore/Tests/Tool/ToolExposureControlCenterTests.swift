//
//  ToolExposureControlCenterTests.swift
//  osaurus
//
//  Tests for the tool exposure control-center snapshot and report contract.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ToolExposureControlCenterTests {

    @Test @MainActor
    func exposureSnapshotClassifiesSourcesStatesAndReasons() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tool-exposure-control-\(UUID().uuidString)",
                isDirectory: true
            )
            let previousOverride = ToolConfigurationStore.overrideDirectory
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                ToolConfigurationStore.overrideDirectory = previousOverride
                try? FileManager.default.removeItem(at: tempDir)
            }

            let dbWasOpen = ToolDatabase.shared.isOpen
            if !dbWasOpen {
                try ToolDatabase.shared.openInMemory()
            }

            let enabled = ExposureControlFixtureTool(
                name: Self.uniqueName("enabled"),
                description: "Search current exposure control rows"
            )
            let disabled = ExposureControlFixtureTool(
                name: Self.uniqueName("disabled"),
                description: "Search disabled exposure control rows"
            )

            ToolRegistry.shared.registerPluginTool(enabled)
            ToolRegistry.shared.registerPluginTool(disabled)
            ToolRegistry.shared.setEnabled(true, for: enabled.name)
            ToolRegistry.shared.setEnabled(false, for: disabled.name)

            defer {
                ToolRegistry.shared.unregister(names: [enabled.name, disabled.name])
                try? ToolDatabase.shared.deleteEntry(id: enabled.name)
                try? ToolDatabase.shared.deleteEntry(id: disabled.name)
                if !dbWasOpen {
                    ToolDatabase.shared.close()
                }
            }

            await ToolIndexService.shared.onToolRegistered(
                name: enabled.name,
                description: enabled.description,
                runtime: .native,
                tokenCount: 12,
                parameters: enabled.parameters
            )
            await ToolIndexService.shared.onToolRegistered(
                name: disabled.name,
                description: disabled.description,
                runtime: .native,
                tokenCount: 12,
                parameters: disabled.parameters
            )

            let allToolsCount = ToolRegistry.shared.toolCount
            let snapshot = await ToolIndexService.shared.exposureSnapshot(
                agentAllowedNames: [enabled.name]
            )
            #expect(snapshot.registeredToolCount == allToolsCount)
            #expect(snapshot.rows.count == allToolsCount)

            let rowsByName = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.toolName, $0) })
            let enabledRow = try #require(rowsByName[enabled.name])
            #expect(enabledRow.source == .plugin)
            #expect(enabledRow.state == .loadable)
            #expect(enabledRow.availability.reasonCodes == [.loadableViaCapabilitiesLoad])
            #expect(enabledRow.searchReasonCodes.contains(.searchable))
            #expect(enabledRow.searchableByCapabilitiesDiscover)

            let disabledRow = try #require(rowsByName[disabled.name])
            #expect(disabledRow.source == .plugin)
            #expect(disabledRow.state == .disabled)
            #expect(disabledRow.availability.reasonCodes.contains(.disabled))
            #expect(disabledRow.searchReasonCodes.contains(.globallyDisabled))
            #expect(!disabledRow.searchableByCapabilitiesDiscover)

            let hidden = await ToolIndexService.shared.exposureDiagnostic(
                forToolNames: [enabled.name],
                agentAllowedNames: []
            )
            let hiddenRow = try #require(hidden.rows.first)
            #expect(hiddenRow.state == .hidden)
            #expect(hiddenRow.availability.reasonCodes.contains(.hiddenByAgentScope))
            #expect(hiddenRow.searchReasonCodes.contains(.hiddenByAgentScope))

            let pluginRows = snapshot.filteredRows(source: .plugin)
            #expect(pluginRows.contains { $0.toolName == enabled.name })
            #expect(pluginRows.contains { $0.toolName == disabled.name })
            #expect(snapshot.filteredRows(state: .disabled).contains { $0.toolName == disabled.name })
        }
    }

    @Test @MainActor
    func reporterSafeMarkdownOmitsSchemasArgumentsAndRuntimeDetails() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tool = ExposureControlFixtureTool(
                name: Self.uniqueName("secret_report"),
                description: "Tool with a schema field that must not leak into reports"
            )
            let excluded = ExposureControlFixtureTool(
                name: Self.uniqueName("excluded_report"),
                description: "Tool filtered out of the report"
            )
            ToolRegistry.shared.registerPluginTool(tool)
            ToolRegistry.shared.registerPluginTool(excluded)
            ToolRegistry.shared.setEnabled(true, for: tool.name)
            ToolRegistry.shared.setEnabled(true, for: excluded.name)
            defer { ToolRegistry.shared.unregister(names: [tool.name, excluded.name]) }

            let diagnostic = await ToolIndexService.shared.exposureDiagnostic(
                forToolNames: [tool.name, excluded.name]
            )
            let row = try #require(diagnostic.rows.first { $0.toolName == tool.name })
            let report = diagnostic.reporterSafeMarkdown(
                generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
                rows: [row]
            )

            #expect(report.contains("# Tool Exposure Report"))
            #expect(report.contains(tool.name))
            #expect(!report.contains(excluded.name))
            #expect(report.contains("- Rows in report: 1"))
            #expect(report.contains("Reporter-safe fields only"))
            #expect(!report.contains("api_key"))
            #expect(!report.contains("Secret credential"))
            #expect(!report.contains("Search query"))
            #expect(!report.contains(tool.description))
        }
    }

    @Test @MainActor
    func capabilitySearchDoesNotReturnGloballyDisabledIndexedTool() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tool-exposure-search-\(UUID().uuidString)",
                isDirectory: true
            )
            let previousOverride = ToolConfigurationStore.overrideDirectory
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                ToolConfigurationStore.overrideDirectory = previousOverride
                try? FileManager.default.removeItem(at: tempDir)
            }

            let dbWasOpen = ToolDatabase.shared.isOpen
            if !dbWasOpen {
                try ToolDatabase.shared.openInMemory()
            }

            let disabled = ExposureControlFixtureTool(
                name: Self.uniqueName("search_disabled"),
                description: "Find exposurecontrolkeyword online search results"
            )
            ToolRegistry.shared.registerPluginTool(disabled)
            ToolRegistry.shared.setEnabled(false, for: disabled.name)
            defer {
                ToolRegistry.shared.unregister(names: [disabled.name])
                try? ToolDatabase.shared.deleteEntry(id: disabled.name)
                if !dbWasOpen {
                    ToolDatabase.shared.close()
                }
            }

            await ToolIndexService.shared.onToolRegistered(
                name: disabled.name,
                description: disabled.description,
                runtime: .native,
                tokenCount: 12,
                parameters: disabled.parameters
            )

            let bm25 = try ToolDatabase.shared.searchBM25(query: "exposurecontrolkeyword", topK: 5)
            #expect(bm25.contains { $0.id == disabled.name })

            let (hybrid, diagnostic) = await ToolSearchService.shared.searchHybridWithDiagnostic(
                query: "exposurecontrolkeyword",
                topK: 5,
                minFusedScore: CapabilitySearch.minimumFusedScore
            )
            #expect(diagnostic.allHits.contains { $0.name == disabled.name })
            #expect(!hybrid.contains { $0.entry.name == disabled.name })

            let capabilityResults = await CapabilitySearch.search(
                query: "exposurecontrolkeyword",
                topK: (methods: 0, tools: 5, skills: 0)
            )
            #expect(!capabilityResults.tools.contains { $0.entry.name == disabled.name })

            let exposure = await ToolIndexService.shared.exposureDiagnostic(forToolNames: [disabled.name])
            let row = try #require(exposure.rows.first)
            #expect(row.state == .disabled)
            #expect(row.searchReasonCodes.contains(.globallyDisabled))
            #expect(!row.searchableByCapabilitiesDiscover)
        }
    }

    private static func uniqueName(_ suffix: String) -> String {
        "tool_exposure_\(suffix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }
}

private struct ExposureControlFixtureTool: OsaurusTool {
    let name: String
    let description: String
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Search query"),
            ]),
            "api_key": .object([
                "type": .string("string"),
                "description": .string("Secret credential used only by tests"),
            ]),
        ]),
        "required": .array([.string("query")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        argumentsJSON
    }
}
