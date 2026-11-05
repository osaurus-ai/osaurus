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

            enum CodingKeys: String, CodingKey {
                case command
                case args
                case env
            }

            // Default a missing `args` to `[]`, matching `EntryPoint` above so the
            // two interchangeable formats behave the same. Without this a valid
            // desktop manifest whose command takes no arguments fails to decode.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                command = try container.decode(String.self, forKey: .command)
                args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
                env = try container.decodeIfPresent([String: String].self, forKey: .env)
            }
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
            resolved[key] = MCPBundleManifest.substituteEnvTokens(
                value,
                environment: ProcessInfo.processInfo.environment
            )
        }
        return resolved
    }

    /// Substitute every `${env:NAME}` token found anywhere in `value` with the
    /// corresponding entry from `environment`. Unset variables resolve to the
    /// empty string (preserving the prior whole-value behavior). Literal text
    /// surrounding a token is left intact, so embedded tokens
    /// (`"https://${env:HOST}/path"`) and multiple tokens (`"${env:A}:${env:B}"`)
    /// both resolve correctly. A value containing no token is returned unchanged.
    static func substituteEnvTokens(_ value: String, environment: [String: String]) -> String {
        guard value.contains("${env:") else { return value }
        let pattern = #"\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }

        let ns = value as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var result = ""
        var cursor = 0
        for match in regex.matches(in: value, range: fullRange) {
            let tokenRange = match.range
            let nameRange = match.range(at: 1)
            // Copy literal text preceding this token.
            if tokenRange.location > cursor {
                result += ns.substring(
                    with: NSRange(location: cursor, length: tokenRange.location - cursor)
                )
            }
            let name = ns.substring(with: nameRange)
            result += environment[name] ?? ""
            cursor = tokenRange.location + tokenRange.length
        }
        // Copy any trailing literal text after the last token.
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }
}
