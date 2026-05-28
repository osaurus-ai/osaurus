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
    private let invocationIsolation: ExternalPlugin.InvocationIsolation

    init(plugin: ExternalPlugin, spec: PluginManifest.ToolSpec) {
        self.plugin = plugin
        self.toolId = spec.id

        self.name = spec.id
        self.pluginId = plugin.id
        self.description = spec.description
        self.parameters = spec.parameters
        self.requirements = spec.requirements ?? []
        self.invocationIsolation = Self.invocationIsolation(for: self.requirements)

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
        let agentId = ChatExecutionContext.currentAgentId
        let payloadWithSecrets = injectSecrets(into: argumentsJSON, agentId: agentId)
        let payloadWithContext = injectFolderContext(into: payloadWithSecrets)
        return try await plugin.invoke(
            type: "tool",
            id: toolId,
            payload: payloadWithContext,
            agentId: agentId,
            isolation: invocationIsolation
        )
    }

    /// Native plugins that touch macOS automation APIs often hold
    /// AppKit/Accessibility objects whose lifetime is tied to the main
    /// thread. Dispatching those C ABI calls on the plugin's concurrent
    /// queue can turn a valid UI element reference into a dangling ObjC
    /// pointer during write actions such as click/type/press-key.
    private static func invocationIsolation(for requirements: [String]) -> ExternalPlugin.InvocationIsolation {
        let normalized = Set(requirements.map { $0.lowercased() })
        if normalized.contains("accessibility") || normalized.contains("automation") {
            return .mainActor
        }
        return .pluginQueue
    }

    /// Injects plugin secrets into the tool payload under the `_secrets` key
    /// - Parameter payload: Original JSON payload
    /// - Returns: Payload with secrets injected, or original payload if no secrets or parsing fails
    private func injectSecrets(into payload: String, agentId: UUID? = nil) -> String {
        // No agent context (or Default-agent context) means the tool is being
        // invoked anonymously. Return the payload unchanged rather than
        // injecting the Default agent's secrets — the previous
        // `?? Agent.defaultId` fallback leaked the built-in agent's secret
        // namespace to anonymous tool paths.
        guard let agentId = agentId, agentId != Agent.defaultId else { return payload }
        let secrets = plugin.resolvedSecrets(agentId: agentId)
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
        guard let rootPath = FolderContextService.cachedRootPath else { return payload }

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
