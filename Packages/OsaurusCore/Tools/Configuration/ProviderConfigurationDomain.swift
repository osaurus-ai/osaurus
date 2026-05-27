//
//  ProviderConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tools for cloud LLM providers:
//   - osaurus_provider_add            (opens credential sheet)
//   - osaurus_provider_update         (non-secret fields only)
//   - osaurus_provider_remove
//   - osaurus_provider_set_credentials (key rotation)
//
//  Security principle: no secret ever appears in tool arguments or
//  tool results. The model sends only `name` + `provider_type`; the
//  user pastes / signs in via `ProviderCredentialPromptService`, and
//  the manager writes directly to Keychain. The success envelope
//  carries only `provider_id` + status — never the secret.
//
//  Add and set_credentials set `bypassRegistryTimeout = true` so the
//  user has uncapped time to interact with the sheet. The 120-second
//  registry timeout would otherwise abort the call before the user
//  finishes typing.
//

import Foundation

enum ProviderConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "providers",
        displayName: "Providers",
        summary: "Cloud LLM providers (Anthropic, OpenAI, Gemini, Codex OAuth, Azure, custom).",
        menuHint:
            "add / update / remove cloud providers — Anthropic, OpenAI, Codex OAuth, Gemini, Azure, custom",
        searchKeywords: [
            "provider", "providers", "cloud", "api key", "key", "credentials",
            "anthropic", "claude", "openai", "gpt", "chatgpt", "codex",
            "gemini", "google", "openrouter", "azure",
            "add provider", "connect provider", "sign in",
            "update provider", "edit provider",
            "remove provider", "delete provider", "disconnect",
            "rotate key", "replace key", "fix key",
        ],
        exampleQueries: [
            "add my Anthropic key",
            "connect anthropic",
            "sign in to Codex",
            "add OpenAI",
            "my Anthropic key stopped working",
            "remove the OpenAI provider",
            "update the host for my custom provider",
        ],
        tools: [
            OsaurusProviderAddTool(),
            OsaurusProviderUpdateTool(),
            OsaurusProviderRemoveTool(),
            OsaurusProviderSetCredentialsTool(),
        ],
        writeToolNames: [
            "osaurus_provider_add",
            "osaurus_provider_update",
            "osaurus_provider_remove",
            "osaurus_provider_set_credentials",
        ]
    )
}

// MARK: - Shared helpers

private enum ProviderToolShared {
    /// The eight provider types the model can pass via `provider_type`,
    /// keyed by the chat-friendly name (`"openai"` not
    /// `"openResponses"`). Maps to `RemoteProviderType.rawValue`s
    /// when those exist; the rest are aliases the model expects.
    static let providerTypeAliases: [String: RemoteProviderType] = [
        "anthropic": .anthropic,
        "openai": .openResponses,
        "openai_compatible": .openaiLegacy,
        "gemini": .gemini,
        "codex_oauth": .openAICodex,
        "openrouter": .openaiLegacy,
        "azure_openai": .azureOpenAI,
        "osaurus_agent": .osaurus,
    ]

    static func resolveProviderType(_ value: String?) -> RemoteProviderType? {
        guard let value else { return nil }
        if let mapped = providerTypeAliases[value.lowercased()] { return mapped }
        return RemoteProviderType(rawValue: value)
    }

    /// Default host/protocol/basePath for a given type. Used when the
    /// model doesn't pass an explicit host (the common case for
    /// vendor-managed APIs like Anthropic / OpenAI / Gemini).
    static func defaults(for type: RemoteProviderType) -> (
        host: String,
        providerProtocol: RemoteProviderProtocol,
        port: Int?,
        basePath: String
    ) {
        switch type {
        case .anthropic: return ("api.anthropic.com", .https, nil, "/v1")
        case .openResponses: return ("api.openai.com", .https, nil, "/v1")
        case .openaiLegacy: return ("api.openai.com", .https, nil, "/v1")
        case .azureOpenAI: return ("example.openai.azure.com", .https, nil, "/openai/v1")
        case .gemini: return ("generativelanguage.googleapis.com", .https, nil, "/v1beta")
        case .openAICodex: return ("chatgpt.com", .https, nil, "/backend-api")
        case .osaurus: return ("localhost", .http, 8080, "/v1")
        }
    }
}

// MARK: - osaurus_provider_add

