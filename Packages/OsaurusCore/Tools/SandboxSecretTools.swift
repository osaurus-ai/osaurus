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
        "Check whether a secret (API key, token) exists for the current agent. "
        + "Returns whether the secret is stored — never reveals the value."

    let agentId: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "key": .object([
                    "type": .string("string"),
                    "description": .string("Secret name to check (e.g. NOTION_API_KEY)"),
                ])
            ]),
            "required": .array([.string("key")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let key = args["key"] as? String,
            !key.isEmpty
        else {
            return SecretToolResult.error("Missing required parameter: key")
        }

        guard let uuid = UUID(uuidString: agentId) else {
            return SecretToolResult.error("Invalid agent ID")
        }

        let exists = AgentSecretsKeychain.getSecret(id: key, agentId: uuid) != nil
        return SecretToolResult.encode(["key": key, "exists": exists])
    }
}

// MARK: - sandbox_secret_set

/// Marker action returned by sandbox_secret_set when no value is provided.
/// The execution loop (Chat or Work) intercepts this to show a secure prompt
/// overlay, store the result in Keychain, and resume.
enum SecretPromptAction {
    static let actionKey = "secret_prompt"
}

struct SandboxSecretSetTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_secret_set"
    let description =
        "Store a secret (API key, token) securely for the current agent. "
        + "If you already have the value, pass it directly via the 'value' parameter. "
        + "If you don't have the value, omit 'value' and the user will be prompted."

    let agentId: String

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "properties": .object([
                "key": .object([
                    "type": .string("string"),
                    "description": .string("Secret name (e.g. NOTION_API_KEY)"),
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Human-readable description of this secret"),
                ]),
                "instructions": .object([
                    "type": .string("string"),
                    "description": .string("Instructions for the user on how to obtain this secret"),
                ]),
                "value": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The secret value to store. If provided, stores directly without prompting. "
                            + "Omit to prompt the user via a secure input dialog."
                    ),
                ]),
            ]),
            "required": .array([.string("key"), .string("description"), .string("instructions")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let args = parseArguments(argumentsJSON),
            let key = args["key"] as? String,
            !key.isEmpty,
            let desc = args["description"] as? String,
            let instructions = args["instructions"] as? String
        else {
            return SecretToolResult.error("Missing required parameters: key, description, instructions")
        }

        if let value = args["value"] as? String, !value.isEmpty {
            guard let uuid = UUID(uuidString: agentId) else {
                return SecretToolResult.error("Invalid agent ID")
            }
            AgentSecretsKeychain.saveSecret(value, id: key, agentId: uuid)
            return SecretToolResult.stored(key: key)
        }

        // No value — return marker for the execution loop to intercept and prompt
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

enum SecretToolResult {
    static func encode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let json = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"Failed to encode result\"}" }
        return json
    }

    static func error(_ message: String) -> String {
        encode(["error": message])
    }

    static func stored(key: String) -> String {
        encode(["stored": true, "key": key])
    }

    static func cancelled(key: String) -> String {
        encode(["stored": false, "key": key, "reason": "User cancelled"])
    }
}
