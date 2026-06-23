//
//  ProviderConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tool for cloud LLM providers. One tool,
//  `osaurus_provider`, fans out across four actions:
//   - add             (opens a credential sheet)
//   - update          (non-secret fields only)
//   - remove
//   - set_credentials (key rotation)
//
//  Security principle: no secret ever appears in tool arguments or
//  tool results. The model sends only `name` + `provider` (the preset
//  id — `openrouter`, `deepseek`, `openai`, …). The user pastes /
//  signs in via `ProviderCredentialPromptService`, and the manager
//  writes directly to Keychain. The success envelope carries only
//  `provider_id` + status — never the secret.
//
//  `add` and `set_credentials` rely on `bypassRegistryTimeout = true`
//  so the user has uncapped time to interact with the sheet; the
//  120-second registry timeout would otherwise abort the call before
//  the user finishes typing. The tool still checks `Task.isCancelled`
//  so a cancelled chat turn dismisses the sheet.
//

import Foundation

enum ProviderConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "providers",
        displayName: "Providers",
        summary:
            "Cloud LLM providers (Anthropic, OpenAI, Gemini, Codex OAuth, Azure, "
            + "OpenRouter, DeepSeek, xAI, Venice, Ollama, custom).",
        menuHint:
            "add / update / remove / rotate-key cloud providers — Anthropic, OpenAI, Codex OAuth, "
            + "Gemini, Azure, OpenRouter (OAuth), DeepSeek, xAI, Venice, Ollama, custom",
        searchKeywords: [
            "provider", "providers", "cloud", "api key", "key", "credentials",
            "anthropic", "claude", "openai", "gpt", "chatgpt", "codex",
            "gemini", "google", "openrouter", "azure", "deepseek", "xai", "grok",
            "venice", "ollama",
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
            "sign in to OpenRouter",
            "connect DeepSeek",
            "set up Ollama",
            "my Anthropic key stopped working",
            "remove the OpenAI provider",
            "update the host for my custom provider",
        ],
        tools: [
            OsaurusProviderTool()
        ],
        writeToolNames: [
            "osaurus_provider"
        ]
    )
}

// MARK: - Shared helpers

/// Resolution outcome for the `provider` argument. `.preset` is the
/// canonical chat-tool path; the other two cases carry the special storage
/// paths that have no `ProviderPreset` case (`.codexOAuth` uses the OpenAI
/// brand but a distinct OAuth flow, and `.osaurusAgent` is a peer agent
/// rather than a third-party vendor).
internal enum ProviderToolResolution {
    case preset(ProviderPreset)
    case codexOAuth
    case osaurusAgent

    /// `RemoteProviderType` the manager should persist with.
    var providerType: RemoteProviderType {
        switch self {
        case .preset(let preset): return preset.configuration.providerType
        case .codexOAuth: return .openAICodex
        case .osaurusAgent: return .osaurus
        }
    }
}

internal enum ProviderToolShared {
    /// Chat-friendly provider ids the model can pass via the `provider`
    /// argument. New ids should be added here first.
    static let providerAliases: [String: ProviderToolResolution] = [
        "anthropic": .preset(.anthropic),
        "openai": .preset(.openai),
        "azure_openai": .preset(.azureOpenAI),
        "google": .preset(.google),
        "gemini": .preset(.google),
        "xai": .preset(.xai),
        "deepseek": .preset(.deepseek),
        "venice": .preset(.venice),
        "openrouter": .preset(.openrouter),
        "ollama": .preset(.ollama),
        "custom": .preset(.custom),
        "openai_compatible": .preset(.custom),
        "codex_oauth": .codexOAuth,
        "osaurus_agent": .osaurusAgent,
    ]

    /// Canonical list of chat-friendly ids surfaced in the tool schema
    /// `enum`, description, and error messages. Kept in display order
    /// rather than alphabetical so the most common vendors appear first.
    static let canonicalIds: [String] = [
        "anthropic", "openai", "codex_oauth", "azure_openai", "google",
        "xai", "deepseek", "venice", "openrouter", "ollama",
        "custom", "osaurus_agent",
    ]

    static func resolve(_ value: String?) -> ProviderToolResolution? {
        guard let value else { return nil }
        return providerAliases[value.lowercased()]
    }

    /// Human-readable enumeration of `canonicalIds` for error messages.
    static var canonicalIdsList: String {
        canonicalIds.joined(separator: ", ")
    }
}

// MARK: - osaurus_provider

