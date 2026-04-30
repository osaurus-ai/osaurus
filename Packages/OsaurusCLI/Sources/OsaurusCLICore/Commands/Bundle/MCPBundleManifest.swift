//
//  MCPBundleManifest.swift
//  osaurus
//
//  Model for MCPB (MCP Bundle) manifest.json files.
//  Supports both standard MCPB format and desktop-client integration format.
//

import Foundation

struct MCPBundleManifest: Codable {
    // Standard MCPB format
    let mcpVersion: String?

    // Desktop-client integration format
    let manifestVersion: String?

    let name: String
    let version: String
    let displayName: String?
    let description: String?
    let entry: EntryPoint?

    // Desktop-client integration format
    let server: ServerConfig?
    let icon: String?

    enum CodingKeys: String, CodingKey {
        case mcpVersion
        case manifestVersion = "manifest_version"
        case name
        case version
        case displayName
        case description
        case entry
        case server
        case icon
    }

    struct EntryPoint: Codable {
        let command: String
        let args: [String]
        let env: [String: String]?

        enum CodingKeys: String, CodingKey {
            case command
            case args
            case env
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(String.self, forKey: .command)
            args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            env = try container.decodeIfPresent([String: String].self, forKey: .env)
        }
    }

    struct ServerConfig: Codable {
        let type: String?
        let entryPoint: String?
        let mcpConfig: MCPConfig?

        enum CodingKeys: String, CodingKey {
            case type
            case entryPoint = "entry_point"
            case mcpConfig = "mcp_config"
        }

        struct MCPConfig: Codable {
            let command: String
            let args: [String]
            let env: [String: String]?
        }
    }

    /// Get the entry point, supporting both formats
    func getEntryPoint() -> (command: String, args: [String], env: [String: String]?) {
        // Try standard MCPB format first
        if let entry = entry {
            return (entry.command, entry.args, entry.env)
        }

        // Try desktop-client integration format
        if let server = server, let config = server.mcpConfig {
            return (config.command, config.args, config.env)
        }

        // Default fallback
        return ("", [], nil)
    }

    /// Resolve environment variables, substituting ${env:VAR_NAME} with actual values
    func resolveEnvironment() -> [String: String] {
        let (_, _, env) = getEntryPoint()
        var resolved: [String: String] = [:]
        for (key, value) in (env ?? [:]) {
            if value.hasPrefix("${env:"), value.hasSuffix("}") {
                let envVar = String(value.dropFirst(6).dropLast(1))
                resolved[key] = ProcessInfo.processInfo.environment[envVar] ?? ""
            } else {
                resolved[key] = value
            }
        }
        return resolved
    }
}