public final class OsaurusProviderAddTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_provider_add"
    public let description =
        "Add a cloud LLM provider. Pass `name` and `provider_type` "
        + "(anthropic, openai, openai_compatible, gemini, codex_oauth, azure_openai, osaurus_agent). "
        + "DO NOT pass API keys here — a secure sheet opens so the user can paste / sign in. "
        + "The tool waits for the user (the sheet can take several minutes)."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object(["type": .string("string")]),
            "provider_type": .object([
                "type": .string("string"),
                "description": .string(
                    "One of: anthropic, openai, openai_compatible, gemini, codex_oauth, azure_openai, osaurus_agent."
                ),
            ]),
            "host": .object([
                "type": .string("string"),
                "description": .string("Override host. Optional for managed vendors."),
            ]),
        ]),
        "required": .array([.string("name"), .string("provider_type")]),
    ])

    /// The credential sheet is user-paced — letting the registry's
    /// 120s wall-clock budget time us out would break the flow. The
    /// tool still checks `Task.isCancelled` so a cancelled chat turn
    /// dismisses the sheet via `ProviderCredentialPromptService.cancel()`.
    public var bypassRegistryTimeout: Bool { true }

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
        let typeReq = requireString(args, "provider_type", expected: "provider type id", tool: name)
        guard case .value(let typeRaw) = typeReq else { return typeReq.failureEnvelope ?? "" }
        guard let providerType = ProviderToolShared.resolveProviderType(typeRaw) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`provider_type` must be one of: anthropic, openai, openai_compatible, "
                    + "gemini, codex_oauth, azure_openai, osaurus_agent.",
                field: "provider_type",
                tool: name
            )
        }

        let hostOverride = args["host"] as? String
        let instructions = ProviderCredentialInstructionsCatalog.entry(for: providerType)

        let request = ProviderCredentialRequest(
            providerType: providerType,
            providerName: displayName,
            mode: .addNew
        )
        let outcome = await ProviderCredentialPromptService.requestCredentials(request)

        if Task.isCancelled {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Provider add cancelled before completion.",
                tool: name,
                retryable: false
            )
        }

        switch outcome {
        case .cancelled:
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "User cancelled credential entry.",
                tool: name,
                retryable: false
            )
        case .apiKey(let key, let headers):
            let providerId = await MainActor.run {
                buildAndAdd(
                    displayName: displayName,
                    providerType: providerType,
                    storageAuthType: instructions.storageAuthType,
                    hostOverride: hostOverride,
                    extraHeaders: headers,
                    apiKey: key,
                    oauthTokens: nil
                )
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "provider_id": providerId.uuidString,
                    "status": "added",
                    "connecting": true,
                    "next_steps": [
                        "Use osaurus_describe({scope: 'provider', id: '\(providerId.uuidString)'}) "
                            + "to see connection status and discovered models."
                    ],
                ]
            )
        case .oauthTokens(let tokens):
            let providerId = await MainActor.run {
                buildAndAdd(
                    displayName: displayName,
                    providerType: providerType,
                    storageAuthType: .openAICodexOAuth,
                    hostOverride: hostOverride,
                    extraHeaders: nil,
                    apiKey: nil,
                    oauthTokens: tokens
                )
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "provider_id": providerId.uuidString,
                    "status": "added",
                    "connecting": true,
                    "auth_mode": "oauth",
                ]
            )
        }
    }

    @MainActor
    private func buildAndAdd(
        displayName: String,
        providerType: RemoteProviderType,
        storageAuthType: RemoteProviderAuthType,
        hostOverride: String?,
        extraHeaders: [String: String]?,
        apiKey: String?,
        oauthTokens: RemoteProviderOAuthTokens?
    ) -> UUID {
        if providerType == .openAICodex {
            let provider = OpenAICodexOAuthService.makeProvider()
            RemoteProviderManager.shared.addProvider(
                provider,
                apiKey: apiKey,
                oauthTokens: oauthTokens
            )
            // Rename to user-friendly label
            if provider.name != displayName {
                var renamed = provider
                renamed.name = displayName
                RemoteProviderManager.shared.updateProvider(renamed, apiKey: nil, oauthTokens: nil)
            }
            return provider.id
        }

        let defaults = ProviderToolShared.defaults(for: providerType)
        let host = (hostOverride?.isEmpty == false) ? hostOverride! : defaults.host
        var headers: [String: String] = [:]
        if let extra = extraHeaders, providerType == .openaiLegacy {
            for (k, v) in extra where k != "host" && k != "deployment" {
                headers[k] = v
            }
        }
        let provider = RemoteProvider(
            name: displayName,
            host: host,
            providerProtocol: defaults.providerProtocol,
            port: defaults.port,
            basePath: defaults.basePath,
            customHeaders: headers,
            authType: storageAuthType,
            providerType: providerType,
            enabled: true,
            autoConnect: true,
            timeout: 60
        )
        RemoteProviderManager.shared.addProvider(
            provider,
            apiKey: apiKey,
            oauthTokens: oauthTokens
        )
        return provider.id
    }
}

