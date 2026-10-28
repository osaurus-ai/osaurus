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
        /// Tool names listed one by one: tools that belong to no group, plus
        /// the exact tools of groups that are only partly selected.
        var toolNames: [String]
        /// MCP servers with every tool selected.
        var enabledMCPServers: [String]
        /// MCP servers known locally with no selected tool.
        var disabledMCPServers: [String]
        /// Plugins with every tool selected.
        var enabledPlugins: [String]
        /// Plugins known locally with no selected tool.
        var disabledPlugins: [String]
    }

    /// Splits `manualToolNames` into tool names plus per-group enablement.
    /// A fully selected group travels by name, so it picks up the tools the
    /// group exposes on another machine. A partly selected group travels as
    /// its exact tool names, so the export shows the list the agent really
    /// runs with and re-applying it does not widen to the whole group.
    static func export(
        manualToolNames: [String],
        groups: [PortableToolGroup: [String]]
    ) -> Exported {
        let selected = Set(manualToolNames)
        var owner: [String: PortableToolGroup] = [:]
        for (group, names) in groups {
            for name in names { owner[name] = group }
        }
        var enabledMCP: [String] = []
        var disabledMCP: [String] = []
        var enabledPlugins: [String] = []
        var disabledPlugins: [String] = []
        var partial = Set<PortableToolGroup>()
        for (group, names) in groups {
            let count = names.filter { selected.contains($0) }.count
            if count > 0 && count < names.count {
                partial.insert(group)
                continue
            }
            switch (group, count > 0) {
            case (.mcpServer(let n), true): enabledMCP.append(n)
            case (.mcpServer(let n), false): disabledMCP.append(n)
            case (.plugin(let id), true): enabledPlugins.append(id)
            case (.plugin(let id), false): disabledPlugins.append(id)
            }
        }
        var listed: [String] = []
        var seen = Set<String>()
        for name in manualToolNames where !seen.contains(name) {
            if let group = owner[name], !partial.contains(group) { continue }
            seen.insert(name)
            listed.append(name)
        }
        return Exported(
            toolNames: listed,
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
        /// Unregistered `tools.enabled` names kept because the caller asked
        /// to (`keepUnregistered`), e.g. tools of a server still connecting.
        var keptUnregistered: [String] = []
    }

    /// Computes the new manual tool list.
    ///
    /// - `baseToolNames`: when non-nil (the document carried `tools.enabled`)
    ///   it REPLACES the ungrouped part of the current list, and the
    ///   selection of every group it names a tool of (an exact, partly
    ///   selected group). Other grouped tools already selected on this
    ///   machine are kept unless a group entry says otherwise. When nil,
    ///   the current list is the starting point.
    /// - `enabledGroups` add every locally registered tool of the group,
    ///   `disabledGroups` remove them. Unknown groups are reported, never
    ///   fatal, so a template from another machine still applies.
    /// - `keepUnregistered` keeps base names no tool here provides instead
    ///   of reporting them missing.
    static func apply(
        current: [String],
        baseToolNames: [String]?,
        enabledGroups: [PortableToolGroup],
        disabledGroups: [PortableToolGroup],
        registered: Set<String>,
        groups: [PortableToolGroup: [String]],
        keepUnregistered: Bool = false
    ) -> Applied {
        var owner: [String: PortableToolGroup] = [:]
        for (group, names) in groups {
            for name in names { owner[name] = group }
        }
        var result: [String] = []
        var missingTools: [String] = []
        var keptUnregistered: [String] = []
        if let base = baseToolNames {
            // Keep grouped selections, replace the ungrouped ones. A current
            // name that is not registered at all most likely belongs to an MCP
            // server or plugin that is offline right now; it has no owner to
            // classify it by, so keep it rather than silently dropping tools
            // the user picked.
            let exactGroups = Set(base.compactMap { owner[$0] })
            result = current.filter { name in
                if let group = owner[name] { return !exactGroups.contains(group) }
                return !registered.contains(name)
            }
            let kept = Set(result)
            for name in base {
                if owner[name] != nil || registered.contains(name) {
                    result.append(name)
                } else if kept.contains(name) {
                    continue
                } else if keepUnregistered {
                    result.append(name)
                    keptUnregistered.append(name)
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
            missingGroups: missingGroups,
            keptUnregistered: keptUnregistered
        )
    }
}
