//
//  AgentConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tool for custom agents. One tool,
//  `osaurus_agent`, fans out across four actions:
//   - create
//   - update
//   - delete
//   - activate
//
//  The default agent itself is *not* self-mutable — create/update/delete
//  refuse every `id == Agent.defaultId` and every `agent.isBuiltIn == true`
//  (activate back to the Default agent is allowed). The user edits the
//  default agent's persona/model/temperature in Settings → Chat.
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
            OsaurusAgentTool()
        ],
        writeToolNames: [
            "osaurus_agent"
        ]
    )
}

// MARK: - osaurus_agent

public final class OsaurusAgentTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_agent"
    public let description =
        "Manage custom agents (personas). `action`: create (needs `name`; optional `description`, "
        + "`system_prompt`, `default_model`, `temperature` 0..2, `max_tokens`), update (needs `id`; other "
        + "fields patch), delete (needs `id`), activate (needs `id`; switching back to the Default agent is "
        + "allowed). The Default agent is edited in Settings → Chat, not here."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("create"), .string("update"), .string("delete"), .string("activate"),
                ]),
                "description": .string("Operation to perform."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string("Agent UUID. Required for update / delete / activate."),
            ]),
            "name": .object([
                "type": .string("string"),
                "description": .string("Display name. Required for create."),
            ]),
            "description": .object(["type": .string("string")]),
            "system_prompt": .object(["type": .string("string")]),
            "default_model": .object([
                "type": .string("string"),
                "description": .string("Installed local model id or connected cloud model id."),
            ]),
            "temperature": .object(["type": .string("number")]),
            "max_tokens": .object(["type": .string("integer")]),
        ]),
        "required": .array([.string("action")]),
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
        let actionReq = requireAction(args, allowed: ["create", "update", "delete", "activate"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "create": return await handleCreate(args)
        case "update": return await handleUpdate(args)
        case "delete": return await handleDelete(args)
        case "activate": return await handleActivate(args)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    private func handleCreate(_ args: [String: Any]) async -> String {
        let nameReq = requireString(args, "name", expected: "non-empty display name", tool: name)
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
                    "call osaurus_agent({action: 'activate', id: '\(agent.id.uuidString)'}) to switch to it",
                ],
            ]
        )
    }

    private func handleUpdate(_ args: [String: Any]) async -> String {
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

        // Extract patch values into Sendable locals before the @MainActor hop;
        // capturing the raw `args` dictionary there trips the concurrency checker.
        let newName = args["name"] as? String
        let newDescription = args["description"] as? String
        let newSystemPrompt = args["system_prompt"] as? String
        let defaultModelProvided = args.keys.contains("default_model")
        let newDefaultModel = args["default_model"] as? String
        let newTemperature: Float? = {
            if let v = args["temperature"] as? Double { return Float(v) }
            if let v = args["temperature"] as? NSNumber { return v.floatValue }
            return nil
        }()
        let newMaxTokens = coerceInt(args["max_tokens"])

        return await MainActor.run {
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

            if let v = newName { agent.name = v }
            if let v = newDescription { agent.description = v }
            if let v = newSystemPrompt { agent.systemPrompt = v }
            if defaultModelProvided { agent.defaultModel = newDefaultModel }
            if let v = newTemperature { agent.temperature = v }
            if let v = newMaxTokens { agent.maxTokens = v }

            AgentManager.shared.update(agent)
            return ToolEnvelope.success(
                tool: name,
                result: ["agent_id": agent.id.uuidString, "status": "updated"]
            )
        }
    }

    private func handleDelete(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "UUID of an existing custom agent", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
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

    private func handleActivate(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "UUID of an existing agent", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
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