// MARK: - osaurus_provider_update

public final class OsaurusProviderUpdateTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_provider_update"
    public let description =
        "Update non-secret fields of an existing provider. Requires `id`. To rotate the API key "
        + "or OAuth tokens, call osaurus_provider_set_credentials instead."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "id": .object(["type": .string("string")]),
            "name": .object(["type": .string("string")]),
            "host": .object(["type": .string("string")]),
            "enabled": .object(["type": .string("boolean")]),
            "auto_connect": .object(["type": .string("boolean")]),
        ]),
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
        let idReq = requireString(args, "id", expected: "provider UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`id` must be a valid UUID.",
                tool: name
            )
        }

        let outcome: String = await MainActor.run {
            let mgr = RemoteProviderManager.shared
            guard var provider = mgr.configuration.providers.first(where: { $0.id == id }) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No provider found with id \(idStr).",
                    field: "id",
                    tool: name
                )
            }
            if let v = args["name"] as? String { provider.name = v }
            if let v = args["host"] as? String { provider.host = v }
            if let b = self.coerceBool(args["enabled"]) { provider.enabled = b }
            if let b = self.coerceBool(args["auto_connect"]) { provider.autoConnect = b }
            mgr.updateProvider(provider, apiKey: nil, oauthTokens: nil)
            return ToolEnvelope.success(
                tool: name,
                result: ["provider_id": id.uuidString, "status": "updated"]
            )
        }
        return outcome
    }
}

// MARK: - osaurus_provider_remove

public final class OsaurusProviderRemoveTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_provider_remove"
    public let description =
        "Remove a provider by `id`. Its Keychain entries (API key + OAuth tokens) are cleaned up automatically."
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
        let idReq = requireString(args, "id", expected: "provider UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`id` must be a valid UUID.",
                tool: name
            )
        }

        let removed: Bool = await MainActor.run {
            let mgr = RemoteProviderManager.shared
            guard mgr.configuration.providers.contains(where: { $0.id == id }) else {
                return false
            }
            mgr.removeProvider(id: id)
            return true
        }
        if !removed {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No provider found with id \(idStr).",
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

// MARK: - osaurus_provider_set_credentials

public final class OsaurusProviderSetCredentialsTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_provider_set_credentials"
    public let description =
        "Re-enter credentials for an existing provider (key rotation / fix wrong key). "
        + "Opens the same secure sheet as osaurus_provider_add."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object(["id": .object(["type": .string("string")])]),
        "required": .array([.string("id")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let idReq = requireString(args, "id", expected: "provider UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`id` must be a valid UUID.",
                tool: name
            )
        }

        let lookup: (provider: RemoteProvider, displayName: String)? = await MainActor.run {
            guard let p = RemoteProviderManager.shared.configuration.providers.first(where: { $0.id == id })
            else { return nil }
            return (p, p.name)
        }
        guard let (provider, displayName) = lookup else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No provider found with id \(idStr).",
                field: "id",
                tool: name
            )
        }

        let request = ProviderCredentialRequest(
            providerType: provider.providerType,
            providerName: displayName,
            mode: .rotate(existingId: id)
        )
        let outcome = await ProviderCredentialPromptService.requestCredentials(request)

        switch outcome {
        case .cancelled:
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "User cancelled credential rotation.",
                tool: name,
                retryable: false
            )
        case .apiKey(let key, _):
            await MainActor.run {
                RemoteProviderManager.shared.updateProvider(provider, apiKey: key, oauthTokens: nil)
            }
            return ToolEnvelope.success(
                tool: name,
                result: ["provider_id": id.uuidString, "status": "credentials_updated"]
            )
        case .oauthTokens(let tokens):
            await MainActor.run {
                RemoteProviderManager.shared.updateProvider(provider, apiKey: nil, oauthTokens: tokens)
            }
            return ToolEnvelope.success(
                tool: name,
                result: ["provider_id": id.uuidString, "status": "credentials_updated", "auth_mode": "oauth"]
            )
        }
    }
}
