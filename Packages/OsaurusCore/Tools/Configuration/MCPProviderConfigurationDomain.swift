//
//  MCPProviderConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tools for remote MCP (Model Context Protocol)
//  tool providers:
//   - osaurus_mcp_add     — register an HTTP MCP server
//   - osaurus_mcp_remove  — delete a registered MCP server
//   - osaurus_mcp_enable  — enable / disable a registered MCP server
//
//  Scope is intentionally narrow and HTTP-only. stdio MCP servers launch
//  local subprocesses (`npx`, `uvx`, …) and carry real trust weight, so
//  they stay in Settings → Tools → Remote rather than chat. Secrets
//  (bearer tokens, OAuth) NEVER travel through chat: when a server needs
//  auth the tool registers it and returns `needs_secrets: true`, directing
//  the user to finish in Settings → Tools → Remote (same pattern as the
//  plugin domain's `needs_secrets`).
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
            OsaurusMCPAddTool(),
            OsaurusMCPRemoveTool(),
            OsaurusMCPEnableTool(),
        ],
        writeToolNames: [
            "osaurus_mcp_add",
            "osaurus_mcp_remove",
            "osaurus_mcp_enable",
        ]
    )
}

// MARK: - osaurus_mcp_add

public final class OsaurusMCPAddTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_mcp_add"
    public let description =
        "Register a remote HTTP MCP (Model Context Protocol) tool server. Requires `name` and `url` "
        + "(an https endpoint). Optional `auth` ∈ {none, bearer, oauth}; defaults to `none`. When the "
        + "server needs a bearer token or OAuth, the response carries `needs_secrets: true` — direct the "
        + "user to Settings → Tools → Remote to enter the secret. Never accept secrets as tool arguments. "
        + "stdio (local subprocess) servers are not supported here — use Settings → Tools → Remote."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Display name for the MCP server."),
            ]),
            "url": .object([
                "type": .string("string"),
                "description": .string("HTTP(S) endpoint URL of the MCP server."),
            ]),
            "auth": .object([
                "type": .string("string"),
                "description": .string("Auth strategy: none (default), bearer, or oauth."),
            ]),
        ]),
        "required": .array([.string("name"), .string("url")]),
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
            // Secrets are never accepted via chat — `token: nil`. For
            // bearer/oauth the user finishes in Settings → Tools → Remote.
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
}

// MARK: - osaurus_mcp_remove

public final class OsaurusMCPRemoveTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_mcp_remove"
    public let description =
        "Remove a registered MCP server by `id` (its UUID). Disconnects it and clears its keychain secrets."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object(["id": .object(["type": .string("string")])]),
        "required": .array([.string("id")]),
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
}

// MARK: - osaurus_mcp_enable

public final class OsaurusMCPEnableTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_mcp_enable"
    public let description =
        "Enable or disable a registered MCP server by `id`. Pass `enabled: true` to connect, "
        + "`enabled: false` to disconnect."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "id": .object(["type": .string("string")]),
            "enabled": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("id"), .string("enabled")]),
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
        guard let enabled = args["enabled"] as? Bool else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`enabled` (boolean) is required.",
                field: "enabled",
                tool: name
            )
        }

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
            result: [
                "provider_id": id.uuidString,
                "status": enabled ? "enabled" : "disabled",
            ]
        )
    }
}
