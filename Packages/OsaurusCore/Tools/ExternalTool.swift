//
//  ExternalTool.swift
//  osaurus
//
//  Wrapper around a specific tool capability from an ExternalPlugin.
//

import Foundation
import OsaurusRepository

final class ExternalTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?
    let requirements: [String]
    let defaultPermissionPolicy: ToolPermissionPolicy
    /// The plugin this tool belongs to (matches `PluginManifest.plugin_id`)
    let pluginId: String

    private let plugin: ExternalPlugin
    private let toolId: String

    init(plugin: ExternalPlugin, spec: PluginManifest.ToolSpec) {
        self.plugin = plugin
        self.toolId = spec.id

        self.name = spec.id
        self.pluginId = plugin.id
        self.description = spec.description
        self.parameters = spec.parameters
        self.requirements = spec.requirements ?? []

        if let polStr = spec.permission_policy?.lowercased() {
            switch polStr {
            case "auto": self.defaultPermissionPolicy = .auto
            case "deny": self.defaultPermissionPolicy = .deny
            default: self.defaultPermissionPolicy = .ask
            }
        } else {
            self.defaultPermissionPolicy = .ask
        }
    }

    func execute(argumentsJSON: String) async throws -> String {
        // Inject secrets into the payload if the plugin has secrets configured
        let payloadWithSecrets = injectSecrets(into: argumentsJSON)
        // Inject folder context so plugins can resolve relative paths
        let payloadWithContext = injectFolderContext(into: payloadWithSecrets)
        return try await plugin.invoke(type: "tool", id: toolId, payload: payloadWithContext)
    }

    /// Injects plugin secrets into the tool payload under the `_secrets` key
    /// - Parameter payload: Original JSON payload
    /// - Returns: Payload with secrets injected, or original payload if no secrets or parsing fails
    private func injectSecrets(into payload: String) -> String {
        let secrets = plugin.resolvedSecrets()
        guard !secrets.isEmpty else { return payload }

        // Parse the original payload
        guard let payloadData = payload.data(using: .utf8),
            var payloadDict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            // If payload isn't a valid JSON object, return as-is
            return payload
        }

        // Add secrets under the `_secrets` key
        payloadDict["_secrets"] = secrets

        // Re-serialize to JSON
        guard let modifiedData = try? JSONSerialization.data(withJSONObject: payloadDict),
            let modifiedPayload = String(data: modifiedData, encoding: .utf8)
        else {
            return payload
        }

        return modifiedPayload
    }

    /// Injects folder context into the tool payload under the `_context` key
    /// - Parameter payload: Original JSON payload
    /// - Returns: Payload with folder context injected, or original payload if no folder context active
    private func injectFolderContext(into payload: String) -> String {
        // Read from the thread-safe cache to avoid hopping to MainActor,
        // which can deadlock when the main thread is busy with SwiftUI layout.
        guard let rootPath = AgentFolderContextService.cachedRootPath else { return payload }

        // Parse the original payload
        guard let payloadData = payload.data(using: .utf8),
            var payloadDict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            // If payload isn't a valid JSON object, return as-is
            return payload
        }

        // Add context under the `_context` key
        payloadDict["_context"] = [
            "working_directory": rootPath.path
        ]

        // Re-serialize to JSON
        guard let modifiedData = try? JSONSerialization.data(withJSONObject: payloadDict),
            let modifiedPayload = String(data: modifiedData, encoding: .utf8)
        else {
            return payload
        }

        return modifiedPayload
    }
}
