//
//  MCPServerResolution.swift
//  osaurus
//
//  Which server on this Mac a template's MCP server name means, and how to
//  get one when there is none. Templates name servers the way their author
//  did ("Linear", "linear", "Linear (work)"); this Mac may call the same
//  server something else. Resolution order:
//    1. the install binding (template name -> local name),
//    2. a configured server with the same name, ignoring case and
//       punctuation, or with the hint's / directory entry's endpoint,
//    3. an MCP Directory entry with that name or endpoint,
//    4. the template's hint (custom endpoint or command),
//    5. nothing known.
//
//  A server bound under another name exposes its tools under another
//  prefix (`linear_work_search` instead of `linear_search`), so the
//  bindings are applied to the graph before it is checked or run.
//

import Foundation

public enum MCPServerResolution {

    /// A configured server, as resolution needs it.
    public struct LocalServer: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var transport: MCPProviderTransport
        public var url: String
        public var command: String
        public var args: [String]
        public var enabled: Bool

        public init(
            id: UUID, name: String, transport: MCPProviderTransport = .http, url: String = "", command: String = "",
            args: [String] = [], enabled: Bool = true
        ) {
            self.id = id
            self.name = name
            self.transport = transport
            self.url = url
            self.command = command
            self.args = args
            self.enabled = enabled
        }

