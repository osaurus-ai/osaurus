//
//  SandboxPluginTool.swift
//  osaurus
//
//  Wraps a sandbox plugin tool spec as an OsaurusTool.
//  Translates LLM tool calls into `container exec` commands with
//  parameters passed as PARAM_* environment variables.
//

import Foundation

final class SandboxPluginTool: OsaurusTool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?
    let pluginId: String
    let agentId: String

    private let runCommand: String
    private let agentName: String
    private let parameterSpecs: [String: SandboxParameterSpec]

    /// Whether this tool requires the sandbox to be running
    let requiresSandbox = true

    init(
        spec: SandboxToolSpec,
        plugin: SandboxPlugin,
        agentId: String,
        agentName: String
    ) {
        self.name = "\(plugin.id)_\(spec.id)"
        self.description = spec.description
        self.pluginId = plugin.id
        self.agentId = agentId
        self.agentName = agentName
        self.runCommand = spec.run
        self.parameterSpecs = spec.parameters ?? [:]
        self.parameters = Self.buildParameterSchema(from: spec.parameters)
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard await SandboxManager.shared.status().isRunning else {
            return encodeResult(stdout: "", stderr: "Sandbox container is not running", exitCode: 1)
        }

        let env = buildEnvVars(from: argumentsJSON)

        let outputBefore = await listOutputFiles()

        let result = try await SandboxManager.shared.execAsAgent(
            agentName,
            command: runCommand,
            pluginName: pluginId,
            env: env,
            timeout: 30,
            streamToLogs: true,
            logSource: pluginId
        )

        let outputAfter = await listOutputFiles()
        let newFiles = outputAfter.subtracting(outputBefore).sorted()

        return encodeResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            newFiles: newFiles
        )
    }

    // MARK: - Parameter Handling

    /// Build PARAM_* environment variables from the JSON arguments.
    private func buildEnvVars(from argumentsJSON: String) -> [String: String] {
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

    // MARK: - Output Tracking

    private func listOutputFiles() async -> Set<String> {
        guard
            let result = try? await SandboxManager.shared.execAsAgent(
                agentName,
                command: "find /output -type f 2>/dev/null"
            ), result.succeeded
        else {
            return []
        }
        return Set(
            result.stdout.split(separator: "\n").map(String.init)
        )
    }

    // MARK: - Result Encoding

    private func encodeResult(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        newFiles: [String] = []
    ) -> String {
        var dict: [String: Any] = [
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": Int(exitCode),
        ]
        if !newFiles.isEmpty {
            dict["new_files"] = newFiles
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{\"stdout\":\"\",\"stderr\":\"Failed to encode result\",\"exit_code\":-1}"
        }
        return json
    }
}
