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

    private let plugin: ExternalPlugin
    private let toolId: String

    init(plugin: ExternalPlugin, spec: PluginManifest.ToolSpec) {
        self.plugin = plugin
        self.toolId = spec.id

        self.name = spec.id
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
        return try plugin.invoke(type: "tool", id: toolId, payload: argumentsJSON)
    }
}
