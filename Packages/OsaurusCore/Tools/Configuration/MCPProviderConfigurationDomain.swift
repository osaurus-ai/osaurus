//
//  MCPProviderConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tool for remote MCP (Model Context Protocol)
//  tool providers. One tool, `osaurus_mcp`, fans out across three actions:
//   - add     — register an HTTP MCP server
//   - remove  — delete a registered MCP server
//   - enable  — enable / disable a registered MCP server
//
//  Scope is intentionally narrow and HTTP-only. stdio MCP servers launch
//  local subprocesses (`npx`, `uvx`, …) and carry real trust weight, so
//  they stay in Settings → Tools → Remote rather than chat. Secrets
//  (bearer tokens, OAuth) NEVER travel through chat: when a server needs
//  auth the tool registers it and returns `needs_secrets: true`, directing
//  the user to finish in Settings → Tools → Remote.
//

import Foundation

enum MCPProviderConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "mcp_providers",
        displayName: "MCP Tool Providers",
        summary: "Remote MCP (Model Context Protocol) tool servers. Add, remove, enable HTTP servers.",
        menuHint: "add / remove / enable remote MCP tool servers (HTTP)",
        searchKeywords: [
            "mcp", "mcp server", "mcp provider", "model context protocol",
            "tool server", "remote tools", "add mcp", "connect mcp server",
            "remove mcp", "disable mcp", "enable mcp",
        ],
        exampleQueries: [
            "add an MCP server",
            "connect a remote MCP tool server",
            "remove the github mcp server",
            "disable an mcp provider",
        ],
        tools: [
            OsaurusMCPTool()
        ],
        writeToolNames: [
            "osaurus_mcp"
        ]
    )
}

// MARK: - osaurus_mcp

public final class OsaurusMCPTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_mcp"
    public let description =
        "Manage remote HTTP MCP tool servers. `action`: add (needs `name` + `url`; optional `auth` ∈ "
        + "{none, bearer, oauth}; when auth is needed the response carries `needs_secrets: true` — send the "
        + "user to Settings → Tools → Remote, never accept secrets as arguments), remove (needs `id`), "
        + "enable (needs `id`; connects the server), disable (needs `id`; disconnects it). stdio servers are "
        + "not supported here."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("add"), .string("remove"), .string("enable"), .string("disable"),
                ]),
                "description": .string("Operation to perform."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string("MCP server UUID. Required for remove / enable / disable."),
            ]),
            "name": .object([
                "type": .string("string"),
                "description": .string("Display name. Required for add."),
            ]),
            "url": .object([
                "type": .string("string"),
                "description": .string("HTTP(S) endpoint URL. Required for add."),
            ]),
            "auth": .object([
                "type": .string("string"),
                "enum": .array([.string("none"), .string("bearer"), .string("oauth")]),
                "description": .string("Auth strategy for add. Defaults to none."),
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
        let actionReq = requireAction(args, allowed: ["add", "remove", "enable", "disable"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "add": return await handleAdd(args)
        case "remove": return await handleRemove(args)
        case "enable", "disable": return await handleEnable(args, action: action)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    private func handleAdd(_ args: [String: Any]) async -> String {
        let nameReq = requireString(args, "name", expected: "display name", tool: name)
        guard case .value(let displayName) = nameReq else { return nameReq.failureEnvelope ?? "" }

        let urlReq = requireString(args, "url", expected: "MCP server URL", tool: name)
        guard case .value(let urlString) = urlReq else { return urlReq.failureEnvelope ?? "" }

        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`url` must be a valid http(s) URL.",
                field: "url",
                tool: name
            )
        }

        let authRaw = (args["auth"] as? String)?.lowercased() ?? "none"
        let authType: MCPProviderAuthType
        switch authRaw {
        case "none", "": authType = .none
        case "bearer", "bearer_token", "token": authType = .bearerToken
        case "oauth": authType = .oauth
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`auth` must be one of: none, bearer, oauth.",
                field: "auth",
                tool: name
            )
        }

        let providerId: UUID = await MainActor.run {
            let provider = MCPProvider(
                name: displayName,
                url: urlString,
                enabled: true,
                authType: authType,
                transport: .http
            )
            // Secrets are never accepted via chat — `token: nil`.
            MCPProviderManager.shared.addProvider(provider, token: nil)
            return provider.id
        }

        let canonicalAuth: String
        switch authType {
        case .none: canonicalAuth = "none"
        case .bearerToken: canonicalAuth = "bearer"
        case .oauth: canonicalAuth = "oauth"
        }

        let needsSecrets = authType != .none
        var result: [String: Any] = [
            "provider_id": providerId.uuidString,
            "name": displayName,
            "url": urlString,
            "auth": canonicalAuth,
            "status": "added",
            "needs_secrets": needsSecrets,
        ]
        if needsSecrets {
            result["next_steps"] = [
                "This MCP server uses \(authType == .oauth ? "OAuth" : "a bearer token"). "
                    + "Direct the user to Settings → Tools → Remote to "
                    + (authType == .oauth ? "sign in" : "enter the token")
                    + "; never accept secrets as tool arguments.",
                "Use osaurus_list({scope: 'mcp'}) to confirm connection status.",
            ]
        } else {
            result["next_steps"] = [
                "Use osaurus_list({scope: 'mcp'}) to confirm the server connected."
            ]
        }
        return ToolEnvelope.success(tool: name, result: result)
    }

    private func handleRemove(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "MCP provider UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`id` must be a valid UUID.",
                field: "id",
                tool: name
            )
        }

        let found: Bool = await MainActor.run {
            guard MCPProviderManager.shared.configuration.provider(id: id) != nil else { return false }
            MCPProviderManager.shared.removeProvider(id: id)
            return true
        }
        guard found else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No MCP provider found with id \(idStr).",
                field: "id",
                tool: name
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["provider_id": id.uuidString, "status": "removed"]
        )
    }

    private func handleEnable(_ args: [String: Any], action: String) async -> String {
        let idReq = requireString(args, "id", expected: "MCP provider UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`id` must be a valid UUID.",
                field: "id",
                tool: name
            )
        }
        // The action carries the intent (`enable`→connect, `disable`→disconnect);
        // an explicit `enabled` boolean overrides it so a single action can still
        // flip either way. This lets a model say `action: disable` directly
        // instead of discovering the `enable` + `enabled:false` idiom.
        let enabled = coerceBool(args["enabled"]) ?? (action == "enable")

        let found: Bool = await MainActor.run {
            guard MCPProviderManager.shared.configuration.provider(id: id) != nil else { return false }
            MCPProviderManager.shared.setEnabled(enabled, for: id)
            return true
        }
        guard found else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No MCP provider found with id \(idStr).",
                field: "id",
                tool: name
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["provider_id": id.uuidString, "status": enabled ? "enabled" : "disabled"]
        )
    }
}
