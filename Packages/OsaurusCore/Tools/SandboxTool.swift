//
//  SandboxTool.swift
//  osaurus
//
//  Wraps a sandbox plugin tool as an OsaurusTool. Executes commands inside
//  the agent's VM via vsock, passing parameters as PARAM_* env vars.
//

import Foundation

final class SandboxTool: OsaurusTool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?

    let pluginName: String
    let agentId: UUID
    let runCommand: String
    let timeout: Int
    let secretNames: [String]

    /// The original tool ID from the plugin JSON (without prefix).
    let toolId: String

    /// Compute the globally unique tool name: `{pluginName}_{toolId}`.
    static func registeredName(pluginName: String, toolId: String) -> String {
        "\(pluginName)_\(toolId)"
    }

    init(pluginName: String, spec: SandboxToolSpec, agentId: UUID, secrets: [String]) {
        self.pluginName = pluginName
        self.toolId = spec.id
        self.name = Self.registeredName(pluginName: pluginName, toolId: spec.id)
        self.description = spec.description
        self.runCommand = spec.run
        self.timeout = spec.timeout ?? 30
        self.agentId = agentId
        self.secretNames = secrets

        if let params = spec.parameters {
            var properties: [String: JSONValue] = [:]
            var required: [JSONValue] = []
            for (key, paramSpec) in params {
                var prop: [String: JSONValue] = [
                    "type": .string(paramSpec.type),
                ]
                if let desc = paramSpec.description {
                    prop["description"] = .string(desc)
                }
                if let def = paramSpec.default {
                    prop["default"] = .string(def)
                }
                if let enumVals = paramSpec.enum {
                    prop["enum"] = .array(enumVals.map { .string($0) })
                }
                properties[key] = .object(prop)
                if paramSpec.default == nil {
                    required.append(.string(key))
                }
            }

            var schema: [String: JSONValue] = [
                "type": .string("object"),
                "properties": .object(properties),
            ]
            if !required.isEmpty {
                schema["required"] = .array(required)
            }
            self.parameters = .object(schema)
        } else {
            self.parameters = nil
        }
    }

    func execute(argumentsJSON: String) async throws -> String {
        try await VMManager.shared.ensureRunning(agentId: agentId)

        // Vsock may not be ready immediately after boot; retry briefly.
        var conn: VsockConnection?
        for _ in 0..<10 {
            conn = await MainActor.run { VMManager.shared.vsockConnection(for: agentId) }
            if conn != nil { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let conn else {
            return """
            {"error":"vsock_unavailable","message":"VM is running but vsock connection not established"}
            """
        }

        let args = parseArguments(argumentsJSON)
        var env = buildEnvVars(from: args)
        injectSecrets(into: &env)

        // Snapshot /output/ before
        let beforeFiles = (try? await conn.listFiles(path: "/output")) ?? []

        let result = try await conn.exec(
            command: runCommand,
            cwd: "/workspace/plugins/\(pluginName)",
            env: env,
            timeout: timeout
        )

        // Diff /output/ after
        let afterFiles = (try? await conn.listFiles(path: "/output")) ?? []
        let newFiles = afterFiles.filter { !beforeFiles.contains($0) }

        var response: [String: Any] = [
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": result.exitCode,
        ]
        if !newFiles.isEmpty {
            response["new_files"] = newFiles
        }

        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            return """
            {"stdout":"","stderr":"serialization error","exit_code":-1}
            """
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Helpers

    private func parseArguments(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var result: [String: String] = [:]
        for (key, value) in dict {
            if let str = value as? String {
                result[key] = str
            } else if let num = value as? NSNumber {
                result[key] = num.stringValue
            } else if let bool = value as? Bool {
                result[key] = bool ? "true" : "false"
            }
        }
        return result
    }

    /// Convert tool parameters to PARAM_* environment variables.
    private func buildEnvVars(from args: [String: String]) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in args {
            let envKey = "PARAM_\(key.uppercased())"
            env[envKey] = value
        }
        env["OSAURUS_PLUGIN"] = pluginName
        return env
    }

    /// Inject plugin secrets from Keychain into the env vars.
    private func injectSecrets(into env: inout [String: String]) {
        for secretName in secretNames {
            if let value = ToolSecretsKeychain.getSecret(id: secretName, for: pluginName, agentId: agentId) {
                env[secretName] = value
            }
        }
    }
}

// MARK: - MCP Sandbox Tool

/// Wraps a discovered MCP tool as an OsaurusTool, routing invocations through MCPBridge.
final class MCPSandboxTool: OsaurusTool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?

    let pluginName: String
    let agentId: UUID
    let mcpToolName: String
    private let plugin: SandboxPlugin

    static func registeredName(pluginName: String, mcpToolName: String) -> String {
        "\(pluginName)_\(mcpToolName)"
    }

    init(pluginName: String, plugin: SandboxPlugin, discovered: DiscoveredMCPTool, agentId: UUID) {
        self.pluginName = pluginName
        self.mcpToolName = discovered.name
        self.name = Self.registeredName(pluginName: pluginName, mcpToolName: discovered.name)
        self.description = discovered.description
        self.agentId = agentId
        self.plugin = plugin

        if let schemaJSON = discovered.inputSchemaJSON,
           let data = schemaJSON.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            self.parameters = json
        } else {
            self.parameters = nil
        }
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args: [String: Any]
        if let data = argumentsJSON.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = dict
        } else {
            args = [:]
        }

        return try await MCPBridge.shared.invokeTool(
            agentId: agentId,
            plugin: plugin,
            toolName: mcpToolName,
            arguments: args
        )
    }
}
