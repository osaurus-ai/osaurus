//
//  SandboxPluginTool.swift
//  osaurus
//
//  Wraps a sandbox plugin tool spec as an OsaurusTool.
//  Translates LLM tool calls into `container exec` commands with
//  agent/plugin secrets and PARAM_* arguments as environment variables.
//

import Foundation

final class SandboxPluginTool: OsaurusTool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?
    let plugin: SandboxPlugin

    private let runCommand: String
    private let parameterSpecs: [String: SandboxParameterSpec]

    let requiresSandbox = true

    init(spec: SandboxToolSpec, plugin: SandboxPlugin) {
        self.name = "\(plugin.id)_\(spec.id)"
        self.description = spec.description
        self.plugin = plugin
        self.runCommand = spec.run
        self.parameterSpecs = spec.parameters ?? [:]
        self.parameters = Self.buildParameterSchema(from: spec.parameters)
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard await SandboxManager.shared.status().isRunning else {
            return encodeResult(stdout: "", stderr: "Sandbox container is not running", exitCode: 1)
        }

        let (agentId, agentName) = await resolveAgent()

        let ready = await SandboxPluginManager.shared.ensureReady(
            pluginId: plugin.id,
            plugin: plugin,
            for: agentId
        )
        guard ready else {
            return encodeResult(
                stdout: "",
                stderr: "Failed to provision plugin '\(plugin.id)' for agent",
                exitCode: 1
            )
        }

        let env = buildExecEnvironment(agentId: agentId, from: argumentsJSON)

        let result = try await SandboxManager.shared.execAsAgent(
            agentName,
            command: runCommand,
            pluginName: plugin.id,
            env: env,
            timeout: 30,
            streamToLogs: true,
            logSource: plugin.id
        )

        return encodeResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode
        )
    }

    // MARK: - Agent Resolution

    private func resolveAgent() async -> (id: String, name: String) {
        let agentId: String
        if let ctxAgent = ChatExecutionContext.currentAgentId {
            agentId = ctxAgent.uuidString
        } else {
            agentId = await MainActor.run { AgentManager.shared.activeAgent.id.uuidString }
        }
        let agentName = await MainActor.run { SandboxAgentProvisioner.linuxName(for: agentId) }
        return (agentId, agentName)
    }

    // MARK: - Environment

    private func buildExecEnvironment(agentId: String, from argumentsJSON: String) -> [String: String] {
        var env: [String: String] = [:]

        if let uuid = UUID(uuidString: agentId) {
            env = AgentSecretsKeychain.mergedSecretsEnvironment(agentId: uuid, pluginId: plugin.id)
        }

        env["OSAURUS_PLUGIN"] = plugin.id
        env.merge(buildParamVars(from: argumentsJSON)) { _, new in new }
        return env
    }

    private func buildParamVars(from argumentsJSON: String) -> [String: String] {
        guard let args = parseArguments(argumentsJSON) else { return [:] }

        var env: [String: String] = [:]
        for (key, value) in args {
            let envKey = "PARAM_\(key.uppercased())"
            if let str = value as? String {
                env[envKey] = str
            } else if let num = value as? NSNumber {
                env[envKey] = num.stringValue
            } else if let bool = value as? Bool {
                env[envKey] = bool ? "true" : "false"
            } else if let data = try? JSONSerialization.data(withJSONObject: value),
                let str = String(data: data, encoding: .utf8)
            {
                env[envKey] = str
            }
        }

        // Apply defaults for missing parameters
        for (key, spec) in parameterSpecs {
            let envKey = "PARAM_\(key.uppercased())"
            if env[envKey] == nil, let defaultValue = spec.default {
                env[envKey] = defaultValue
            }
        }

        return env
    }

    /// Build an OpenAI-compatible JSON Schema from sandbox parameter specs.
    private static func buildParameterSchema(from specs: [String: SandboxParameterSpec]?) -> JSONValue? {
        guard let specs = specs, !specs.isEmpty else { return nil }

        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []

        for (key, spec) in specs {
            var prop: [String: JSONValue] = ["type": .string(spec.type)]
            if let desc = spec.description {
                prop["description"] = .string(desc)
            }
            if let defaultVal = spec.default {
                prop["default"] = .string(defaultVal)
            }
            if let enumVals = spec.enum {
                prop["enum"] = .array(enumVals.map { .string($0) })
            }
            properties[key] = .object(prop)

            if spec.default == nil {
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
        return .object(schema)
    }

    // MARK: - Result Encoding

    private func encodeResult(
        stdout: String,
        stderr: String,
        exitCode: Int32
    ) -> String {
        let dict: [String: Any] = [
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": Int(exitCode),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{\"stdout\":\"\",\"stderr\":\"Failed to encode result\",\"exit_code\":-1}"
        }
        return json
    }
}
