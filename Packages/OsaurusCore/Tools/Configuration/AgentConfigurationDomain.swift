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
//  The default agent itself is *not* mutable through THIS tool —
//  create/update/delete refuse every `id == Agent.defaultId` and every
//  `agent.isBuiltIn == true` (activate back to the Default agent is
//  allowed). The default agent's persona/model/temperature are edited in
//  Settings → Chat or via `osaurus_settings` (scope `default_agent`).
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

    /// Capability toggles as the tool-facing payload — shared by
    /// `osaurus_describe` (agents scope) and `osaurus_agent` update, so a
    /// model that patched `capabilities` can verify the effective state from
    /// the result without a follow-up read.
    static func capabilitiesPayload(for agent: Agent) -> [String: Any] {
        [
            "tools_enabled": agent.toolsEnabled,
            "memory_enabled": agent.memoryEnabled,
            "search_memory_enabled": agent.settings.searchMemoryEnabled,
            "web_search_enabled": agent.settings.webSearchEnabled,
            "knowledge_enabled": agent.settings.knowledgeEnabled,
            "knowledge_collection_ids": agent.settings.knowledgeCollectionIds
                .map { $0.uuidString },
            "db_enabled": agent.settings.dbEnabled,
            "self_scheduling_enabled": agent.settings.selfSchedulingEnabled,
            "computer_use_enabled": agent.settings.computerUseEnabled,
            "browser_use_enabled": agent.settings.browserUseEnabled,
            "speak_enabled": agent.settings.speakEnabled,
            "render_chart_enabled": agent.settings.renderChartEnabled,
            "theme_id": agent.themeId?.uuidString ?? "",
        ]
    }
}

// MARK: - osaurus_agent

