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
        let context = await SandboxToolRequestContext.resolve(
            fallbackAgentId: agentId
        )
        if let rejection = context.rejection(for: .autonomous, tool: name) {
            return rejection
        }
        let agentId = context.agentId

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
        + "PREFER omitting `value`: the user gets a secure input dialog and the secret never "
        + "enters the conversation. Pass `value` only when you already hold the secret "
        + "(it is stored in Keychain and redacted from the recorded call)."

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
                        "The secret value to store. PREFER OMITTING this — the user is prompted "
                            + "via a secure dialog and the value never enters the conversation. "
                            + "If provided it is stored directly and redacted from the recorded call."
                    ),
                ]),
            ]),
            "required": .array([.string("key"), .string("description"), .string("instructions")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let context = await SandboxToolRequestContext.resolve(
            fallbackAgentId: agentId
        )
        if let rejection = context.rejection(for: .autonomous, tool: name) {
            return rejection
        }
        let agentId = context.agentId

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

        // `value` is optional. Preflight already drops empty-string
        // fillers; what arrives here is either a non-empty string or
        // missing (→ prompt the user). A wrong-typed value (e.g. number
        // for a long token) surfaces a structured failure instead of
        // silently falling through to the prompt path.
        let valueReq = optionalString(
            args,
            "value",
            expected: "the secret value to store (omit to prompt the user)",
            tool: name
        )
        guard case .value(let valueOpt) = valueReq else {
            return valueReq.failureEnvelope ?? ""
        }
        if let value = valueOpt, !value.isEmpty {
            guard let uuid = UUID(uuidString: agentId) else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Invalid agent ID: \(agentId)",
                    tool: name,
                    retryable: false
                )
            }
            // A failed Keychain write (locked keychain, denied ACL,
            // keychain-free process) must surface as a failure. Reporting
            // `stored: true` here would tell the model the secret is
            // available as an env var when `sandbox_exec` will see nothing —
            // observed live as a model echoing an empty variable and then
            // confabulating the value in its final answer.
            guard AgentSecretsKeychain.saveSecret(value, id: key, agentId: uuid) else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message:
                        "Secret storage failed for `\(key)`: the Keychain write "
                        + "did not succeed, so the value will NOT be available to "
                        + "sandbox commands. Do not report the secret as stored.",
                    tool: name,
                    retryable: false
                )
            }
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
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical),
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

// MARK: - Persisted-Argument Scrubbing

/// Execution vs recording views of one tool-call argument payload.
///
/// The direct `value` path of `sandbox_secret_set` must reach
/// `ToolRegistry.execute` intact so Keychain can store the secret, but the
/// same JSON must never re-enter model-visible history, plugin SSE,
/// persistence, or host tool-call logs. Surfaces that need both forms call
/// `split` so the execution/recording boundary is explicit and hard to invert.
struct ToolCallArgumentMaterial: Sendable, Equatable {
    /// Byte-identical arguments for execution and permission gates.
    let forExecution: String
    /// Arguments safe for history, model re-feed, SSE deltas, and logs.
    let forRecording: String

    /// Build both views from the raw model-emitted arguments.
    static func split(toolName: String, argumentsJSON: String) -> ToolCallArgumentMaterial {
        ToolCallArgumentMaterial(
            forExecution: argumentsJSON,
            forRecording: SecretArgumentScrubber.recordedArguments(
                toolName: toolName,
                argumentsJSON: argumentsJSON
            )
        )
    }
}

/// Scrubs the secret `value` out of `sandbox_secret_set` tool-call
/// arguments before they land in recorded / model-visible / plugin-visible
/// material.
///
/// The direct-`value` path stores the secret in Keychain correctly, but
/// the model's tool-call arguments would otherwise ride along in every
/// later context window and in the persisted session file — defeating
/// the Keychain. Execution always sees the original arguments; only the
/// RECORDED copy is scrubbed. Scrubbing fails closed: malformed or
/// non-serializable `sandbox_secret_set` payloads never re-emit the
/// original input.
public enum SecretArgumentScrubber {
    static let redactedPlaceholder = "[REDACTED]"
    private static let allowedSecretSetKeys: Set<String> = [
        "key", "description", "instructions", "value",
    ]

    /// Fail-closed stub used when `sandbox_secret_set` arguments cannot be
    /// parsed or re-serialized without risk of re-emitting a secret.
    static let failClosedArgumentsJSON = #"{"value":"[REDACTED]"}"#

    /// Arguments JSON safe for recorded/model-visible/persisted surfaces.
    /// Non-`sandbox_secret_set` tools return the input byte-for-byte.
    static func recordedArguments(toolName: String, argumentsJSON: String) -> String {
        scrubForPersistence(toolName: toolName, argumentsJSON: argumentsJSON)
    }

    /// Returns scrubbed arguments JSON for `sandbox_secret_set` calls
    /// that carry a secret-bearing `value`; every other *tool* returns its
    /// input unchanged. For `sandbox_secret_set` itself, unparseable or
    /// non-serializable payloads fail closed rather than echoing the
    /// original text (which may still contain a secret).
    public static func scrubForPersistence(toolName: String, argumentsJSON: String) -> String {
        let recordedName = ToolRegistry.deferredToolAliasTarget(toolName) ?? toolName
        guard recordedName == "sandbox_secret_set" else { return argumentsJSON }

        // Malformed / non-object JSON may still embed a secret as raw text.
        // Never re-emit the original payload for this tool.
        guard let data = argumentsJSON.data(using: .utf8),
            var args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return failClosedArgumentsJSON
        }

