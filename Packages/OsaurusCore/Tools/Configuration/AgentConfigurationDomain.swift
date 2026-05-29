//
//  AgentConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tools for custom agents:
//   - osaurus_agent_create
//   - osaurus_agent_update
//   - osaurus_agent_delete
//   - osaurus_agent_activate
//
//  The default agent itself is *not* self-mutable — those tools refuse
//  every `id == Agent.defaultId` and every `agent.isBuiltIn == true`.
//  The user edits the default agent's persona/model/temperature in
//  Settings → Chat (Phase B).
//

import Foundation

enum AgentConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "agents",
        displayName: "Agents",
        summary: "Custom agents the user creates: persona, model, temperature, autonomous exec.",
        menuHint: "create / update / delete / activate custom agents (default agent is edited in Settings)",
        searchKeywords: [
            "agent", "agents", "custom agent", "persona",
            "switch agent", "switch active agent", "set active",
            "create agent", "new agent", "make an agent",
            "update agent", "edit agent", "rename agent",
            "delete agent", "remove agent",
            "activate agent", "use agent",
        ],
        exampleQueries: [
            "create a research agent",
            "make an agent that summarizes news",
            "switch to my coding agent",
            "delete the test agent",
            "update the research agent's prompt",
        ],
        tools: [
            OsaurusAgentCreateTool(),
            OsaurusAgentUpdateTool(),
            OsaurusAgentDeleteTool(),
            OsaurusAgentActivateTool(),
        ],
        writeToolNames: [
            "osaurus_agent_create",
            "osaurus_agent_update",
            "osaurus_agent_delete",
            "osaurus_agent_activate",
        ]
    )
}

// MARK: - osaurus_agent_create

public final class OsaurusAgentCreateTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_agent_create"
    public let description =
        "Create a new custom agent (persona). Requires `name`. Optional `description`, `system_prompt`, "
        + "`default_model`, `temperature` (0..2), `max_tokens`. The default agent cannot be created — "
        + "users edit it in Settings → Chat."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Display name for the new agent."),
            ]),
            "description": .object(["type": .string("string")]),
            "system_prompt": .object([
                "type": .string("string"),
                "description": .string("Persona prompt. Optional."),
            ]),
            "default_model": .object([
                "type": .string("string"),
                "description": .string("Installed local model id or connected cloud model id. Optional."),
            ]),
            "temperature": .object([
                "type": .string("number"),
                "description": .string("0..2. Optional."),
            ]),
            "max_tokens": .object([
                "type": .string("integer"),
                "description": .string("Max tokens per response. Optional."),
            ]),
        ]),
        "required": .array([.string("name")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let nameReq = requireString(
            args,
            "name",
            expected: "non-empty display name",
            tool: name
        )
        guard case .value(let agentName) = nameReq else { return nameReq.failureEnvelope ?? "" }

        let description = (args["description"] as? String) ?? ""
        let systemPrompt = (args["system_prompt"] as? String) ?? ""
        let defaultModel = args["default_model"] as? String
        let temperature: Float? = {
            if let n = args["temperature"] as? Double { return Float(n) }
            if let n = args["temperature"] as? NSNumber { return n.floatValue }
            return nil
        }()
        let maxTokens = coerceInt(args["max_tokens"])

        let agent = await MainActor.run {
            AgentManager.shared.create(
                name: agentName,
                description: description,
                systemPrompt: systemPrompt,
                defaultModel: defaultModel,
                temperature: temperature,
                maxTokens: maxTokens
            )
        }

        return ToolEnvelope.success(
            tool: name,
            result: [
                "agent_id": agent.id.uuidString,
                "name": agent.name,
                "status": "created",
                "next_steps": [
                    "call osaurus_describe({scope: 'agents', id: '\(agent.id.uuidString)'}) to see effective settings",
                    "call osaurus_agent_activate({id: '\(agent.id.uuidString)'}) to switch to it",
                ],
            ]
        )
    }
}

// MARK: - osaurus_agent_update

public final class OsaurusAgentUpdateTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_agent_update"
    public let description =
        "Patch an existing custom agent. Requires `id`. All other fields optional; "
        + "absent = unchanged. Refuses the default agent and any built-in (edit those in Settings)."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "id": .object(["type": .string("string")]),
            "name": .object(["type": .string("string")]),
            "description": .object(["type": .string("string")]),
            "system_prompt": .object(["type": .string("string")]),
            "default_model": .object(["type": .string("string")]),
            "temperature": .object(["type": .string("number")]),
            "max_tokens": .object(["type": .string("integer")]),
        ]),
        "required": .array([.string("id")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let idReq = requireString(args, "id", expected: "UUID of an existing custom agent", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`id` must be a valid UUID.",
                field: "id",
                expected: "UUID string",
                tool: name
            )
        }

        let result: String = await MainActor.run {
            guard var agent = AgentManager.shared.agent(for: id) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No agent found with id \(idStr).",
                    field: "id",
                    tool: name
                )
            }
            if id == Agent.defaultId || agent.isBuiltIn {
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: "Default and built-in agents are edited in Settings → Chat, not via chat.",
                    tool: name,
                    retryable: false
                )
            }

            if let v = args["name"] as? String { agent.name = v }
            if let v = args["description"] as? String { agent.description = v }
            if let v = args["system_prompt"] as? String { agent.systemPrompt = v }
            if args.keys.contains("default_model") {
                agent.defaultModel = args["default_model"] as? String
            }
            if let v = args["temperature"] as? Double {
                agent.temperature = Float(v)
            } else if let v = args["temperature"] as? NSNumber {
                agent.temperature = v.floatValue
            }
            if let v = coerceInt(args["max_tokens"]) { agent.maxTokens = v }

            AgentManager.shared.update(agent)
            return ToolEnvelope.success(
                tool: name,
                result: ["agent_id": agent.id.uuidString, "status": "updated"]
            )
        }
        return result
    }
}

// MARK: - osaurus_agent_delete

public final class OsaurusAgentDeleteTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_agent_delete"
    public let description =
        "Delete a custom agent by `id`. Refuses the default agent and any built-in. "
        + "Removes its persisted record; the user is responsible for any cleanup of agent-owned data."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object(["id": .object(["type": .string("string")])]),
        "required": .array([.string("id")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let idReq = requireString(args, "id", expected: "UUID of an existing custom agent", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`id` must be a valid UUID.",
                tool: name
            )
        }

        if id == Agent.defaultId {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Default agent cannot be deleted.",
                tool: name,
                retryable: false
            )
        }

        let agent = await MainActor.run { AgentManager.shared.agent(for: id) }
        guard let agent else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No agent found with id \(idStr).",
                tool: name
            )
        }
        if agent.isBuiltIn {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Built-in agents cannot be deleted.",
                tool: name,
                retryable: false
            )
        }

        let deleteResult = await AgentManager.shared.delete(id: id)
        let resultPayload: [String: Any] = [
            "agent_id": id.uuidString,
            "status": "deleted",
            "summary": String(describing: deleteResult),
        ]
        return ToolEnvelope.success(tool: name, result: resultPayload)
    }
}

// MARK: - osaurus_agent_activate

public final class OsaurusAgentActivateTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_agent_activate"
    public let description =
        "Switch the active agent to `id`. Switching back to the Default agent is allowed."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object(["id": .object(["type": .string("string")])]),
        "required": .array([.string("id")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let idReq = requireString(args, "id", expected: "UUID of an existing agent", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`id` must be a valid UUID.",
                tool: name
            )
        }

        let switched: Bool = await MainActor.run {
            let exists = AgentManager.shared.agent(for: id) != nil || id == Agent.defaultId
            if exists { AgentManager.shared.setActiveAgent(id) }
            return exists
        }
        guard switched else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No agent found with id \(idStr).",
                tool: name
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["agent_id": id.uuidString, "status": "activated"]
        )
    }
}
