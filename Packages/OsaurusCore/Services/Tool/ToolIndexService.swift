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
    public func syncFromRegistry(rebuildVectorIndex: Bool = true) async {
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
                // indexed so capabilities_discover can discover them. Authoritatively-gated
                // built-ins (computer_use) are also excluded: they are auto-injected by the
                // prompt composer when the owning agent flag is on and have no
                // capabilities_load carve-out, so discovery would only surface a capability
                // the model can never load.
                let excluded = ToolRegistry.capabilityToolNames
                    .union(ToolRegistry.shared.runtimeManagedToolNames)
                    .union(ToolRegistry.nonDiscoverableBuiltInToolNames)
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

        if rebuildVectorIndex {
            await ToolSearchService.shared.rebuildIndex()
        }

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

    /// Snapshot every registered session tool with the same availability and
    /// capability-search reasons used by named diagnostics.
    func exposureSnapshot(
        agentAllowedNames: Set<String>? = nil,
        executionMode: ExecutionMode? = nil,
        selectedPreflightNames: Set<String>? = nil
    ) async -> ToolExposureDiagnostic {
        let toolNames = await MainActor.run {
            ToolRegistry.shared.listTools().map(\.name)
        }
        return await exposureDiagnostic(
            forToolNames: toolNames,
            agentAllowedNames: agentAllowedNames,
            executionMode: executionMode,
            selectedPreflightNames: selectedPreflightNames
        )
    }

    /// Explain how named tools move through the registry → search index →
    /// capability-discovery path. This is intentionally read-only: callers
    /// still enforce loading and execution through `ToolRegistry` and
    /// `capabilities_load`.
    func exposureDiagnostic(
        forToolNames rawNames: [String],
        agentAllowedNames: Set<String>? = nil,
        executionMode: ExecutionMode? = nil,
        selectedPreflightNames: Set<String>? = nil
    ) async -> ToolExposureDiagnostic {
        var seen = Set<String>()
        let names =
            rawNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        let databaseOpen = ToolDatabase.shared.isOpen
        let indexedToolCount = (try? ToolDatabase.shared.entryCount()) ?? 0
        let indexedNames: Set<String> = {
            guard databaseOpen,
                let entries = try? ToolDatabase.shared.loadAllEntries()
            else { return [] }
            return Set(entries.map(\.name))
        }()

        struct RegistrySnapshot {
            let registeredToolCount: Int
            let registeredNames: Set<String>
            let enabledNames: Set<String>
            let runtimeManagedNames: Set<String>
            let capabilityToolNames: Set<String>
            let entriesByName: [String: ToolRegistry.ToolEntry]
            let sourcesByName: [String: ToolExposureSource]
            let availabilityByName: [String: ToolAvailability]
        }

        let snapshot = await MainActor.run {
            let tools = ToolRegistry.shared.listTools()
            let registry = ToolRegistry.shared
            let entriesByName = Dictionary(
                uniqueKeysWithValues: tools.map { ($0.name, $0) }
            )
            let sourcesByName = Dictionary(
                uniqueKeysWithValues: tools.map { tool in
                    (tool.name, Self.exposureSource(for: tool.name, registry: registry))
                }
            )
            return RegistrySnapshot(
                registeredToolCount: tools.count,
                registeredNames: Set(tools.map(\.name)),
                enabledNames: Set(tools.filter(\.enabled).map(\.name)),
                runtimeManagedNames: registry.runtimeManagedToolNames,
                capabilityToolNames: ToolRegistry.capabilityToolNames,
                entriesByName: entriesByName,
                sourcesByName: sourcesByName,
                availabilityByName: Dictionary(
                    uniqueKeysWithValues: names.map {
                        (
                            $0,
                            registry.availability(
                                forTool: $0,
                                agentAllowedNames: agentAllowedNames,
                                executionMode: executionMode,
                                selectedPreflightNames: selectedPreflightNames
                            )
                        )
                    }
                )
            )
        }

        let rows = names.map { name -> ToolExposureDiagnostic.Row in
            let registered = snapshot.registeredNames.contains(name)
            let globallyEnabled = snapshot.enabledNames.contains(name)
            let indexedForSearch = indexedNames.contains(name)
            let entry = snapshot.entriesByName[name]
            let availability =
                snapshot.availabilityByName[name]
                ?? ToolAvailability(
                    toolName: name,
                    runtime: nil,
                    groupName: nil,
                    reasonCodes: [.notRegistered],
                    detail: L("tool is not registered; install or enable the plugin/provider that owns it")
                )

            var blockers: [ToolExposureSearchReasonCode] = []
            func append(_ reason: ToolExposureSearchReasonCode) {
                if !blockers.contains(reason) {
                    blockers.append(reason)
                }
            }

            if !registered {
                append(.notRegistered)
            }
            if snapshot.capabilityToolNames.contains(name) {
                append(.excludedCapabilityInfrastructure)
            }
            if snapshot.runtimeManagedNames.contains(name) {
                append(.runtimeManaged)
            }
            if registered, !globallyEnabled {
                append(.globallyDisabled)
            }
            if availability.reasonCodes.contains(.hiddenByAgentScope) {
                append(.hiddenByAgentScope)
            }
            if availability.reasonCodes.contains(.hiddenByExecutionMode) {
                append(.hiddenByExecutionMode)
            }
            if databaseOpen, registered, !indexedForSearch {
                append(.notIndexed)
            }

            let hasSearchBlocker = blockers.contains { reason in
                switch reason {
                case .indexed, .databaseClosedRegistryFallback, .searchable:
                    return false
                default:
                    return true
                }
            }
            let searchable =
                registered
                && !hasSearchBlocker
                && (!databaseOpen || indexedForSearch)

            var reasons: [ToolExposureSearchReasonCode] = []
            if searchable {
                reasons.append(.searchable)
                reasons.append(databaseOpen ? .indexed : .databaseClosedRegistryFallback)
            }
            reasons.append(contentsOf: blockers)

            return ToolExposureDiagnostic.Row(
                toolName: name,
                description: entry?.description ?? "",
                source: snapshot.sourcesByName[name] ?? .unknown,
                state: Self.exposureState(for: availability),
                availability: availability,
                registered: registered,
                globallyEnabled: globallyEnabled,
                indexedForSearch: indexedForSearch,
                searchableByCapabilitiesDiscover: searchable,
                searchReasonCodes: reasons,
                tokenEstimate: entry?.estimatedTokens ?? 0
            )
        }

        return ToolExposureDiagnostic(
            registeredToolCount: snapshot.registeredToolCount,
            indexedToolCount: indexedToolCount,
            rows: rows
        )
    }

    @MainActor
    private static func exposureSource(
        for toolName: String,
        registry: ToolRegistry
    ) -> ToolExposureSource {
        if registry.runtimeManagedToolNames.contains(toolName) {
            return .runtime
        }
        if registry.builtInToolNames.contains(toolName) {
            return .builtIn
        }
        if registry.isMCPTool(toolName) {
            return .mcpProvider
        }
        if registry.isSandboxTool(toolName) {
            return .sandboxPlugin
        }
        if registry.isPluginTool(toolName) {
            return .plugin
        }
        return .native
    }

    private static func exposureState(for availability: ToolAvailability) -> ToolExposureState {
        let reasons = Set(availability.reasonCodes)
        if reasons.contains(.permissionBlocked) || reasons.contains(.missingPermission) {
            return .blocked
        }
        if reasons.contains(.disabled) {
            return .disabled
        }
        if reasons.contains(.hiddenByAgentScope)
            || reasons.contains(.hiddenByExecutionMode)
            || reasons.contains(.notSelectedByPreflight)
        {
            return .hidden
        }
        if availability.isCallableNow {
            return .exposed
        }
        if availability.isLoadableViaCapabilitiesLoad {
            return .loadable
        }
        return .unavailable
    }

    /// Build a compact text index for injection into system prompt.
    /// Only includes enabled tools from the registry.
    public func buildCompactIndex() async throws -> String {
        let enabledTools = await MainActor.run {
            ToolRegistry.shared.listTools().filter { $0.enabled }
        }
        let enabledNames = Set(enabledTools.map { $0.name })
        let entries: [ToolIndexEntry]
        if ToolDatabase.shared.isOpen {
            entries = try ToolDatabase.shared.loadAllEntries().filter { enabledNames.contains($0.name) }
        } else {
            entries = await MainActor.run {
                let excluded = ToolRegistry.capabilityToolNames
                    .union(ToolRegistry.shared.runtimeManagedToolNames)
                return
                    enabledTools
                    .filter { !excluded.contains($0.name) }
                    .map { tool -> ToolIndexEntry in
                        let runtime: ToolRuntime
                        if ToolRegistry.shared.isSandboxTool(tool.name) {
                            runtime = .sandbox
                        } else if ToolRegistry.shared.isMCPTool(tool.name) {
                            runtime = .mcp
                        } else if ToolRegistry.shared.builtInToolNames.contains(tool.name) {
                            runtime = .builtin
                        } else {
                            runtime = .native
                        }
                        return ToolIndexEntry(
                            id: tool.name,
                            name: tool.name,
                            description: tool.description,
                            runtime: runtime,
                            source: .system,
                            tokenCount: tool.estimatedTokens
                        )
                    }
            }
        }

        if entries.isEmpty { return "No tools available." }

        var lines: [String] = ["Available tools:"]
        for entry in entries {
            lines.append("- \(entry.name): \(entry.description) [\(entry.runtime.rawValue)]")
        }
        return lines.joined(separator: "\n")
    }
}
