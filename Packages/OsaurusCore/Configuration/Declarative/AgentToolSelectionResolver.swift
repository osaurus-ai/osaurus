//
//  AgentToolSelectionResolver.swift
//  osaurus
//
//  Pure mapping between an agent's manual tool list and the portable
//  `tools` / `mcp_servers` / `plugins` keys of the declarative document.
//  MCP servers are addressed by NAME and plugins by registry id because
//  tool names an MCP server exposes differ between machines; the group
//  is what travels, the tool list is derived locally on apply.
//

import Foundation

/// A machine-portable owner of dynamic tools.
public enum PortableToolGroup: Hashable, Sendable {
    /// An MCP server, identified by its user-facing name.
    case mcpServer(String)
    /// An external or sandbox plugin, identified by its registry id.
    case plugin(String)

    var name: String {
        switch self {
        case .mcpServer(let name): return name
        case .plugin(let id): return id
        }
    }

    var isMCP: Bool {
        if case .mcpServer = self { return true }
        return false
    }
}

enum AgentToolSelectionResolver {

    /// Result of splitting an agent's manual list into portable parts.
    struct Exported: Equatable {
        /// Tool names that belong to no group (built-in / runtime tools).
        var toolNames: [String]
        /// MCP servers with at least one selected tool.
        var enabledMCPServers: [String]
        /// MCP servers known locally with no selected tool.
        var disabledMCPServers: [String]
        /// Plugins with at least one selected tool.
        var enabledPlugins: [String]
        /// Plugins known locally with no selected tool.
        var disabledPlugins: [String]
    }

    /// Splits `manualToolNames` into ungrouped tool names plus per-group
    /// enablement. A group counts as enabled when ANY of its tools is
    /// selected (partial selections widen to the full group on re-apply;
    /// that is the documented portability trade-off).
    static func export(
        manualToolNames: [String],
        groups: [PortableToolGroup: [String]]
    ) -> Exported {
        let selected = Set(manualToolNames)
        var owner: [String: PortableToolGroup] = [:]
        for (group, names) in groups {
            for name in names { owner[name] = group }
        }
        var ungrouped: [String] = []
        var seen = Set<String>()
        for name in manualToolNames where owner[name] == nil && !seen.contains(name) {
            seen.insert(name)
            ungrouped.append(name)
        }
        var enabledMCP: [String] = []
        var disabledMCP: [String] = []
        var enabledPlugins: [String] = []
        var disabledPlugins: [String] = []
        for (group, names) in groups {
            let on = names.contains { selected.contains($0) }
            switch (group, on) {
            case (.mcpServer(let n), true): enabledMCP.append(n)
            case (.mcpServer(let n), false): disabledMCP.append(n)
            case (.plugin(let id), true): enabledPlugins.append(id)
            case (.plugin(let id), false): disabledPlugins.append(id)
            }
        }
        return Exported(
            toolNames: ungrouped,
            enabledMCPServers: enabledMCP.sorted(),
            disabledMCPServers: disabledMCP.sorted(),
            enabledPlugins: enabledPlugins.sorted(),
            disabledPlugins: disabledPlugins.sorted()
        )
    }

    /// Result of applying document keys on top of a current manual list.
    struct Applied: Equatable {
        var manualToolNames: [String]
        /// Tool names from `tools.enabled` that are not registered here.
        var missingTools: [String]
        /// Group names from `mcp_servers` / `plugins` that do not exist here.
        var missingGroups: [String]
    }

    /// Computes the new manual tool list.
    ///
    /// - `baseToolNames`: when non-nil (the document carried `tools.enabled`)
    ///   it REPLACES the ungrouped part of the current list; grouped tools
    ///   already selected on this machine are kept unless a group entry
    ///   says otherwise. When nil, the current list is the starting point.
    /// - `enabledGroups` add every locally registered tool of the group,
    ///   `disabledGroups` remove them. Unknown groups are reported, never
    ///   fatal, so a template from another machine still applies.
    static func apply(
        current: [String],
        baseToolNames: [String]?,
        enabledGroups: [PortableToolGroup],
        disabledGroups: [PortableToolGroup],
        registered: Set<String>,
        groups: [PortableToolGroup: [String]]
    ) -> Applied {
        var owner: [String: PortableToolGroup] = [:]
        for (group, names) in groups {
            for name in names { owner[name] = group }
        }
        var result: [String] = []
        var missingTools: [String] = []
        if let base = baseToolNames {
            // Keep grouped selections, replace the ungrouped ones.
            result = current.filter { owner[$0] != nil }
            for name in base {
                if owner[name] != nil || registered.contains(name) {
                    result.append(name)
                } else {
                    missingTools.append(name)
                }
            }
        } else {
            result = current
        }
        var missingGroups: [String] = []
        for group in enabledGroups {
            guard let names = groups[group] else {
                missingGroups.append(group.name)
                continue
            }
            result.append(contentsOf: names)
        }
        var removed = Set<String>()
        for group in disabledGroups {
            guard let names = groups[group] else {
                // Disabling something that does not exist is already true.
                continue
            }
            removed.formUnion(names)
        }
        var seen = Set<String>()
        let deduped = result.filter { name in
            guard !removed.contains(name), !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
        return Applied(
            manualToolNames: deduped,
            missingTools: missingTools,
            missingGroups: missingGroups
        )
    }
}