public final class OsaurusAgentTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_agent"
    // The first sentence must stay ≤180 chars and carry the routing-critical
    // affordances: the Default agent's compact bootstrap schema keeps only
    // that sentence (see SystemPromptComposer.oneLineToolDescription).
    public let description =
        "Manage custom agents — create, delete, activate, or update: patch fields or use "
        + "`capabilities` to toggle features like web search, knowledge, db, computer use, and "
        + "browser use. `action`: create (needs `name`; optional `description`, "
        + "`system_prompt`, `default_model`, `temperature` 0..2, `max_tokens`), update (needs `id`; other "
        + "fields patch, including `capabilities`), delete (needs `id`), activate (needs `id`; switching "
        + "back to the Default agent is allowed). The Default agent is edited via osaurus_settings "
        + "(scope default_agent), not here. Feature toggles (tools, memory, web search, knowledge, "
        + "database, self-scheduling, computer use, browser use, speech, charts, theme) are patched via "
        + "the `capabilities` object — e.g. enable browser use: {action: 'update', id: …, capabilities: "
        + "{browser_use_enabled: true}}. Knowledge tools need both knowledge_enabled: true AND granted "
        + "knowledge_collection_ids. Autonomy ceilings, delegation/spawn budgets, and permission modes "
        + "stay UI-only (Settings → Agents)."
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
            "capabilities": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "description": .string(
                    "Per-agent capability toggles (update only). Only the provided keys change."
                ),
                "properties": .object([
                    "tools_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether the agent may use tools at all."),
                    ]),
                    "memory_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Inject distilled memory context into the agent's turns."),
                    ]),
                    "search_memory_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Expose the search_memory recall tool."),
                    ]),
                    "web_search_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Expose web search tools."),
                    ]),
                    "knowledge_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Expose knowledge tools (also needs collection grants)."),
                    ]),
                    "knowledge_collection_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Knowledge collection UUIDs this agent may search/read (replaces the "
                                + "grant list). Find ids via osaurus_list({scope: 'knowledge'})."
                        ),
                    ]),
                    "db_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Give the agent its own private database (db_* tools)."),
                    ]),
                    "self_scheduling_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Let the agent schedule its own next wake-up."),
                    ]),
                    "computer_use_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Allow screen control (computer use)."),
                    ]),
                    "browser_use_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Allow browser automation (browser use)."),
                    ]),
                    "speak_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Let the agent speak replies aloud (TTS)."),
                    ]),
                    "render_chart_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Allow rendering charts in chat."),
                    ]),
                    "theme_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Theme UUID to apply when this agent is active (null clears it). "
                                + "Find ids via osaurus_list({scope: 'themes'})."
                        ),
                    ]),
                ]),
            ]),
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

        // Capabilities patch — validated into Sendable locals pre-hop.
        var capabilityBools: [String: Bool] = [:]
        var newKnowledgeCollectionIds: [UUID]?
        var themeIdProvided = false
        var newThemeId: UUID?
        if let caps = args["capabilities"] as? [String: Any] {
            let boolKeys: Set<String> = [
                "tools_enabled", "memory_enabled", "search_memory_enabled",
                "web_search_enabled", "knowledge_enabled", "db_enabled",
                "self_scheduling_enabled", "computer_use_enabled",
                "browser_use_enabled", "speak_enabled", "render_chart_enabled",
            ]
            for (key, value) in caps {
                if boolKeys.contains(key) {
                    guard let b = coerceBool(value) else {
                        return ToolEnvelope.failure(
                            kind: .invalidArgs,
                            message: "`capabilities.\(key)` must be a boolean.",
                            field: key,
                            tool: name
                        )
                    }
                    capabilityBools[key] = b
                } else if key == "knowledge_collection_ids" {
                    guard let raw = value as? [Any] else {
                        return ToolEnvelope.failure(
                            kind: .invalidArgs,
                            message: "`capabilities.knowledge_collection_ids` must be an array of UUID strings.",
                            field: key,
                            tool: name
                        )
                    }
                    let ids = raw.compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }
                    guard ids.count == raw.count else {
                        return ToolEnvelope.failure(
                            kind: .invalidArgs,
                            message:
                                "`capabilities.knowledge_collection_ids` must contain only UUID strings. "
                                + "Find collection ids via osaurus_list({scope: 'knowledge'}).",
                            field: key,
                            tool: name
                        )
                    }
                    newKnowledgeCollectionIds = ids
                } else if key == "theme_id" {
                    themeIdProvided = true
                    if value is NSNull {
                        newThemeId = nil
                    } else if let s = value as? String, let uuid = UUID(uuidString: s) {
                        newThemeId = uuid
                    } else {
                        return ToolEnvelope.failure(
                            kind: .invalidArgs,
                            message:
                                "`capabilities.theme_id` must be a theme UUID or null to clear. "
                                + "Find theme ids via osaurus_list({scope: 'themes'}).",
                            field: key,
                            tool: name
                        )
                    }
                } else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message:
                            "Unknown capability `\(key)`. Supported: \(boolKeys.sorted().joined(separator: ", ")), "
                            + "knowledge_collection_ids, theme_id. Autonomy ceilings, delegation/spawn, and "
                            + "permission modes are edited in Settings → Agents only.",
                        field: "capabilities",
                        tool: name
                    )
                }
            }
        }

        // Grant validation runs off the main actor (blocking disk I/O).
        if let ids = newKnowledgeCollectionIds, !ids.isEmpty {
            let known = Set(await KnowledgeCollectionStore.loadAllAsync().map { $0.id })
            let unknown = ids.filter { !known.contains($0) }
            if !unknown.isEmpty {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Unknown knowledge collection id(s): "
                        + "\(unknown.map { $0.uuidString }.joined(separator: ", ")). "
                        + "Find collections via osaurus_list({scope: 'knowledge'}).",
                    field: "knowledge_collection_ids",
                    tool: name
                )
            }
        }

        let capabilityBoolsFinal = capabilityBools
        let knowledgeIdsFinal = newKnowledgeCollectionIds
        let themeIdProvidedFinal = themeIdProvided
        let newThemeIdFinal = newThemeId

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
                    message:
                        "Default and built-in agents are not editable here. Use "
                        + "osaurus_settings({action: 'set', scope: 'default_agent', …}) for the "
                        + "Default agent's model/persona/temperature.",
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

            if themeIdProvidedFinal {
                if let themeId = newThemeIdFinal,
                    !ThemeConfigurationStore.listThemes().contains(where: { $0.metadata.id == themeId })
                {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message:
                            "No theme found with id \(themeId.uuidString). "
                            + "Find theme ids via osaurus_list({scope: 'themes'}).",
                        field: "theme_id",
                        tool: name
                    )
                }
                agent.themeId = newThemeIdFinal
            }

            for (key, value) in capabilityBoolsFinal {
                switch key {
                case "tools_enabled": agent.toolsEnabled = value
                case "memory_enabled": agent.memoryEnabled = value
                case "search_memory_enabled": agent.settings.searchMemoryEnabled = value
                case "web_search_enabled": agent.settings.webSearchEnabled = value
                case "knowledge_enabled": agent.settings.knowledgeEnabled = value
                case "db_enabled": agent.settings.dbEnabled = value
                case "self_scheduling_enabled": agent.settings.selfSchedulingEnabled = value
                case "computer_use_enabled": agent.settings.computerUseEnabled = value
                case "browser_use_enabled": agent.settings.browserUseEnabled = value
                case "speak_enabled": agent.settings.speakEnabled = value
                case "render_chart_enabled": agent.settings.renderChartEnabled = value
                default: break  // unreachable — keys validated above
                }
            }
            if let ids = knowledgeIdsFinal {
                agent.settings.knowledgeCollectionIds = ids
            }

            AgentManager.shared.update(agent)

            // Echo the effective capabilities so the model can verify a
            // requested feature toggle actually changed (the compact
            // bootstrap schema hides per-key prose, so a model that missed
            // the `capabilities` object recovers from this result).
            var result: [String: Any] = [
                "agent_id": agent.id.uuidString,
                "status": "updated",
                "capabilities": AgentConfigurationDomain.capabilitiesPayload(for: agent),
            ]
            if agent.settings.knowledgeEnabled && agent.settings.knowledgeCollectionIds.isEmpty {
                result["note"] =
                    "knowledge_enabled is on but no collections are granted — knowledge tools stay "
                    + "hidden until knowledge_collection_ids is set."
            }
            return ToolEnvelope.success(tool: name, result: result)
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
