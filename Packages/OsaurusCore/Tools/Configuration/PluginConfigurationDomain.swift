//
//  PluginConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tool for Osaurus plugins (central registry).
//  One tool, `osaurus_plugin`, fans out across two actions:
//   - install
//   - uninstall
//
//  Secrets are intentionally NOT entered through the chat. If an
//  install reports `needs_secrets`, the tool surfaces that signal to
//  the model so it can direct the user to the Plugin Secrets sheet.
//

import Foundation

enum PluginConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "plugins",
        displayName: "Plugins",
        summary: "Osaurus plugins from the central registry. Install and uninstall by `plugin_id`.",
        menuHint: "install / uninstall plugins (e.g. weather, search, calendar)",
        searchKeywords: [
            "plugin", "plugins",
            "install plugin", "add plugin", "enable plugin",
            "uninstall plugin", "remove plugin", "disable plugin",
        ],
        exampleQueries: [
            "install the weather plugin",
            "add a calendar plugin",
            "uninstall the search plugin",
        ],
        tools: [
            OsaurusPluginTool()
        ],
        writeToolNames: [
            "osaurus_plugin"
        ]
    )
}

// MARK: - osaurus_plugin

public final class OsaurusPluginTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_plugin"
    public let description =
        "Manage plugins from the central registry. `action`: install (needs `plugin_id`, e.g. "
        + "`osaurus.weather`; if it needs secrets the response carries `needs_secrets: true` — send the user "
        + "to the Plugin Secrets sheet, never accept secrets as arguments), uninstall (needs `plugin_id`)."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("install"), .string("uninstall")]),
                "description": .string("Operation to perform."),
            ]),
            "plugin_id": .object([
                "type": .string("string"),
                "description": .string("Registry plugin id, e.g. `osaurus.weather`."),
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
        let actionReq = requireAction(args, allowed: ["install", "uninstall"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "install": return await handleInstall(args)
        case "uninstall": return await handleUninstall(args)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    private func handleInstall(_ args: [String: Any]) async -> String {
        let req = requireString(args, "plugin_id", expected: "registry plugin id", tool: name)
        guard case .value(let pluginId) = req else { return req.failureEnvelope ?? "" }

        do {
            try await PluginRepositoryService.shared.install(pluginId: pluginId)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to install `\(pluginId)`: \(error.localizedDescription)",
                tool: name,
                retryable: false
            )
        }

        // Inspect the freshly loaded manifest for required secrets the user
        // hasn't supplied yet. Secrets never travel through chat.
        let missingSecretLabels: [String] = await MainActor.run {
            guard
                let loaded = PluginManager.shared.plugins
                    .first(where: { $0.plugin.id == pluginId }),
                let secrets = loaded.plugin.manifest.secrets
            else {
                return []
            }
            return
                secrets
                .filter { spec in
                    spec.required
                        && !ToolSecretsKeychain.hasSecret(
                            id: spec.id,
                            for: pluginId,
                            agentId: Agent.defaultId
                        )
                }
                .map { $0.label }
        }

        let needsSecrets = !missingSecretLabels.isEmpty
        var result: [String: Any] = [
            "plugin_id": pluginId,
            "status": "installed",
            "needs_secrets": needsSecrets,
        ]
        if needsSecrets {
            result["missing_secrets"] = missingSecretLabels
            result["next_steps"] = [
                "This plugin needs secrets (\(missingSecretLabels.joined(separator: ", "))). "
                    + "Direct the user to Settings → Plugins → Secrets; never accept secrets as tool arguments.",
                "Use osaurus_describe({scope: 'plugins', id: '\(pluginId)'}) to inspect its tools.",
            ]
        } else {
            result["next_steps"] = [
                "Use osaurus_describe({scope: 'plugins', id: '\(pluginId)'}) to inspect its tools."
            ]
        }
        return ToolEnvelope.success(tool: name, result: result)
    }

    private func handleUninstall(_ args: [String: Any]) async -> String {
        let req = requireString(args, "plugin_id", expected: "installed plugin id", tool: name)
        guard case .value(let pluginId) = req else { return req.failureEnvelope ?? "" }

        do {
            try await PluginRepositoryService.shared.uninstall(pluginId: pluginId)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to uninstall `\(pluginId)`: \(error.localizedDescription)",
                tool: name,
                retryable: false
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["plugin_id": pluginId, "status": "uninstalled"]
        )
    }
}
