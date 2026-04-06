//
//  ToolIndexService.swift
//  osaurus
//
//  Syncs ToolRegistry contents into the unified tool_index SQLite table and
//  VecturaKit search index. Provides search for the context interface.
//

import Foundation

public actor ToolIndexService {
    public static let shared = ToolIndexService()

    private init() {}

    /// Populate tool_index from ToolRegistry. Called once at startup after
    /// ToolDatabase and ToolSearchService are both initialized.
    public func syncFromRegistry() async {
        let (tools, sandboxNames, mcpNames, builtInNames, excludedNames):
            (
                [ToolRegistry.ToolEntry], Set<String>, Set<String>, Set<String>, Set<String>
            ) = await MainActor.run {
                let all = ToolRegistry.shared.listTools()
                let sandbox = Set(all.filter { ToolRegistry.shared.isSandboxTool($0.name) }.map(\.name))
                let mcp = Set(all.filter { ToolRegistry.shared.isMCPTool($0.name) }.map(\.name))
                let builtIn = ToolRegistry.shared.builtInToolNames
                // Exclude capability infrastructure tools and runtime-managed tools from the
                // search index, but allow user-facing built-in tools (e.g. search_*) to be
                // indexed so capabilities_search can discover them.
                let excluded = ToolRegistry.capabilityToolNames
                    .union(ToolRegistry.shared.runtimeManagedToolNames)
                return (all, sandbox, mcp, builtIn, excluded)
            }

        let indexableTools = tools.filter { !excludedNames.contains($0.name) }
        let indexedNames = Set(indexableTools.map(\.name))

        for tool in indexableTools {
            let runtime: ToolRuntime
            if sandboxNames.contains(tool.name) {
                runtime = .sandbox
            } else if mcpNames.contains(tool.name) {
                runtime = .mcp
            } else if builtInNames.contains(tool.name) {
                runtime = .builtin
            } else {
                runtime = .native
            }
            let entry = ToolIndexEntry(
                id: tool.name,
                name: tool.name,
                description: tool.description,
                runtime: runtime,
                toolsJSON: "{}",
                source: .system,
                tokenCount: tool.estimatedTokens
            )

            do {
                try ToolDatabase.shared.upsertEntry(entry)
            } catch {
                ToolIndexLogger.service.error("Failed to sync tool '\(tool.name)' to index: \(error)")
            }
        }

        do {
            let allEntries = try ToolDatabase.shared.loadAllEntries()
            let staleSystemEntries = allEntries.filter {
                $0.source == .system && !indexedNames.contains($0.id)
            }
            for stale in staleSystemEntries {
                do {
                    try ToolDatabase.shared.deleteEntry(id: stale.id)
                    ToolIndexLogger.service.info("Pruned stale tool index entry: \(stale.id)")
                } catch {
                    ToolIndexLogger.service.error("Failed to prune stale entry '\(stale.id)': \(error)")
                }
            }
        } catch {
            ToolIndexLogger.service.error("Failed to load entries for pruning: \(error)")
        }

        await ToolSearchService.shared.rebuildIndex()

        let count = (try? ToolDatabase.shared.entryCount()) ?? 0
        ToolIndexLogger.service.info("Tool index synced: \(count) entries from registry")
    }

    /// Index a single newly-registered tool.
    public func onToolRegistered(
        name: String,
        description: String,
        runtime: ToolRuntime = .builtin,
        tokenCount: Int = 0,
        parameters: JSONValue? = nil
    ) async {
        let entry = ToolIndexEntry(
            id: name,
            name: name,
            description: description,
            runtime: runtime,
            toolsJSON: "{}",
            source: .system,
            tokenCount: tokenCount
        )
        do {
            try ToolDatabase.shared.upsertEntry(entry)
            await ToolSearchService.shared.indexEntry(entry, parameters: parameters)
        } catch {
            ToolIndexLogger.service.error("Failed to index registered tool '\(name)': \(error)")
        }
    }

    /// Remove a tool from the index when unregistered.
    public func onToolUnregistered(name: String) async {
        do {
            try ToolDatabase.shared.deleteEntry(id: name)
            await ToolSearchService.shared.removeEntry(id: name)
        } catch {
            ToolIndexLogger.service.error("Failed to remove tool '\(name)' from index: \(error)")
        }
    }

    /// Search the tool index.
    public func search(query: String, topK: Int = 10) async -> [ToolSearchResult] {
        await ToolSearchService.shared.search(query: query, topK: topK)
    }

    /// Build a compact text index for injection into system prompt.
    /// Only includes enabled tools from the registry.
    public func buildCompactIndex() async throws -> String {
        let enabledNames = await MainActor.run {
            Set(ToolRegistry.shared.listTools().filter { $0.enabled }.map { $0.name })
        }
        let entries = try ToolDatabase.shared.loadAllEntries().filter { enabledNames.contains($0.name) }
        if entries.isEmpty { return "No tools available." }

        var lines: [String] = ["Available tools:"]
        for entry in entries {
            lines.append("- \(entry.name): \(entry.description) [\(entry.runtime.rawValue)]")
        }
        return lines.joined(separator: "\n")
    }
}
