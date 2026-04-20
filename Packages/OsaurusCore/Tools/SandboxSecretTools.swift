//
//  SandboxSecretTools.swift
//  osaurus
//
//  Builtin sandbox tools for agent-driven secret management.
//  - sandbox_secret_check: test whether a secret exists (never reveals values)
//  - sandbox_secret_set: store a secret directly or prompt the user to provide one
//

import Foundation

// MARK: - sandbox_secret_check

struct SandboxSecretCheckTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_secret_check"
    let description =
        "Check whether a named secret exists for the current agent. Returns whether the secret is "
        + "stored — never reveals the value. Useful before a tool call that needs the secret as an "
        + "env var (so you can `sandbox_secret_set` first if missing)."

    let agentId: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "key": .object([
                    "type": .string("string"),
                    "description": .string("Secret name to check (e.g. `NOTION_API_KEY`)."),
                ])
            ]),
            "required": .array([.string("key")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let keyReq = requireString(
            args,
            "key",
            expected: "secret name (e.g. `NOTION_API_KEY`)",
            tool: name
        )
        guard case .value(let key) = keyReq else { return keyReq.failureEnvelope ?? "" }

        guard let uuid = UUID(uuidString: agentId) else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Invalid agent ID: \(agentId)",
                tool: name,
                retryable: false
            )
        }

        let exists = AgentSecretsKeychain.getSecret(id: key, agentId: uuid) != nil
        return ToolEnvelope.success(tool: name, result: ["key": key, "exists": exists])
    }
}

// MARK: - sandbox_secret_set

/// Marker action returned by sandbox_secret_set when no value is provided.
/// The execution loop (Chat or Work) intercepts this to show a secure prompt
/// overlay, store the result in Keychain, and resume.
///
/// This marker is NOT a `ToolEnvelope` — it carries instructions for the
/// chat loop to render an inline secure-input UI. The chat loop replaces
/// the marker with a proper `ToolEnvelope.success(...)` once the user
/// either submits or cancels.
enum SecretPromptAction {
    static let actionKey = "secret_prompt"
}

struct SandboxSecretSetTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_secret_set"
    let description =
        "Store a secret (API key, token) securely for the current agent. "
        + "Pass `value` if you already have it; omit to prompt the user via a secure dialog "
        + "(the chat loop intercepts the prompt marker and surfaces an input overlay)."

    let agentId: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "key": .object([
                    "type": .string("string"),
                    "description": .string("Secret name (e.g. `NOTION_API_KEY`)."),
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Human-readable description of what this secret is."),
                ]),
                "instructions": .object([
                    "type": .string("string"),
                    "description": .string("Instructions shown to the user on how to obtain this secret."),
                ]),
                "value": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The secret value to store. If provided, stored directly without prompting. "
                            + "Omit to prompt the user via a secure input dialog."
                    ),
                ]),
            ]),
            "required": .array([.string("key"), .string("description"), .string("instructions")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let keyReq = requireString(
            args,
            "key",
            expected: "secret name (e.g. `NOTION_API_KEY`)",
            tool: name
        )
        guard case .value(let key) = keyReq else { return keyReq.failureEnvelope ?? "" }

        let descReq = requireString(
            args,
            "description",
            expected: "human-readable description of the secret",
            tool: name
        )
        guard case .value(let desc) = descReq else { return descReq.failureEnvelope ?? "" }

        let instReq = requireString(
            args,
            "instructions",
            expected: "instructions for the user on how to obtain the secret",
            tool: name
        )
        guard case .value(let instructions) = instReq else { return instReq.failureEnvelope ?? "" }

        if let value = args["value"] as? String, !value.isEmpty {
            guard let uuid = UUID(uuidString: agentId) else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Invalid agent ID: \(agentId)",
                    tool: name,
                    retryable: false
                )
            }
            AgentSecretsKeychain.saveSecret(value, id: key, agentId: uuid)
            return SecretToolResult.stored(key: key)
        }

        // No value — return the special prompt marker for the execution
        // loop to intercept. The marker is intentionally NOT an envelope
        // because `SecretPromptParser` keys off the `action` field at the
        // root of the JSON object.
        return SecretToolResult.encode([
            "action": SecretPromptAction.actionKey,
            "key": key,
            "description": desc,
            "instructions": instructions,
            "agent_id": agentId,
        ])
    }
}

// MARK: - Shared Result Encoding

/// Helpers for the secret tools' two unusual result paths:
///   - `stored` / `cancelled` carry the new envelope shape so the model
///     and downstream UI agree with every other tool.
///   - `encode(_:)` is the bare JSON serializer used by the prompt-marker
///     branch in `sandbox_secret_set` (see `SecretPromptAction`). It
///     deliberately does NOT wrap in an envelope — `SecretPromptParser`
///     keys off the `action` field at the JSON root.
enum SecretToolResult {
    static func encode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let json = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"Failed to encode result\"}" }
        return json
    }

    static func stored(key: String) -> String {
        ToolEnvelope.success(
            tool: "sandbox_secret_set",
            result: ["stored": true, "key": key]
        )
    }

    static func cancelled(key: String) -> String {
        ToolEnvelope.failure(
            kind: .userDenied,
            message: "User cancelled the secret prompt for `\(key)`.",
            tool: "sandbox_secret_set",
            retryable: false
        )
    }
}

// MARK: - Prompt Marker Parsing

/// Parses the JSON marker emitted by `sandbox_secret_set` when no value
/// was provided. The chat loop intercepts this marker, opens a secure
/// input overlay, and replaces the tool result with a stored/cancelled
/// envelope.
struct SecretPromptParser {
    let key: String
    let description: String
    let instructions: String
    let agentId: String

    static func parse(_ resultText: String) -> SecretPromptParser? {
        guard let data = resultText.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let action = json["action"] as? String,
            action == SecretPromptAction.actionKey,
            let key = json["key"] as? String,
            let desc = json["description"] as? String,
            let instructions = json["instructions"] as? String,
            let agentId = json["agent_id"] as? String
        else { return nil }
        return SecretPromptParser(
            key: key,
            description: desc,
            instructions: instructions,
            agentId: agentId
        )
    }
}