        public init(_ provider: MCPProvider) {
            self.init(
                id: provider.id, name: provider.name, transport: provider.transport, url: provider.url,
                command: provider.command, args: provider.args, enabled: provider.enabled)
        }
    }

    public enum Candidate: Equatable, Sendable {
        /// Connected here under `local`, tools registered.
        case ready(local: String)
        /// Configured here but not connected, or under a name the binding
        /// does not point at yet.
        case existing(LocalServer)
        /// Not configured; the MCP Directory knows it.
        case directory(MCPProviderTemplate)
        /// Not configured; the template says how to set it up.
        case hint(MCPServerHint)
        /// Not configured and nothing says how to set it up.
        case unknown
    }

    // MARK: - Matching

    /// Letters and digits only, lowercased: "Linear (work)" -> "linearwork".
    static func key(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Scheme-less, lowercased host and path without a trailing slash.
    static func endpointKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed), let host = components.host else {
            return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        return host.lowercased() + path.lowercased()
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        if a.caseInsensitiveCompare(b) == .orderedSame { return true }
        let ka = key(a)
        return !ka.isEmpty && ka == key(b)
    }

    /// The connected server a template server name runs on: the binding
    /// when it is connected, else a connected server with the same name.
    public static func localName(for name: String, bindings: [String: String], connected: Set<String>) -> String? {
        if let bound = bindings[name], connected.contains(bound) { return bound }
        if connected.contains(name) { return name }
        let matches = connected.filter { sameName($0, name) }
        return matches.count == 1 ? matches.first : nil
    }

    /// The directory entry a template server is.
    public static func directoryEntry(
        for name: String, hint: MCPServerHint?, directory: [MCPProviderTemplate]
    ) -> MCPProviderTemplate? {
        if let id = hint?.directoryID, let entry = directory.first(where: { $0.id == id }) { return entry }
        if let endpoint = hint?.url.flatMap(endpointKey),
            let entry = directory.first(where: { endpointKey($0.url) == endpoint })
        {
            return entry
        }
        return directory.first { sameName($0.displayName, name) || sameName($0.id, name) }
    }

    /// The configured server a template server is, by name or endpoint.
    static func configuredMatch(
        for name: String, hint: MCPServerHint?, directoryEntry: MCPProviderTemplate?, servers: [LocalServer]
    ) -> LocalServer? {
        let byName = servers.filter { sameName($0.name, name) }
        if byName.count == 1 { return byName[0] }
        if let exact = byName.first(where: { $0.name == name }) { return exact }
        let endpoints = [hint?.url, directoryEntry?.url].compactMap { $0.flatMap(endpointKey) }
        if !endpoints.isEmpty {
            let byURL = servers.filter { $0.transport == .http && endpointKey($0.url).map(endpoints.contains) == true }
            if let first = byURL.first { return first }
        }
        if let hint, hint.transport == .stdio, let command = hint.command, !command.isEmpty {
            let byCommand = servers.filter {
                $0.transport == .stdio && $0.command == command && $0.args == hint.args
            }
            if let first = byCommand.first { return first }
        }
        return nil
    }

    /// What this Mac has, or can get, for the template server `name`.
    public static func candidate(
        for name: String, hint: MCPServerHint?, bindings: [String: String], servers: [LocalServer],
        connected: Set<String>, directory: [MCPProviderTemplate]
    ) -> Candidate {
        if let bound = bindings[name] {
            if connected.contains(bound) { return .ready(local: bound) }
            if let server = servers.first(where: { $0.name == bound }) { return .existing(server) }
        }
        let entry = directoryEntry(for: name, hint: hint, directory: directory)
        if let server = configuredMatch(for: name, hint: hint, directoryEntry: entry, servers: servers) {
            return connected.contains(server.name) ? .ready(local: server.name) : .existing(server)
        }
        if let local = localName(for: name, bindings: bindings, connected: connected) { return .ready(local: local) }
        if let entry { return .directory(entry) }
        if let hint, hint.url?.isEmpty == false || hint.command?.isEmpty == false { return .hint(hint) }
        return .unknown
    }

    /// Bindings for every template server that unambiguously matches a
    /// connected server under a different name. Existing bindings win.
    public static func autoBindings(
        for template: Template, bindings: [String: String], servers: [LocalServer], connected: Set<String>,
        directory: [MCPProviderTemplate]
    ) -> [String: String] {
        var out = bindings
        for name in template.requirements.mcpServers where out[name] == nil {
            if case .ready(let local) = candidate(
                for: name, hint: template.serverHint(named: name), bindings: out, servers: servers,
                connected: connected, directory: directory), local != name
            {
                out[name] = local
            }
        }
        return out
    }

    // MARK: - Applying bindings

    /// `tool` as the bound server exposes it.
    static func rebound(_ tool: ToolRef, servers: [String: String]) -> ToolRef {
        guard let server = tool.server, let local = servers[server], local != server else { return tool }
        var copy = tool
        copy.server = local
        let from = MCPProviderTool.sanitizedProviderPrefix(from: server)
        let to = MCPProviderTool.sanitizedProviderPrefix(from: local)
        if !from.isEmpty, from != to, tool.name.hasPrefix(from + "_") {
            copy.name = (to.isEmpty ? "mcp" : to) + "_" + tool.name.dropFirst(from.count + 1)
        }
        return copy
    }

    /// The graph with every tool of a bound MCP server pointed at the local
    /// server and its tool names. Unbound servers are left alone.
    public static func applying(_ servers: [String: String], to def: WorkflowDefinition) -> WorkflowDefinition {
        guard servers.contains(where: { $0.key != $0.value }) else { return def }
        var copy = def
        func rebind(_ node: WorkflowNode) -> WorkflowNode {
            var n = node
            switch node.kind {
            case .tool(var spec):
                spec.tool = rebound(spec.tool, servers: servers)
                n.kind = .tool(spec)
            case .inference(var spec):
                if case .agentic(let tools, let maxSteps) = spec.mode {
                    spec.mode = .agentic(tools: tools.map { rebound($0, servers: servers) }, maxSteps: maxSteps)
                    n.kind = .inference(spec)
                }
            case .map(var spec):
                // The body is stored as JSON; rebind it as a node and keep
                // everything but the derived id and name.
                let body = rebind(spec.body(parentID: node.id))
                if case .object(var json) = WorkflowDraftPatcher.encode(body) {
                    json.removeValue(forKey: "id")
                    if spec.step.objectValue?["name"] == nil { json.removeValue(forKey: "name") }
                    spec.step = .object(json)
                    n.kind = .map(spec)
                }
            case .code, .dialog, .http, .wait, .workflow, .state, .reply, .media, .agent, nil:
                break
            }
            return n
        }
        copy.nodes = def.nodes.map(rebind)
        return copy
    }

    /// Template server name -> the connected server it runs on, for every
    /// required server that resolves here.
    public static func effectiveServers(
        for template: Template, bindings: [String: String], connected: Set<String>
    ) -> [String: String] {
        var out: [String: String] = [:]
        for name in template.requirements.mcpServers {
            if let local = localName(for: name, bindings: bindings, connected: connected) { out[name] = local }
        }
        return out
    }

    /// The template a run executes: its graph with `servers` applied. The
    /// content hash is not recomputed; runs never store it.
    public static func runnable(_ template: Template, servers: [String: String]) -> Template {
        guard let def = template.workflow, servers.contains(where: { $0.key != $0.value }) else { return template }
        var copy = template
        copy.payload = .workflow(applying(servers, to: def))
        return copy
    }

    /// Server names with tools registered here.
    static func connectedServers(in groups: [PortableToolGroup: [String]]) -> Set<String> {
        Set(groups.keys.compactMap { if case .mcpServer(let name) = $0 { return name } else { return nil } })
    }

    @MainActor
    public static func liveServers() -> [LocalServer] {
        MCPProviderManager.shared.configuration.providers.map(LocalServer.init)
    }

    @MainActor
    public static func liveConnected() -> Set<String> {
        connectedServers(in: ToolRegistry.shared.portableToolGroups())
    }

    @MainActor
    public static func liveCandidate(for name: String, in template: Template, bindings: InstallBindings) -> Candidate {
        candidate(
            for: name, hint: template.serverHint(named: name), bindings: bindings.mcpServers, servers: liveServers(),
            connected: liveConnected(), directory: MCPProviderTemplate.allTemplates)
    }

    /// `bindings` with every server this Mac already has under another
    /// name bound to it.
    @MainActor
    public static func liveAutoBindings(for template: Template, bindings: InstallBindings) -> InstallBindings {
        var copy = bindings
        copy.mcpServers = autoBindings(
            for: template, bindings: bindings.mcpServers, servers: liveServers(), connected: liveConnected(),
            directory: MCPProviderTemplate.allTemplates)
        return copy
    }

    /// `template` as it runs on this Mac under `bindings`.
    @MainActor
    public static func liveRunnable(_ template: Template, bindings: InstallBindings) -> Template {
        runnable(
            template, servers: effectiveServers(for: template, bindings: bindings.mcpServers, connected: liveConnected()))
    }
}
