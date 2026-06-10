//
//  SandboxPluginTool.swift
//  osaurus
//
//  Wraps a sandbox plugin tool spec as an OsaurusTool.
//  Translates LLM tool calls into `container exec` commands with
//  agent/plugin secrets and PARAM_* arguments as environment variables.
//
//  Resilience contract (mirrors built-in sandbox tools):
//   - Schema is generated with `additionalProperties: false` and typed
//     `default`s (string defaults are parsed under `integer`/`number`/
//     `boolean` types) so the central preflight rejects unknown keys
//     and surfaces typed-default semantics correctly.
//   - Per-parameter validation runs through the standard `requireXxx`
//     helpers, picking the right helper from `SandboxParameterSpec.type`,
//     so a missing or wrong-typed argument returns a structured
//     `ToolEnvelope.failure(invalid_args)` with `field` + `expected`.
//   - Successful invocations return `ToolEnvelope.success(result:
//     {stdout, stderr, exit_code})` with stdout/stderr capped via
//     `truncateForModel`. Non-zero exits surface as
//     `ToolEnvelope.failure(execution_error)` so the chat UI's
//     `isError` / `isSuccess` detectors classify the result correctly.
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
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Sandbox container is not running. Start it before invoking this tool.",
                tool: name,
                retryable: true
            )
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        // Per-parameter validation. The preflight has already coerced the
        // values to the schema's declared types; here we only need to
        // assert presence (or default-fallback) and surface the standard
        // missing-/wrong-type envelope per spec.
        if let envelope = validateArguments(args) { return envelope }

        let (agentId, agentName) = await resolveAgent()

        let ready = await SandboxPluginManager.shared.ensureReady(
            pluginId: plugin.id,
            plugin: plugin,
            for: agentId
        )
        guard ready else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Failed to provision plugin '\(plugin.id)' for agent. Try again — "
                    + "the plugin install may still be in flight.",
                tool: name,
                retryable: true
            )
        }

        // Captured separately from the full env so post-exec scrubbing
        // only matches actual secret values, never PARAM_* arguments.
        let secrets = secretEnvironment(agentId: agentId)
        let env = buildExecEnvironment(secrets: secrets, from: args)

        let result: ContainerExecResult
        do {
            result = try await SandboxManager.shared.execAsAgent(
                agentName,
                command: runCommand,
                pluginName: plugin.id,
                env: env,
                timeout: 30,
                streamToLogs: true,
                logSource: plugin.id
            )
        } catch {
            return ToolEnvelope.fromError(error, tool: name)
        }

        // Secrets ride into the plugin's env, so any script that prints
        // its config would exfiltrate them — scrub before enveloping.
        return encodeResult(
            stdout: SecretScrubber.scrub(result.stdout, secrets: secrets),
            stderr: SecretScrubber.scrub(result.stderr, secrets: secrets),
            exitCode: result.exitCode
        )
    }

    // MARK: - Per-Parameter Validation

    /// Walk `parameterSpecs` and validate each required argument
    /// against its declared type. Returns the first failure envelope
    /// encountered, or nil when every required argument is present and
    /// well-typed. Optional parameters (those with a `default`) are
    /// skipped — they fall through to the env-var defaulting in
    /// `buildParamVars`.
    private func validateArguments(_ args: [String: Any]) -> String? {
        for (key, spec) in parameterSpecs where spec.default == nil {
            let expected = spec.description ?? "value of type `\(spec.type)`"
            switch spec.type.lowercased() {
            case "string":
                if case .failure(let env) = requireString(args, key, expected: expected, tool: name) {
                    return env
                }
            case "integer":
                if case .failure(let env) = requireInt(args, key, expected: expected, tool: name) {
                    return env
                }
            case "array":
                if case .failure(let env) = requireStringArray(args, key, expected: expected, tool: name) {
                    return env
                }
            case "boolean":
                if let env = requireScalar(
                    args,
                    key,
                    expected: expected,
                    kindName: "boolean",
                    parse: { ArgumentCoercion.bool($0) }
                ) {
                    return env
                }
            case "number":
                if let env = requireScalar(
                    args,
                    key,
                    expected: expected,
                    kindName: "number",
                    parse: { (raw: Any) -> Double? in
                        (raw as? NSNumber)?.doubleValue
                            ?? (raw as? String).flatMap { Double($0) }
                    }
                ) {
                    return env
                }
            default:
                // Unknown declared type → fall back to a permissive
                // presence check rather than blocking the call.
                if args[key] == nil {
                    return missingArgEnvelope(key: key, expected: expected)
                }
            }
        }
        return nil
    }

    /// Validate a scalar argument that doesn't have a dedicated
    /// `requireXxx` helper. Returns nil when the value is present and
    /// `parse` accepts it, or a structured failure envelope otherwise.
    private func requireScalar<T>(
        _ args: [String: Any],
        _ key: String,
        expected: String,
        kindName: String,
        parse: (Any) -> T?
    ) -> String? {
        guard let raw = args[key] else {
            return missingArgEnvelope(key: key, expected: expected)
        }
        if parse(raw) == nil {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Argument `\(key)` must be a \(kindName) (\(expected)). "
                    + "Got \(type(of: raw)).",
                field: key,
                expected: expected,
                tool: name
            )
        }
        return nil
    }

    private func missingArgEnvelope(key: String, expected: String) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Missing required argument `\(key)` (\(expected)).",
            field: key,
            expected: expected,
            tool: name
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

    /// The agent + plugin secrets injected into the exec env. Kept as a
    /// separate dict so the post-exec scrubber knows the exact values.
    private func secretEnvironment(agentId: String) -> [String: String] {
        guard let uuid = UUID(uuidString: agentId) else { return [:] }
        return AgentSecretsKeychain.mergedSecretsEnvironment(agentId: uuid, pluginId: plugin.id)
    }

    private func buildExecEnvironment(
        secrets: [String: String],
        from args: [String: Any]
    ) -> [String: String] {
        var env = secrets
        env["OSAURUS_PLUGIN"] = plugin.id
        env.merge(buildParamVars(from: args)) { _, new in new }
        return env
    }

    private func buildParamVars(from args: [String: Any]) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in args {
            let envKey = "PARAM_\(key.uppercased())"
            if let str = value as? String {
                env[envKey] = str
            } else if let num = value as? NSNumber {
                env[envKey] = num.stringValue
            } else if let bool = value as? Bool {
                env[envKey] = bool ? "true" : "false"
            } else if let data = try? JSONSerialization.data(withJSONObject: value, options: .osaurusCanonical),
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
    ///
    /// `additionalProperties: false` is set unconditionally so the
    /// central preflight rejects unknown keys with `field` pointing at
    /// the offender. `default` values are emitted with the proper JSON
    /// type — `SandboxParameterSpec.default` is always a string at the
    /// model layer (it's authored in JSON), so we re-parse it under the
    /// declared `type` to avoid handing the schema validator a typed-as-
    /// integer property whose `default` is a string.
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
                prop["default"] = typedDefault(defaultVal, type: spec.type)
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
            "additionalProperties": .bool(false),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required)
        }
        return .object(schema)
    }

    /// Re-encode a string `default` under the right JSON type. Falls
    /// back to a string default when parsing fails — an authoring bug
    /// (e.g. `default: "abc"` on an integer field) shouldn't crash the
    /// schema build, just be slightly mis-typed in the validator.
    private static func typedDefault(_ raw: String, type: String) -> JSONValue {
        switch type.lowercased() {
        case "integer":
            if let n = Int(raw) { return .number(Double(n)) }
            if let d = Double(raw), d.rounded() == d { return .number(d) }
            return .string(raw)
        case "number":
            if let d = Double(raw) { return .number(d) }
            return .string(raw)
        case "boolean":
            if let b = ArgumentCoercion.bool(raw) { return .bool(b) }
            return .string(raw)
        default:
            return .string(raw)
        }
    }

    // MARK: - Result Encoding

    /// Wrap the container exec result in the standard envelope. Success
    /// (exit 0) → `ToolEnvelope.success(result: {...})`; non-zero →
    /// `ToolEnvelope.failure(execution_error, ..., metadata: {...})` so
    /// downstream code can branch on `kind` without parsing the
    /// payload's `exit_code` field. Stdout/stderr are bounded with
    /// `truncateForModel` so a runaway plugin can't blow the context
    /// window.
    private func encodeResult(
        stdout: String,
        stderr: String,
        exitCode: Int32
    ) -> String {
        let payload: [String: Any] = [
            "stdout": truncateForModel(stdout),
            "stderr": truncateForModel(stderr, maxChars: ToolOutputCaps.execStderr),
            "exit_code": Int(exitCode),
        ]
        if exitCode == 0 {
            return ToolEnvelope.success(tool: name, result: payload)
        }
        return ToolEnvelope.failure(
            kind: .executionError,
            message: "Plugin '\(plugin.id)' exited \(exitCode): \(failureDetail(payload))",
            tool: name,
            retryable: true,
            metadata: payload
        )
    }

    /// Pick the most informative line from the truncated stdout/stderr
    /// pair to embed in the failure envelope's `message`. Stderr wins
    /// when present; falls back to stdout for plugins that route
    /// everything through one stream; ultimately reports `no output` so
    /// the message is never empty.
    private func failureDetail(_ payload: [String: Any]) -> String {
        let stderr =
            (payload["stderr"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stderr.isEmpty { return stderr }
        let stdout =
            (payload["stdout"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stdout.isEmpty { return stdout }
        return "no output"
    }
}