public final class OsaurusProviderTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_provider"
    public let description =
        "Manage cloud LLM providers. `action`: add (opens a secure sheet so the user pastes / signs in — "
        + "never pass API keys), update (non-secret fields), remove, set_credentials (rotate the key via the "
        + "same sheet). `add` needs `name` + `provider`; the rest need `id`."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("add"), .string("update"), .string("remove"), .string("set_credentials"),
                ]),
                "description": .string("Operation to perform."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string("Provider UUID. Required for update / remove / set_credentials."),
            ]),
            "name": .object([
                "type": .string("string"),
                "description": .string("Display name. Required for add."),
            ]),
            "provider": .object([
                "type": .string("string"),
                "enum": .array(ProviderToolShared.canonicalIds.map { .string($0) }),
                "description": .string(
                    "Provider preset. Required for add. `openrouter` opens a browser OAuth flow."
                ),
            ]),
            "host": .object([
                "type": .string("string"),
                "description": .string("Override host. Optional."),
            ]),
            "enabled": .object(["type": .string("boolean")]),
            "auto_connect": .object(["type": .string("boolean")]),
            "port": .object(["type": .string("integer")]),
            "base_path": .object([
                "type": .string("string"),
                "description": .string("API base path (e.g. /v1)."),
            ]),
            "timeout": .object([
                "type": .string("integer"),
                "description": .string("Request timeout in seconds."),
            ]),
            "manual_model_ids": .object([
                "type": .string("string"),
                "description": .string(
                    "Comma/newline-separated model ids (Azure: deployment names). Replaces the existing list."
                ),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    /// `add` / `set_credentials` open a user-paced credential sheet, so the
    /// whole tool opts out of the registry's 120s wall-clock budget. The
    /// fast actions (`update` / `remove`) complete well within it anyway.
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
        let actionReq = requireAction(args, allowed: ["add", "update", "remove", "set_credentials"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "add": return await handleAdd(args)
        case "update": return await handleUpdate(args)
        case "remove": return await handleRemove(args)
        case "set_credentials": return await handleSetCredentials(args)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    // MARK: add

    private func handleAdd(_ args: [String: Any]) async -> String {
        let nameReq = requireString(args, "name", expected: "display name", tool: name)
        guard case .value(let displayName) = nameReq else { return nameReq.failureEnvelope ?? "" }

        guard let raw = args["provider"] as? String, !raw.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`provider` is required for action `add`. One of: "
                    + ProviderToolShared.canonicalIdsList + ".",
                field: "provider",
                tool: name
            )
        }
        guard let resolution = ProviderToolShared.resolve(raw) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`provider` must be one of: " + ProviderToolShared.canonicalIdsList + ".",
                field: "provider",
                tool: name
            )
        }

        let hostOverride = args["host"] as? String
        let request = makeRequest(resolution: resolution, displayName: displayName)
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
            // `.none`-auth providers (e.g. Ollama) flow through the same
            // `.apiKey` outcome with an empty string when the user skips
            // the optional key field. Pass nil to the manager so we don't
            // write an empty record to Keychain.
            let storageAuthType = request.instructions.storageAuthType
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedKey: String? =
                (storageAuthType == .none || trimmedKey.isEmpty) ? nil : trimmedKey
            let providerId = await MainActor.run {
                buildAndAdd(
                    displayName: displayName,
                    resolution: resolution,
                    storageAuthType: storageAuthType,
                    hostOverride: hostOverride,
                    extraHeaders: headers,
                    apiKey: resolvedKey,
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
                        "Use osaurus_describe({scope: 'providers', id: '\(providerId.uuidString)'}) "
                            + "to see connection status and discovered models."
                    ],
                ]
            )
        case .oauthTokens(let tokens):
            let providerId = await MainActor.run {
                buildAndAdd(
                    displayName: displayName,
                    resolution: resolution,
                    storageAuthType: request.instructions.storageAuthType,
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

    // MARK: update

    private func handleUpdate(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "provider UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
        }

        // Pull every patch value into Sendable locals before crossing onto the
        // main actor — capturing the `[String: Any]` directly trips the
        // concurrency checker (task-isolated dictionary in a @MainActor closure).
        let newName = args["name"] as? String
        let newHost = args["host"] as? String
        let newEnabled = coerceBool(args["enabled"])
        let newAutoConnect = coerceBool(args["auto_connect"])
        let newPort = coerceInt(args["port"])
        let newBasePath = args["base_path"] as? String
        let newTimeout = coerceInt(args["timeout"])
        let newManualModelIds = (args["manual_model_ids"] as? String)
            .map(OsaurusProviderTool.parseManualModelIds)

        return await MainActor.run {
            let mgr = RemoteProviderManager.shared
            guard var provider = mgr.configuration.providers.first(where: { $0.id == id }) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No provider found with id \(idStr).",
                    field: "id",
                    tool: name
                )
            }
            if let v = newName { provider.name = v }
            if let v = newHost { provider.host = v }
            if let b = newEnabled { provider.enabled = b }
            if let b = newAutoConnect { provider.autoConnect = b }
            if let p = newPort { provider.port = p }
            if let v = newBasePath { provider.basePath = v }
            if let t = newTimeout { provider.timeout = TimeInterval(t) }
            if let ids = newManualModelIds { provider.manualModelIds = ids }
            mgr.updateProvider(provider, apiKey: nil, oauthTokens: nil)
            return ToolEnvelope.success(
                tool: name,
                result: ["provider_id": id.uuidString, "status": "updated"]
            )
        }
    }

    // MARK: remove

    private func handleRemove(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "provider UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
        }

        let removed: Bool = await MainActor.run {
            let mgr = RemoteProviderManager.shared
            guard mgr.configuration.providers.contains(where: { $0.id == id }) else { return false }
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

    // MARK: set_credentials

    private func handleSetCredentials(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "provider UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
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
            provider: provider,
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

    // MARK: - add helpers

    private func makeRequest(
        resolution: ProviderToolResolution,
        displayName: String
    ) -> ProviderCredentialRequest {
        switch resolution {
        case .preset(let preset):
            return ProviderCredentialRequest(preset: preset, providerName: displayName, mode: .addNew)
        case .codexOAuth:
            return ProviderCredentialRequest(providerType: .openAICodex, providerName: displayName, mode: .addNew)
        case .osaurusAgent:
            return ProviderCredentialRequest(providerType: .osaurus, providerName: displayName, mode: .addNew)
        }
    }

    @MainActor
    private func buildAndAdd(
        displayName: String,
        resolution: ProviderToolResolution,
        storageAuthType: RemoteProviderAuthType,
        hostOverride: String?,
        extraHeaders: [String: String]?,
        apiKey: String?,
        oauthTokens: RemoteProviderOAuthTokens?
    ) -> UUID {
        if case .codexOAuth = resolution {
            let provider = OpenAICodexOAuthService.makeProvider()
            RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey, oauthTokens: oauthTokens)
            if provider.name != displayName {
                var renamed = provider
                renamed.name = displayName
                RemoteProviderManager.shared.updateProvider(renamed, apiKey: nil, oauthTokens: nil)
            }
            return provider.id
        }

        let defaults = endpointDefaults(for: resolution)
        let providerType = resolution.providerType
        let extras = extraHeaders ?? [:]

        // The credential sheet collects non-secret extras (host, deployment,
        // …) keyed by the catalog field id. Reserved keys map onto explicit
        // `RemoteProvider` fields below — anything else passes through as a
        // custom header for `.openaiLegacy` providers.
        let sheetHost = extras["host"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host: String
        if let override = hostOverride, !override.isEmpty {
            host = override
        } else if !sheetHost.isEmpty {
            host = sheetHost
        } else {
            host = defaults.host
        }

        var headers: [String: String] = [:]
        if providerType == .openaiLegacy {
            for (k, v) in extras where !Self.reservedExtraKeys.contains(k) {
                headers[k] = v
            }
        }

        // Azure routes requests through deployment names rather than model
        // names, so the Settings UI persists the deployment list in
        // `manualModelIds`. Mirror that here.
        var manualModelIds: [String] = []
        if providerType == .azureOpenAI {
            let raw = extras["deployment"] ?? ""
            manualModelIds = Self.parseManualModelIds(raw)
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
            timeout: 60,
            manualModelIds: manualModelIds
        )
        RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey, oauthTokens: oauthTokens)
        return provider.id
    }

    /// Extra-field keys that map to explicit `RemoteProvider` columns rather
    /// than free-form `customHeaders`. Exposed `internal` so tests can assert
    /// the contract without copy-pasting it.
    static let reservedExtraKeys: Set<String> = ["host", "deployment"]

    /// Split a comma/newline-separated list of deployment names into a
    /// deduped, trimmed, order-preserving array. Mirrors the parser in
    /// `RemoteProviderEditSheet`.
    static func parseManualModelIds(_ text: String) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for part in text.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let value = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            values.append(value)
        }
        return values
    }

    private func endpointDefaults(
        for resolution: ProviderToolResolution
    ) -> (host: String, providerProtocol: RemoteProviderProtocol, port: Int?, basePath: String) {
        switch resolution {
        case .preset(let preset):
            let cfg = preset.configuration
            return (cfg.host, cfg.providerProtocol, cfg.port, cfg.basePath)
        case .codexOAuth:
            return ("chatgpt.com", .https, nil, "/backend-api")
        case .osaurusAgent:
            return ("localhost", .http, 8080, "/v1")
        }
    }
}
