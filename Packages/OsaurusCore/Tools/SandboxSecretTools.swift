//
//  SandboxSecretTools.swift
//  osaurus
//
//  Builtin sandbox tools for agent-driven secret management.
//  - sandbox_secret_check: test whether a secret exists (never reveals values)
//  - sandbox_secret_set: prompt the user to provide a secret and store it
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
            return "{\"error\":\"Missing required parameter: key\"}"
        }

        guard let uuid = UUID(uuidString: agentId) else {
            return "{\"error\":\"Invalid agent ID\"}"
        }

        let exists = AgentSecretsKeychain.getSecret(id: key, agentId: uuid) != nil

        let dict: [String: Any] = ["key": key, "exists": exists]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let json = String(data: data, encoding: .utf8)
        else { return "{\"exists\":false}" }
        return json
    }
}

// MARK: - sandbox_secret_set

/// Marker action returned by sandbox_secret_set. The execution engine
/// intercepts this to pause the loop, prompt the user, store the value
/// in Keychain, and resume.
enum SecretPromptAction {
    static let actionKey = "secret_prompt"
}

struct SandboxSecretSetTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_secret_set"
    let description =
        "Prompt the user to provide a secret (API key, token) and store it securely. "
        + "The value is stored in the host keychain, never on the sandbox filesystem. "
        + "Provide clear instructions so the user knows where to obtain the secret."

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
            return "{\"error\":\"Missing required parameters: key, description, instructions\"}"
        }

        let dict: [String: Any] = [
            "action": SecretPromptAction.actionKey,
            "key": key,
            "description": desc,
            "instructions": instructions,
            "agent_id": agentId,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let json = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"Failed to encode prompt\"}" }
        return json
    }
}