        // The tool schema forbids unknown fields and requires these three
        // strings. Preserve only structurally valid prompt/direct-call
        // payloads; malformed objects can hide a second copy of the secret
        // under an ignored nested or extra field.
        guard Set(args.keys).isSubset(of: allowedSecretSetKeys),
            args["key"] is String,
            args["description"] is String,
            args["instructions"] is String
        else {
            return failClosedArgumentsJSON
        }

        guard let rawValue = args["value"] else {
            // Valid prompt path (no direct value) — leave byte-identical.
            return argumentsJSON
        }

        if let value = rawValue as? String {
            // Empty / already-redacted values need no rewrite.
            guard !value.isEmpty, value != redactedPlaceholder else {
                return argumentsJSON
            }
            // The model can duplicate the direct secret into another
            // schema-valid string field. Redacting only `value` would then
            // preserve the same credential in recorded history. Replace the
            // exact known value everywhere in the retained object before
            // serializing it.
            for key in ["key", "description", "instructions"] {
                if let string = args[key] as? String {
                    args[key] = string.replacingOccurrences(
                        of: value,
                        with: redactedPlaceholder
                    )
                }
            }
            args["value"] = redactedPlaceholder
        } else {
            // A non-string `value` is outside the tool contract. We do not
            // have a trustworthy scalar to scrub from sibling fields, so
            // retain none of them.
            return failClosedArgumentsJSON
        }

        guard
            let scrubbed = try? JSONSerialization.data(
                withJSONObject: args,
                options: .osaurusCanonical
            ),
            let json = String(data: scrubbed, encoding: .utf8)
        else {
            // Re-serialization should never fail for a dict we just
            // parsed; if it somehow does, fail CLOSED rather than
            // persisting the secret.
            return failClosedArgumentsJSON
        }
        return json
    }

    /// Whether a raw or capability-style tool name identifies the
    /// secret-setting tool. Used to omit raw provider wire snapshots that
    /// cannot be safely rewritten without changing their protocol shape.
    static func isSecretSetToolName(_ toolName: String) -> Bool {
        (ToolRegistry.deferredToolAliasTarget(toolName) ?? toolName) == "sandbox_secret_set"
    }

    /// Build a history/SSE-safe `ToolCall` from an execution invocation.
    /// Use this whenever a surface materializes tool-call args into
    /// history, plugin deltas, or logs; pass `invocation.jsonArguments`
    /// unchanged to `ToolRegistry.execute`.
    ///
    /// Package-internal: takes `ServiceToolInvocation`, which is not part of
    /// the public module surface.
    static func recordedToolCall(
        id: String,
        invocation: ServiceToolInvocation
    ) -> ToolCall {
        ToolCall(
            id: id,
            type: "function",
            function: ToolCallFunction(
                name: invocation.toolName,
                arguments: recordedArguments(
                    toolName: invocation.toolName,
                    argumentsJSON: invocation.jsonArguments
                )
            ),
            geminiThoughtSignature: invocation.geminiThoughtSignature
        )
    }

    /// Scrub every tool-call argument on an assistant message before it
    /// enters multi-turn history. Used by the plugin non-stream path,
    /// which appends the model's full `choice.message` (including raw
    /// `tool_calls`) in one shot.
    ///
    /// Package-internal: takes `ChatMessage`, which is not part of the
    /// public module surface.
    static func recordedAssistantMessage(_ message: ChatMessage) -> ChatMessage {
        guard let calls = message.tool_calls, !calls.isEmpty else { return message }
        let scrubbed = calls.map { call in
            ToolCall(
                id: call.id,
                type: call.type,
                function: ToolCallFunction(
                    name: call.function.name,
                    arguments: recordedArguments(
                        toolName: call.function.name,
                        argumentsJSON: call.function.arguments
                    )
                ),
                geminiThoughtSignature: call.geminiThoughtSignature
            )
        }
        // Preserve identity when nothing secret-bearing was present so
        // unrelated tools keep their exact argument text.
        if zip(calls, scrubbed).allSatisfy({ $0.function.arguments == $1.function.arguments }) {
            return message
        }
        return ChatMessage(
            role: message.role,
            content: message.content,
            contentParts: message.contentParts,
            localAudioSamples: message.localAudioSamples,
            tool_calls: scrubbed,
            tool_call_id: message.tool_call_id,
            reasoning_content: message.reasoning_content,
            reasoning_item_id: message.reasoning_item_id,
            reasoning_encrypted: message.reasoning_encrypted,
            // Native output Items can contain the same unredacted function
            // arguments. Never persist/replay them after secret scrubbing.
            responses_output_items: nil
        )
    }

    /// Copy a completion response for persistence while preserving transport
    /// metadata and redacting only assistant tool-call arguments.
    static func recordedResponse(_ response: ChatCompletionResponse) -> ChatCompletionResponse {
        var recorded = ChatCompletionResponse(
            id: response.id,
            created: response.created,
            model: response.model,
            choices: response.choices.map {
                ChatChoice(
                    index: $0.index,
                    message: recordedAssistantMessage($0.message),
                    finish_reason: $0.finish_reason
                )
            },
            usage: response.usage,
            system_fingerprint: response.system_fingerprint
        )
        recorded.object = response.object
        recorded.prefix_hash = response.prefix_hash
        return recorded
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
