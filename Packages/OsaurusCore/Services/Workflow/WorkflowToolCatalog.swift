//
//  WorkflowToolCatalog.swift
//  osaurus
//
//  The tools a workflow step may call on this Mac: every registered tool
//  except workflow, Architect, capability-loader, and agent-loop control
//  tools. The Architect reads it to write tool steps with exact argument
//  schemas, and Edit Step lists it for a tool step.
//

import Foundation

@MainActor
enum WorkflowToolCatalog {

    struct Entry: Equatable, Sendable, Identifiable {
        var name: String
        var description: String
        var parameters: JSONValue?
        var outputSchema: JSONValue?
        /// The MCP server or plugin providing the tool; nil for built-ins.
        var group: PortableToolGroup?

        var id: String { name }

        /// The reference a node stores, with its provider so setup can
        /// require the server or plugin.
        var ref: ToolRef {
            switch group {
            case .mcpServer(let server)?: return ToolRef(name: name, server: server)
            case .plugin(let plugin)?: return ToolRef(name: name, plugin: plugin)
            case nil: return ToolRef(name: name)
            }
        }

        var providerLabel: String {
            switch group {
            case .mcpServer(let server)?: return "mcp:\(server)"
            case .plugin(let plugin)?: return "plugin:\(plugin)"
            case nil: return "builtin"
            }
        }

        var json: JSONValue {
            var o: [String: JSONValue] = [
                "name": .string(name),
                "description": .string(description),
                "provider": .string(providerLabel),
            ]
            if let parameters { o["parameters"] = parameters }
            if let outputSchema { o["output_schema"] = outputSchema }
            return .object(o)
        }

        /// Name, provider, and the description's first sentence.
        var summaryJSON: JSONValue {
            .object(["name": .string(name), "provider": .string(providerLabel), "summary": .string(summary)])
        }

        var summary: String {
            let firstLine = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let sentence = firstLine.range(of: ". ").map { String(firstLine[..<$0.lowerBound]) + "." } ?? firstLine
            return sentence.count > 160 ? String(sentence.prefix(157)) + "…" : sentence
        }
    }

    /// Eligible tools, sorted by name. With a `query`, tools matching any of
    /// its words in their name, description, or provider (case-insensitive),
    /// most matched words first, a name match breaking ties.
    static func entries(query: String? = nil) -> [Entry] {
        ensureRegistered()
        let registry = ToolRegistry.shared
        let all = registry.listTools().compactMap { tool -> Entry? in
            guard !WorkflowValidator.isExcludedFromWorkflows(tool.name) else { return nil }
            return Entry(
                name: tool.name, description: tool.description, parameters: tool.parameters,
                outputSchema: registry.outputSchema(forTool: tool.name),
                group: registry.portableToolGroup(for: tool.name))
        }
        let terms = Set(
            (query ?? "").lowercased().split { $0.isWhitespace || $0 == "," }.map(String.init).filter { !$0.isEmpty })
        guard !terms.isEmpty else { return all }
        let scored = all.compactMap { entry -> (Entry, Int, Int)? in
            let name = entry.name.lowercased()
            let haystack = "\(name) \(entry.description.lowercased()) \(entry.providerLabel.lowercased())"
            let hits = terms.filter(haystack.contains).count
            guard hits > 0 else { return nil }
            return (entry, hits, terms.filter(name.contains).count)
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 > b.2 }
            return a.0.name < b.0.name
        }.map(\.0)
    }

    /// Folder tools register on the first folder mount; a workflow runs
    /// them in its own folder, so they must exist before any chat has one.
    static func ensureRegistered() {
        FolderToolManager.shared.ensureFolderToolsRegistered()
    }

    static func entry(named name: String) -> Entry? {
        entries().first { $0.name == name }
    }

    /// The output schema `name` publishes, for `WorkflowValidator.warnings`.
    static func publishedOutputSchema(_ name: String) -> JSONValue? {
        ensureRegistered()
        return ToolRegistry.shared.outputSchema(forTool: name)
    }

    /// How a step's tool will behave on this Mac, for setup and detail
    /// screens: missing, off, or its permission policy.
    static func status(of name: String) -> String {
        ensureRegistered()
        let registry = ToolRegistry.shared
        guard registry.isRegistered(name) else { return L("Not on this Mac") }
        if registry.isDynamicRegisteredTool(named: name), !registry.isGlobalEnabled(name) { return L("Turned off") }
        switch registry.policyInfo(for: name)?.effectivePolicy {
        case .deny?: return L("Denied")
        case .ask?: return L("Asks before running")
        case .auto?, nil:
            return selfGatingToolNames.contains(name) ? L("Confirms actions as it works") : L("Runs without asking")
        }
    }

    /// Tools whose `.auto` policy only skips the call-level card: they ask
    /// before each risky action inside their own run.
    static let selfGatingToolNames: Set<String> = [
        BrowserUseTool.toolName, ComputerUseTool.toolName, AppleScriptTool.toolName,
    ]
}
