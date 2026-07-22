//
//  SearchProviderConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tool for native web-search providers. One tool,
//  `osaurus_search`, fans out across five actions:
//   - list    — providers in fallback order with status
//   - add     — add a provider from the catalog (or a saved custom definition)
//   - remove  — remove a provider
//   - enable  — enable / disable a provider
//   - reorder — replace the default fallback ranking
//
//  Secrets NEVER travel through chat: adding a keyed provider returns
//  `needs_secrets: true`, directing the user to Settings → Search to paste
//  the API key. Custom definition JSON stays in the Settings editor.
//

import Foundation

enum SearchProviderConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "search_providers",
        displayName: "Web Search Providers",
        summary:
            "Configure native web-search providers (Tavily, Brave, free scrapers, …). This does not search the web or retrieve data.",
        menuHint: "add / remove / enable / reorder web-search providers",
        searchKeywords: [
            "search", "web search", "search provider", "search engine",
            "tavily", "brave search", "serper", "google search", "kagi",
            "duckduckgo", "add search provider", "search fallback",
            "search ranking", "search api key",
        ],
        exampleQueries: [
            "add tavily as a search provider",
            "which search providers are configured?",
            "disable the bing scraper",
            "make brave my primary search provider",
        ],
        tools: [
            OsaurusSearchTool()
        ],
        writeToolNames: [
            "osaurus_search"
        ]
    )
}

// MARK: - osaurus_search

public final class OsaurusSearchTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_search"
    public let description =
        "Configure native web-search providers only. This tool never searches the web or retrieves data; "
        + "use web_search/search_and_extract for research. `action`: list (providers in fallback order, plus addable "
        + "catalog entries), add (needs `id` from the catalog; keyed providers return `needs_secrets: true` — "
        + "send the user to Settings → Search for the API key, never accept secrets as arguments), "
        + "remove (needs `id`), enable / disable (needs `id`), reorder (needs `order`: array of provider ids, "
        + "first = primary; omitted providers keep their relative order after the listed ones)."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("list"), .string("add"), .string("remove"),
                    .string("enable"), .string("disable"), .string("reorder"),
                ]),
                "description": .string("Operation to perform."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string(
                    "Provider id (e.g. tavily, brave_api, ddg_scrape). Required for add / remove / enable / disable."
                ),
            ]),
            "order": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "Provider ids in the new fallback order. Required for reorder."
                ),
            ]),
            "enabled": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Optional override for enable/disable: defaults to true for `enable`, false for "
                        + "`disable`. Pass explicitly only to flip the opposite way."
                ),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireAction(
            args,
            allowed: ["list", "add", "remove", "enable", "disable", "reorder"]
        )
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "list": return await handleList()
        case "add": return await handleAdd(args)
        case "remove": return await handleRemove(args)
        case "enable", "disable": return await handleEnable(args, action: action)
        case "reorder": return await handleReorder(args)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    private func handleList() async -> String {
        // Envelope is rendered inside MainActor.run so only a Sendable
        // String crosses the actor boundary ([String: Any] is not Sendable).
        let toolName = name
        return await MainActor.run {
            let manager = SearchProviderManager.shared
            let configured = manager.configuredProviderIds
            let providers = manager.rankedProviders.enumerated().map { index, entry -> [String: Any] in
                let (provider, def) = entry
                var row: [String: Any] = [
                    "id": def.id,
                    "name": def.name,
                    "rank": index + 1,
                    "enabled": provider.enabled,
                    "free": def.isKeyless,
                    "categories": def.supportedCategories,
                ]
                if !def.isKeyless {
                    row["configured"] = configured.contains(def.id)
                }
                return row
            }
            let addable = manager.addableDefinitions.map { def -> [String: Any] in
                [
                    "id": def.id,
                    "name": def.name,
                    "needs_key": !def.isKeyless,
                    "categories": def.supportedCategories,
                ]
            }
            return ToolEnvelope.success(
                tool: toolName,
                result: [
                    "providers": providers,
                    "addable": addable,
                    "note": "Rank 1 is tried first; lower ranks are fallbacks.",
                ]
            )
        }
    }

    private func handleAdd(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "provider id", tool: name)
        guard case .value(let id) = idReq else { return idReq.failureEnvelope ?? "" }

        enum AddOutcome {
            case unknown
            case alreadyAdded
            case added(name: String, needsSecrets: Bool)
        }
        let outcome: AddOutcome = await MainActor.run {
            let manager = SearchProviderManager.shared
            guard let def = manager.definition(id: id) else { return .unknown }
            guard manager.configuration.provider(id: id) == nil else { return .alreadyAdded }
            manager.addProvider(definitionId: id)
            let needsSecrets = !def.isKeyless && !manager.configuredProviderIds.contains(def.id)
            return .added(name: def.name, needsSecrets: needsSecrets)
        }

        switch outcome {
        case .unknown:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "No search provider definition with id \(id). Use osaurus_search({action: 'list'}) to see addable ids.",
                field: "id",
                tool: name
            )
        case .alreadyAdded:
            return ToolEnvelope.success(
                tool: name,
                result: ["provider_id": id, "status": "already_added"]
            )
        case .added(let displayName, let needsSecrets):
            var result: [String: Any] = [
                "provider_id": id,
                "name": displayName,
                "status": "added",
                "needs_secrets": needsSecrets,
            ]
            if needsSecrets {
                result["next_steps"] = [
                    "\(displayName) needs an API key. Direct the user to Settings → Search to "
                        + "paste it; never accept secrets as tool arguments."
                ]
            }
            return ToolEnvelope.success(tool: name, result: result)
        }
    }

    private func handleRemove(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "provider id", tool: name)
        guard case .value(let id) = idReq else { return idReq.failureEnvelope ?? "" }

        let found: Bool = await MainActor.run {
            let manager = SearchProviderManager.shared
            guard manager.configuration.provider(id: id) != nil else { return false }
            manager.removeProvider(definitionId: id)
            return true
        }
        guard found else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No search provider found with id \(id).",
                field: "id",
                tool: name
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["provider_id": id, "status": "removed"]
        )
    }

    private func handleEnable(_ args: [String: Any], action: String) async -> String {
        let idReq = requireString(args, "id", expected: "provider id", tool: name)
        guard case .value(let id) = idReq else { return idReq.failureEnvelope ?? "" }
        // The action carries the intent; an explicit `enabled` boolean
        // overrides it, matching osaurus_mcp semantics.
        let enabled = coerceBool(args["enabled"]) ?? (action == "enable")

        let found: Bool = await MainActor.run {
            let manager = SearchProviderManager.shared
            guard manager.configuration.provider(id: id) != nil else { return false }
            manager.setEnabled(enabled, for: id)
            return true
        }
        guard found else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No search provider found with id \(id).",
                field: "id",
                tool: name
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["provider_id": id, "status": enabled ? "enabled" : "disabled"]
        )
    }

    private func handleReorder(_ args: [String: Any]) async -> String {
        let raw = args["order"] as? [Any] ?? []
        let order = raw.compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard !order.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`order` must be a non-empty array of provider ids.",
                field: "order",
                tool: name
            )
        }

        let ranking: [String] = await MainActor.run {
            let manager = SearchProviderManager.shared
            manager.setDefaultRanking(order)
            return manager.rankedProviders.map { $0.definition.id }
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["status": "reordered", "ranking": ranking]
        )
    }
}
