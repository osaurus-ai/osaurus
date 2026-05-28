//
//  PluginConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tools for Osaurus plugins (central registry):
//   - osaurus_plugin_install
//   - osaurus_plugin_uninstall
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
            OsaurusPluginInstallTool(),
            OsaurusPluginUninstallTool(),
        ],
        writeToolNames: [
            "osaurus_plugin_install",
            "osaurus_plugin_uninstall",
        ]
    )
}

// MARK: - osaurus_plugin_install

public final class OsaurusPluginInstallTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_plugin_install"
    public let description =
        "Install a plugin from the central registry by `plugin_id` (e.g. `osaurus.weather`). "
        + "If the plugin needs secrets, the response carries `needs_secrets: true` — direct the user "
        + "to the Plugin Secrets sheet; never accept secrets as tool arguments."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "plugin_id": .object([
                "type": .string("string"),
                "description": .string("Registry plugin id, e.g. `osaurus.weather`."),
            ])
        ]),
        "required": .array([.string("plugin_id")]),
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

        return ToolEnvelope.success(
            tool: name,
            result: [
                "plugin_id": pluginId,
                "status": "installed",
                "next_steps": [
                    "If the plugin requires API keys or webhooks, direct the user to Settings → Plugins → Secrets.",
                    "Use osaurus_describe({scope: 'plugins', id: '\(pluginId)'}) to inspect its tools.",
                ],
            ]
        )
    }
}

// MARK: - osaurus_plugin_uninstall

public final class OsaurusPluginUninstallTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_plugin_uninstall"
    public let description = "Uninstall a plugin by `plugin_id` and clean up its keychain secrets."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object(["plugin_id": .object(["type": .string("string")])]),
        "required": .array([.string("plugin_id")]),
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
