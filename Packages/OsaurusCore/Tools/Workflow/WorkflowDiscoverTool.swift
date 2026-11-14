//
//  WorkflowDiscoverTool.swift
//  osaurus
//
//  What the Architect reaches for before building an integration from
//  scratch: MCP servers in the Osaurus directory, an API's OpenAPI or
//  Swagger description compacted to what a workflow needs, published
//  workflows on the registry and the person's own library to adopt, and
//  the models that can serve each of the draft's slots.
//  Read-only except `adopt`, which replaces the draft's graph.
//

import Foundation
import Yams

final class WorkflowDiscoverTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "workflow_discover"
    let name = WorkflowDiscoverTool.toolName
    let description =
        "Find what to build on before writing steps. `mcp` searches the Osaurus MCP directory and marks the "
        + "servers already connected. `docs` fetches an OpenAPI or Swagger file (JSON or YAML) and returns its "
        + "endpoints, parameters, and auth, compacted; `find` narrows it. It reads a published https description "
        + "file, never the API itself: to see what an endpoint returns, build its `http` step and test it. `templates` searches the person's "
        + "library; `registry` published workflows. `adopt` copies a library or registry workflow into this "
        + "draft to adapt (the draft stops editing any saved workflow). `models` lists, for each model slot, "
        + "the models on this Mac and connected providers that can serve it, and the ones that cannot, with why. "
        + "`agents` lists the agents an `agent` step can ask (this Mac's and those shared in workspaces) with "
        + "the exact spec to write."

    static let maxDocsBytes = 2 * 1024 * 1024

    /// Network seam for tests: returns the body, content type, and final URL.
    nonisolated(unsafe) static var fetch: @Sendable (URL) async throws -> Fetched = { url in
        try await liveFetch(url)
    }

    struct Fetched: Sendable {
        var data: Data
        var contentType: String?
        var url: URL
    }

    enum Failure: Error, LocalizedError {
        case insecure(String)
        case privateAddress(String, String)
        case status(Int)
        case tooLarge
        case notText

        var errorDescription: String? {
            switch self {
            case .insecure(let url):
                return "Only https description files are fetched; \(url) is not. To see what an endpoint returns, "
                    + "build its `http` step and run `workflow_test`."
            case .privateAddress(let url, let reason):
                return "\(url) points at a private or local address, which the Architect does not fetch. (\(reason))"
            case .status(let code): return "The server answered HTTP \(code)."
            case .tooLarge: return "The page is larger than 2 MB."
            case .notText: return "The response is not text."
            }
        }
    }

    /// Why `url` may not be fetched for docs, or nil when it may: https
    /// only, and never a loopback, private, link-local, carrier-NAT, or
    /// multicast address (`PluginHostContext.checkSSRF`), since the model
    /// chooses the URL. Applied to the first request and to every
    /// redirect hop.
    static func docsURLProblem(_ url: URL) -> Failure? {
        guard url.scheme?.lowercased() == "https", !(url.host ?? "").isEmpty else {
            return .insecure(url.absoluteString)
        }
        if let blocked = PluginHostContext.checkSSRF(url: url) { return .privateAddress(url.absoluteString, blocked) }
        return nil
    }

    /// Refuses a redirect whose target fails `docsURLProblem`.
    final class DocsRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _refused: Failure?
        var refused: Failure? {
            lock.lock()
            defer { lock.unlock() }
            return _refused
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let url = request.url, let problem = WorkflowDiscoverTool.docsURLProblem(url) {
                lock.lock()
                _refused = problem
                lock.unlock()
                completionHandler(nil)
            } else {
                completionHandler(request)
            }
        }
    }

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("mcp"), .string("docs"), .string("registry"), .string("templates"), .string("adopt"),
                    .string("models"), .string("agents"),
                ]),
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string(
                    "For `mcp`, `registry`, `templates`: words to search for (service or task name)."),
            ]),
            "url": .object([
                "type": .string("string"),
                "description": .string(
                    "For `docs`: an https OpenAPI or Swagger description file, never an API endpoint. For `adopt`: a registry template URL from a `registry` result."),
            ]),
            "find": .object([
                "type": .string("string"),
                "description": .string(
                    "For `docs`: only endpoints whose path, summary, or operation id mention these words."),
            ]),
            "template": .object([
                "type": .string("string"),
                "description": .string("For `adopt`: a library workflow's name (from `templates`)."),
            ]),
            "slot": .object([
                "type": .string("string"),
                "description": .string("For `models`: one slot. Without it, every slot the draft uses."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("For `mcp`, `registry`, `templates`: results to return (default 10, max 25)."),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let gate = ArchitectToolGate.failure(tool: name) { return gate }
        let args: [String: JSONValue]
        switch ArchitectToolGate.arguments(argumentsJSON, tool: name) {
        case .success(let a): args = a
        case .failure(let f): return f.envelope
        }
        let tool = name
        let action = args["action"]?.stringValue ?? ""
        let limit = min(max(args["limit"]?.numberValue.map { Int($0) } ?? 10, 1), 25)
        let query = (args["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "mcp":
            guard !query.isEmpty else { return Self.needs("query", for: action, tool: tool) }
            return await Self.mcp(query: query, limit: limit, tool: tool)
        case "docs":
            guard let raw = args["url"]?.stringValue, let url = URL(string: raw.trimmingCharacters(in: .whitespaces))
            else { return Self.needs("url", for: action, tool: tool) }
            return await Self.docs(url: url, find: args["find"]?.stringValue, tool: tool)
        case "registry":
            guard !query.isEmpty else { return Self.needs("query", for: action, tool: tool) }
            return await Self.registry(query: query, limit: limit, tool: tool)
        case "templates":
            return await MainActor.run {
                ToolEnvelope.success(tool: tool, result: ["templates": Self.templates(query: query, limit: limit)])
            }
        case "adopt":
            return await Self.adopt(args, tool: tool)
        case "models":
            let slot = args["slot"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            return await Self.models(slot: slot?.isEmpty == true ? nil : slot, tool: tool)
        case "agents":
            return await Self.agents(tool: tool)
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "Unknown action `\(action)`.", field: "action",
                expected: "mcp | docs | registry | templates | adopt | models | agents", tool: tool)
        }
    }

    // MARK: - agents

    /// The agents an `agent` step can ask: this Mac's, then those shared in
    /// each workspace, with the exact `agent` spec to write for each.
    @MainActor
    static func agents(tool: String) async -> String {
        let roster = WorkspaceRosterStore.shared
        if roster.lastRefreshedAt == nil { await roster.refresh(reason: .manual) }
        let local = AgentManager.shared.agents.filter { $0.id != Agent.defaultId }.map { agent -> [String: Any] in
            ["name": agent.name, "spec": ["agent": agent.name]]
        }
        var shared: [[String: Any]] = []
        for entry in roster.rosters {
            for agent in entry.agents {
                let ref = WorkspaceAgentRef(workspaceId: entry.id, agentAddress: agent.agentAddress)
                let name = agent.displayName ?? AgentTargetResolver.displayName(for: ref)
                shared.append([
                    "name": name, "workspace": entry.workspace.name,
                    "hosted_here": roster.isHostedHere(address: ref.agentAddress),
                    "spec": [
                        "agent": name,
                        "workspace": ["workspace_id": ref.workspaceId, "agent_address": ref.agentAddress],
                    ] as [String: Any],
                ])
            }
        }
        return ToolEnvelope.success(
            tool: tool,
            result: [
                "local": local, "shared": shared,
                "hint":
                    "Copy an entry's `spec` under `agent` and add `task`. Prefer a shared entry when the workflow will be shared with a workspace: members reach the same agent, and on its own Mac it still runs locally.",
            ])
    }

    // MARK: - models

    /// For each slot the draft uses (or the one named), the models that can
    /// serve it and the ones that cannot, grouped by why: the same lists the
    /// setup wizard's picker shows.
    @MainActor
    static func models(slot: String?, tool: String) async -> String {
        guard let draft = ArchitectToolGate.currentDraft() else {
            return ToolEnvelope.failure(kind: .unavailable, message: "No draft in this chat yet.", tool: tool)
        }
        let cache = ModelPickerItemCache.shared
        if !cache.isLoaded { await cache.prewarmModelCache() }
        let catalog = SetupChecker.Environment.live().modelCatalog
        func row(_ item: ModelPickerItem) -> [String: Any] {
            [
                "id": item.id, "name": item.displayName,
                "runs": SetupChecker.isLocalModel(item.id, catalog: catalog) ? "this_mac" : "cloud",
            ]
        }
        var slots = draft.template().requirements.models
        for declared in draft.definition.modelSlots where !slots.contains(where: { $0.slot == declared.slot }) {
            slots.append(declared)
        }
        if let slot {
            slots = slots.filter { $0.slot == slot }
            if slots.isEmpty { slots = [ModelRequirement(slot: slot)] }
        }
        if slots.isEmpty {
            let all = WorkflowModelChoices.items().filter { StructuredOutputCapability.support(for: $0.id) == .supported }
            return ToolEnvelope.success(
                tool: tool,
                result: [
                    "slots": [] as [Any], "models": all.map(row),
                    "hint": "No step uses a model yet. Name a slot on an inference step, then declare it with `declare_slot`.",
                ])
        }
        let rows = slots.map { requirement -> [String: Any] in
            var out: [String: Any] = [
                "slot": requirement.slot, "strictness": requirement.strictness.rawValue,
                "locality": requirement.locality.rawValue, "needs_tool_use": requirement.needsToolUse,
                "usable": WorkflowModelChoices.choices(for: requirement).usable.map(row),
            ]
            if let preferred = requirement.preferred {
                out["preferred"] = preferred
                if let item = WorkflowModelChoices.items().first(where: { $0.id == preferred }) {
                    if let reason = WorkflowModelChoices.unusableReason(item, for: requirement) {
                        out["preferred_problem"] = reason
                    }
                } else {
                    out["preferred_problem"] = "Not on this Mac or a connected provider"
                }
            }
            let hidden = WorkflowModelChoices.unusable(for: requirement)
            if !hidden.isEmpty {
                out["unusable"] = hidden.map { ["reason": $0.reason, "models": $0.items.map(\.id)] as [String: Any] }
            }
            return out
        }
        return ToolEnvelope.success(
            tool: tool,
            result: [
                "slots": rows,
                "hint":
                    "Set the slot's model with `declare_slot {slot, preferred, strictness}`: `preferred` lets the person pick another model at setup; `always` makes the model a prerequisite.",
            ])
    }

    private static func needs(_ field: String, for action: String, tool: String) -> String {
        ToolEnvelope.failure(kind: .invalidArgs, message: "`\(action)` needs `\(field)`.", field: field, tool: tool)
    }

    // MARK: - mcp

    struct MCPResult: Encodable, Equatable {
        var name: String
        var source: String
        var description: String
        var url: String?
        var auth: String?
        var directoryID: String?
        var category: String?
        var packages: [String]
        var connected: Bool
        var localName: String?

        enum CodingKeys: String, CodingKey {
            case name, source, description, url, auth, category, packages, connected
            case directoryID = "directory_id"
            case localName = "local_name"
        }
    }

    static func mcp(query: String, limit: Int, tool: String) async -> String {
        let local = await MainActor.run { MCPServerResolution.liveServers().filter(\.enabled) }
        var results = Array(directoryMatches(query: query, local: local).prefix(limit))
        for i in results.indices {
            if let match = local.first(where: { server in
                (results[i].url.map { sameEndpoint($0, server.url) } ?? false)
                    || server.name.lowercased() == results[i].name.lowercased()
            }) {
                results[i].connected = true
                results[i].localName = match.name
            }
        }
        return ToolEnvelope.success(
            tool: tool,
            result: [
                "query": query, "count": results.count,
                "servers": results.map(ArchitectToolGate.foundation),
                "hint": results.isEmpty
                    ? "No directory server matches. Build `http` steps from the API's OpenAPI description (`docs`)."
                    : "Declare the one you use with `declare_server {name, directory_id | url}` so setup can connect it on another Mac.",
            ])
    }

    static func directoryMatches(query: String, local: [MCPServerResolution.LocalServer]) -> [MCPResult] {
        let words = searchWords(query)
        return MCPProviderTemplate.allTemplates
            .map { entry -> (MCPResult, Int) in
                let hay = [entry.displayName, entry.tagline, entry.category.displayName, entry.id].joined(separator: " ")
                    .lowercased()
                let score = words.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
                    + (entry.displayName.lowercased().contains(query.lowercased()) ? 2 : 0)
                let result = MCPResult(
                    name: entry.displayName, source: "directory", description: entry.tagline, url: entry.url,
                    auth: entry.authType.rawValue, directoryID: entry.id, category: entry.category.displayName,
                    packages: [], connected: false, localName: nil)
                return (result, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func sameEndpoint(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        return !a.isEmpty && norm(a) == norm(b)
    }

    static func searchWords(_ query: String) -> [String] {
        query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
    }

    // MARK: - docs

    static func docs(url: URL, find: String?, tool: String) async -> String {
        if let problem = docsURLProblem(url) {
            return ToolEnvelope.failure(kind: .invalidArgs, message: problem.localizedDescription, field: "url", tool: tool)
        }
        let fetched: Fetched
        do {
            fetched = try await fetch(url)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError, message: "Could not fetch \(url.absoluteString): \(error.localizedDescription)",
                tool: tool)
        }
        guard let text = String(data: fetched.data, encoding: .utf8) ?? String(data: fetched.data, encoding: .isoLatin1)
        else {
            return ToolEnvelope.failure(kind: .executionError, message: Failure.notText.localizedDescription, tool: tool)
        }
        guard let api = OpenAPISummary.parse(text) else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message:
                    "\(fetched.url.absoluteString) is not an OpenAPI or Swagger document. Ask the person for the API's "
                    + "OpenAPI URL (often `openapi.json` or `swagger.json` next to its reference), or work from the "
                    + "API description they pasted.",
                field: "url", tool: tool)
        }
        let find = find?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = api.compact(find: find)
        return ToolEnvelope.success(tool: tool, result: summary.merging(["url": fetched.url.absoluteString]) { a, _ in a })
    }

    // MARK: - registry

    struct RegistryResult: Encodable, Equatable {
        var id: String
        var slug: String
        var name: String
        var summary: String
        var author: String?
        var version: Int
        var nodeCount: Int?
        var installCount: Int?
        var templateURL: String

        enum CodingKeys: String, CodingKey {
            case id, slug, name, summary, author, version
            case nodeCount = "node_count"
            case installCount = "install_count"
            case templateURL = "template_url"
        }
    }

    static func registry(query: String, limit: Int, tool: String) async -> String {
        let base = WorkflowsRegistryAPIClient.defaultBaseURL
        var components = URLComponents(url: base.appendingPathComponent("workflows"), resolvingAgainstBaseURL: false)!
        // The registry also lists agent templates; only workflows can be adopted into a draft.
        components.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "kind", value: TemplateKind.workflow.rawValue),
        ]
        do {
            let fetched = try await fetch(components.url!)
            let results = try parseRegistryWorkflows(fetched.data, base: base)
            return ToolEnvelope.success(
                tool: tool,
                result: [
                    "query": query, "count": results.count, "workflows": results.map(ArchitectToolGate.foundation),
                    "hint": "`adopt` with a `template_url` copies one into this draft to adapt.",
                ])
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError, message: "The store registry could not be searched: \(error.localizedDescription)",
                tool: tool)
        }
    }

    static func parseRegistryWorkflows(_ data: Data, base: URL) throws -> [RegistryResult] {
        struct Author: Decodable { let display_name: String?; let name: String?; let address: String? }
        struct Item: Decodable {
            let id: String; let kind: String?; let slug: String?; let name: String; let summary: String?
            let author: Author?; let latest_version: Int?; let node_count: Int?; let install_count: Int?
        }
        struct Page: Decodable { let items: [Item] }
        let page = try JSONDecoder().decode(Page.self, from: data)
        return page.items.compactMap { item in
            guard let version = item.latest_version, let id = UUID(uuidString: item.id),
                (item.kind ?? TemplateKind.workflow.rawValue) == TemplateKind.workflow.rawValue
            else { return nil }
            let url = base.appendingPathComponent("workflows").appendingPathComponent(id.uuidString.lowercased())
                .appendingPathComponent("versions").appendingPathComponent(String(version))
                .appendingPathComponent("template.json")
            return RegistryResult(
                id: id.uuidString.lowercased(), slug: item.slug ?? "", name: item.name, summary: item.summary ?? "",
                author: item.author?.display_name ?? item.author?.name ?? item.author?.address, version: version,
                nodeCount: item.node_count, installCount: item.install_count, templateURL: url.absoluteString)
        }
    }

    // MARK: - templates

    @MainActor
    static func templates(query: String, limit: Int) -> [[String: Any]] {
        let words = searchWords(query)
        let installed = InstalledWorkflowStore.shared
        return TemplateStore.shared.allTemplates(kind: .workflow)
            .map { template -> ([String: Any], Int) in
                let installedCopy = installed.workflow(templateID: template.id)
                let tags = installedCopy?.tags ?? []
                let hay = ([template.name, template.summary ?? ""] + tags).joined(separator: " ").lowercased()
                let score = words.isEmpty ? 1 : words.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
                var row: [String: Any] = [
                    "name": template.name, "version": template.version, "summary": template.summary ?? "",
                    "node_count": template.workflow?.nodes.count ?? 0,
                    "installed": installedCopy != nil,
                ]
                if !tags.isEmpty { row["tags"] = tags }
                if let def = template.workflow {
                    row["steps"] = def.nodes.map { "\($0.id) (\($0.kind.map(Self.kindName) ?? "placeholder"))" }
                }
                return (row, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    static func kindName(_ kind: NodeKind) -> String {
        switch kind {
        case .inference: return "inference"
        case .dialog: return "dialog"
        case .code: return "code"
        case .tool: return "tool"
        case .http: return "http"
        case .wait: return "wait"
        case .map: return "map"
        case .workflow: return "workflow"
        case .state: return "state"
        case .reply: return "reply"
        case .media: return "media"
        case .agent: return "agent"
        }
    }

    // MARK: - adopt

    static func adopt(_ args: [String: JSONValue], tool: String) async -> String {
        let template: Template
        let source: String
        if let name = args["template"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            guard let found = await MainActor.run(body: { TemplateStore.shared.template(named: name, kind: .workflow) })
            else {
                return ToolEnvelope.failure(
                    kind: .notFound, message: "No library workflow named \"\(name)\". Use `templates` to list them.",
                    field: "template", tool: tool)
            }
            template = found
            source = "library"
        } else if let raw = args["url"]?.stringValue, let url = URL(string: raw.trimmingCharacters(in: .whitespaces)) {
            guard WorkflowsRegistryAPIClient.isRegistryTemplateURL(url) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`adopt` takes a `template_url` from a `registry` result, not an arbitrary URL.",
                    field: "url", tool: tool)
            }
            do {
                let fetched = try await TemplateImportRouter.fetch(url)
                template = try Template.parse(fetched.text)
            } catch {
                return ToolEnvelope.failure(
                    kind: .executionError, message: "Could not fetch the workflow: \(error.localizedDescription)", tool: tool)
            }
            source = "registry"
        } else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`adopt` needs `template` (a library name) or `url` (a registry template URL).",
                tool: tool)
        }
        guard let definition = template.workflow else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "\"\(template.name)\" is not a workflow template.", tool: tool)
        }
        return await MainActor.run {
            guard let draft = ArchitectToolGate.currentDraft() else {
                return ToolEnvelope.failure(kind: .unavailable, message: "No draft in this chat yet.", tool: tool)
            }
            let wasEditing = draft.templateID.flatMap { TemplateStore.shared.latest(id: $0)?.name }
            guard WorkflowDraftStore.shared.adopt(draft.id, template: template, source: source) != nil else {
                return ToolEnvelope.failure(kind: .executionError, message: "The draft could not take the workflow.", tool: tool)
            }
            let issues = WorkflowValidator.validate(definition, allowPlaceholders: true)
            var out: [String: Any] = [
                "adopted": template.name, "source": source, "version": template.version,
                "node_count": definition.nodes.count, "nodes": definition.nodes.map(\.id),
                "secrets": definition.secrets.map(\.key), "model_slots": definition.modelSlots.map(\.slot),
                "mcp_servers": template.serverHints.map(\.name),
                "issues": ArchitectToolGate.issueList(issues),
                "next": "Review each step against what the person asked, rename the workflow, and run `workflow_test` before proposing a save.",
            ]
            if let wasEditing { out["detached_from"] = wasEditing }
            return ToolEnvelope.success(tool: tool, result: out)
        }
    }

    // MARK: - Network

    static func liveFetch(_ url: URL) async throws -> Fetched {
        if let problem = docsURLProblem(url) { throw problem }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        let guardDelegate = DocsRedirectGuard()
        let session = GlobalProxySettings.makeSession(base: config, delegate: guardDelegate)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(
            "application/json, application/yaml, application/x-yaml, text/yaml, text/plain;q=0.8, */*;q=0.5",
            forHTTPHeaderField: "Accept")
        request.setValue("Osaurus Architect", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        if let refused = guardDelegate.refused { throw refused }
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        if response.expectedContentLength > Int64(maxDocsBytes) { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxDocsBytes { throw Failure.tooLarge }
        }
        return Fetched(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"), url: response.url ?? url)
    }
}

// MARK: - OpenAPI

/// The parts of an OpenAPI 3.x or Swagger 2 document a workflow author
/// needs: servers, security schemes, and each operation's method, path,
/// summary, parameters, body content types, and success response shape.
struct OpenAPISummary {
    struct Operation {
        var method: String
        var path: String
        var summary: String
        var operationID: String?
        var parameters: [String]
        var requestBody: [String]
        var responseFields: [String]
        var security: [String]
    }

    var title: String
    var version: String?
    var servers: [String]
    var securitySchemes: [String: String]
    var operations: [Operation]

    /// nil when the text is not an OpenAPI/Swagger document.
    static func parse(_ text: String) -> OpenAPISummary? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var root: [String: Any]?
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = object
        } else if !trimmed.hasPrefix("<"), trimmed.contains("openapi") || trimmed.contains("swagger"),
            let loaded = try? YAMLLoading.load(trimmed) as? [String: Any]
        {
            root = loaded
        }
        guard let doc = root, doc["openapi"] != nil || doc["swagger"] != nil, let paths = doc["paths"] as? [String: Any]
        else { return nil }

        let info = doc["info"] as? [String: Any]
        var servers = ((doc["servers"] as? [[String: Any]]) ?? []).compactMap { $0["url"] as? String }
        if servers.isEmpty, let host = doc["host"] as? String {
            let scheme = ((doc["schemes"] as? [String])?.first) ?? "https"
            servers = ["\(scheme)://\(host)\((doc["basePath"] as? String) ?? "")"]
        }
        var schemes: [String: String] = [:]
        let components = doc["components"] as? [String: Any]
        let rawSchemes = (components?["securitySchemes"] as? [String: Any]) ?? (doc["securityDefinitions"] as? [String: Any]) ?? [:]
        for (name, value) in rawSchemes {
            guard let scheme = value as? [String: Any] else { continue }
            var parts: [String] = []
            if let type = scheme["type"] as? String { parts.append(type) }
            if let s = scheme["scheme"] as? String { parts.append(s) }
            if let location = scheme["in"] as? String, let header = scheme["name"] as? String { parts.append("\(location) \(header)") }
            if let flows = scheme["flows"] as? [String: Any] {
                for (flow, v) in flows {
                    guard let f = v as? [String: Any] else { continue }
                    var line = flow
                    if let a = f["authorizationUrl"] as? String { line += " authorize=\(a)" }
                    if let t = f["tokenUrl"] as? String { line += " token=\(t)" }
                    if let scopes = f["scopes"] as? [String: Any], !scopes.isEmpty {
                        line += " scopes=\(scopes.keys.sorted().joined(separator: ","))"
                    }
                    parts.append(line)
                }
            }
            schemes[name] = parts.joined(separator: " ")
        }
        let globalSecurity = securityNames(doc["security"])

        var operations: [Operation] = []
        for (path, value) in paths {
            guard let item = value as? [String: Any] else { continue }
            let shared = (item["parameters"] as? [[String: Any]]) ?? []
            for method in ["get", "post", "put", "patch", "delete", "head", "options"] {
                guard let op = item[method] as? [String: Any] else { continue }
                let params = shared + ((op["parameters"] as? [[String: Any]]) ?? [])
                let parameters = params.compactMap { p -> String? in
                    guard let name = p["name"] as? String else { return nil }
                    let location = (p["in"] as? String) ?? ""
                    let required = (p["required"] as? Bool) == true ? "*" : ""
                    return "\(name)\(required) (\(location))"
                }
                var body: [String] = []
                if let rb = op["requestBody"] as? [String: Any], let content = rb["content"] as? [String: Any] {
                    body = content.keys.sorted()
                    if let json = content["application/json"] as? [String: Any], let schema = json["schema"] as? [String: Any] {
                        body += fieldNames(schema, components: components).map { "." + $0 }
                    }
                } else if let bodyParam = params.first(where: { ($0["in"] as? String) == "body" }),
                    let schema = bodyParam["schema"] as? [String: Any]
                {
                    body = ["application/json"] + fieldNames(schema, components: components).map { "." + $0 }
                }
                var response: [String] = []
                if let responses = op["responses"] as? [String: Any] {
                    for code in ["200", "201", "default"] {
                        guard let r = responses[code] as? [String: Any] else { continue }
                        if let content = r["content"] as? [String: Any],
                            let json = (content["application/json"] as? [String: Any]) ?? content.values.first as? [String: Any],
                            let schema = json["schema"] as? [String: Any]
                        {
                            response = fieldNames(schema, components: components)
                        } else if let schema = r["schema"] as? [String: Any] {
                            response = fieldNames(schema, components: components)
                        }
                        if !response.isEmpty { break }
                    }
                }
                let security = op["security"] == nil ? globalSecurity : securityNames(op["security"])
                operations.append(
                    Operation(
                        method: method.uppercased(), path: path,
                        summary: (op["summary"] as? String) ?? (op["description"] as? String)?.prefix(140).description ?? "",
                        operationID: op["operationId"] as? String, parameters: parameters, requestBody: body,
                        responseFields: response, security: security))
            }
        }
        operations.sort { ($0.path, $0.method) < ($1.path, $1.method) }
        return OpenAPISummary(
            title: (info?["title"] as? String) ?? "API", version: info?["version"] as? String, servers: servers,
            securitySchemes: schemes, operations: operations)
    }

    private static func securityNames(_ value: Any?) -> [String] {
        ((value as? [[String: Any]]) ?? []).flatMap { $0.keys }.sorted()
    }

    /// Top-level property names of a schema, following one `$ref` level and
    /// array items; `[]` marks an array.
    static func fieldNames(_ schema: [String: Any], components: [String: Any]?, depth: Int = 0) -> [String] {
        guard depth < 3 else { return [] }
        if let ref = schema["$ref"] as? String {
            let name = ref.split(separator: "/").last.map(String.init) ?? ref
            let pool = (components?["schemas"] as? [String: Any]) ?? [:]
            if let target = pool[name] as? [String: Any] { return fieldNames(target, components: components, depth: depth + 1) }
            return [name]
        }
        if let items = schema["items"] as? [String: Any] {
            return ["[]"] + fieldNames(items, components: components, depth: depth + 1)
        }
        if let properties = schema["properties"] as? [String: Any] {
            let required = Set((schema["required"] as? [String]) ?? [])
            return properties.keys.sorted().map { required.contains($0) ? "\($0)*" : $0 }
        }
        if let all = schema["allOf"] as? [[String: Any]] {
            return all.flatMap { fieldNames($0, components: components, depth: depth + 1) }
        }
        if let type = schema["type"] as? String { return ["(\(type))"] }
        return []
    }

    /// The Foundation form the tool returns; `find` keeps operations whose
    /// path, summary, or operation id mention any of the words.
    func compact(find: String?) -> [String: Any] {
        var ops = operations
        var matched: Int?
        if let find, !find.isEmpty {
            let words = WorkflowDiscoverTool.searchWords(find)
            ops = ops.filter { op in
                let hay = [op.path, op.summary, op.operationID ?? ""].joined(separator: " ").lowercased()
                return words.contains { hay.contains($0) }
            }
            matched = ops.count
        }
        let limit = 80
        let rows = ops.prefix(limit).map { op -> [String: Any] in
            var row: [String: Any] = ["method": op.method, "path": op.path]
            if !op.summary.isEmpty { row["summary"] = op.summary }
            if let id = op.operationID { row["operation_id"] = id }
            if !op.parameters.isEmpty { row["parameters"] = op.parameters }
            if !op.requestBody.isEmpty { row["request_body"] = op.requestBody }
            if !op.responseFields.isEmpty { row["response"] = op.responseFields }
            if !op.security.isEmpty { row["security"] = op.security }
            return row
        }
        var out: [String: Any] = [
            "kind": "openapi", "title": title, "servers": servers, "security_schemes": securitySchemes,
            "operation_count": operations.count, "operations": rows, "truncated": ops.count > limit,
        ]
        if let version { out["version"] = version }
        if let matched { out["matched"] = matched }
        return out
    }
}
