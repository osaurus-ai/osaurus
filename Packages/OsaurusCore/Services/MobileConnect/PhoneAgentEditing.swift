//
//  PhoneAgentEditing.swift
//  osaurus
//
//  The agent settings a paired phone can read and change
//  (docs/MOBILE_PROTOCOL.md §13.2–§13.4, §14.11): name, description and
//  prompt; the Tools, Memory, Web Search and Autonomous Execution switches;
//  temperature and max tokens; deleting the agent; and which of its plugin
//  and MCP tools it may use, with the Tools window's three presets.
//
//  Custom agents only. The Orchestrator's settings live in the Mac's
//  Orchestrator settings, and a built-in agent can't be deleted.
//
//  Every change goes through the same AgentManager calls the Mac's own
//  editor makes, so the Mac's rules (and the sandbox booting when
//  Autonomous Execution turns on) apply to the phone's edits too.
//

import Foundation

// Not main-actor as a whole: its value types are encoded and decoded off it.
enum PhoneAgentEditing {

    /// What `GET /agents/{id}` carries for the phone to show and change.
    struct Settings: Codable, Equatable {
        let tools_enabled: Bool
        let memory_enabled: Bool
        let web_search_enabled: Bool
        let autonomous_exec_enabled: Bool
        /// False where this Mac can't run the sandbox: the switch can't
        /// turn on.
        let autonomous_exec_available: Bool
        /// Nil uses the model's own default.
        let temperature: Float?
        let max_tokens: Int?
    }

    enum EditError: Error, Equatable {
        /// Unknown, or built-in (the Orchestrator).
        case notEditable
        case badRequest(String)
        case sandboxUnavailable
        /// Shared to a workspace: teammates would keep a row nobody can reach.
        case sharedInWorkspace
        /// The agent the phone's Secure Channel (and relay tunnel) runs
        /// through: deleting it would cut the phone off.
        case connectionAgent

        /// `(status, error code, message)` for the reply.
        var reply: (status: Int, code: String, message: String) {
            switch self {
            case .notEditable:
                return (403, "agent_not_editable", "Only your own agents can be changed from the phone.")
            case .badRequest(let message):
                return (400, "bad_request", message)
            case .sandboxUnavailable:
                return (409, "sandbox_unavailable", "This Mac can't run the sandbox.")
            case .sharedInWorkspace:
                return (409, "agent_shared", "Unshare this agent from its workspace on your Mac before deleting it.")
            case .connectionAgent:
                return (
                    409,
                    "agent_in_use",
                    "Your phone is connected to your Mac through this agent. Delete it on your Mac instead."
                )
            }
        }
    }

    /// A value to set, or `.clear` to go back to the model's default (JSON
    /// `null`). A field the body leaves out is not touched.
    enum Field<Value: Equatable>: Equatable {
        case set(Value)
        case clear
    }

    struct Patch: Equatable {
        var name: String?
        var description: String?
        var systemPrompt: String?
        var toolsEnabled: Bool?
        var memoryEnabled: Bool?
        var webSearchEnabled: Bool?
        var autonomousExecEnabled: Bool?
        var temperature: Field<Float>?
        var maxTokens: Field<Int>?

        var isEmpty: Bool { self == Patch() }
    }

    static let temperatureRange: ClosedRange<Float> = 0...2
    static let maxTokensRange: ClosedRange<Int> = 1...1_000_000

    // MARK: Reading

    /// Nil for a built-in agent, whose settings the phone doesn't edit.
    @MainActor
    static func settings(for agent: Agent) -> Settings? {
        guard !agent.isBuiltIn else { return nil }
        let manager = AgentManager.shared
        return Settings(
            tools_enabled: agent.toolsEnabled,
            memory_enabled: agent.memoryEnabled,
            web_search_enabled: agent.settings.webSearchEnabled,
            autonomous_exec_enabled: manager.effectiveAutonomousExec(for: agent.id)?.enabled ?? false,
            autonomous_exec_available: SandboxManager.State.shared.availability.isAvailable,
            temperature: agent.temperature,
            max_tokens: agent.maxTokens
        )
    }

    // MARK: Editing

    /// Parses a `PATCH /agents/{id}` body. Fields left out are untouched;
    /// `temperature` / `max_tokens` set to `null` go back to the default.
    static func patch(from data: Data) throws -> Patch {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw EditError.badRequest("Expected a JSON object")
        }
        var patch = Patch()
        func string(_ key: String) throws -> String? {
            guard let value = object[key] else { return nil }
            guard let text = value as? String else { throw EditError.badRequest("\(key) must be a string") }
            return text
        }
        func bool(_ key: String) throws -> Bool? {
            guard let value = object[key] else { return nil }
            // NSNumber bridges both numbers and booleans: only a real boolean.
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw EditError.badRequest("\(key) must be true or false")
            }
            return number.boolValue
        }
        patch.name = try string("name")
        patch.description = try string("description")
        patch.systemPrompt = try string("system_prompt")
        patch.toolsEnabled = try bool("tools_enabled")
        patch.memoryEnabled = try bool("memory_enabled")
        patch.webSearchEnabled = try bool("web_search_enabled")
        patch.autonomousExecEnabled = try bool("autonomous_exec_enabled")
        if let value = object["temperature"] {
            if value is NSNull {
                patch.temperature = .clear
            } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                temperatureRange.contains(number.floatValue)
            {
                patch.temperature = .set(number.floatValue)
            } else {
                throw EditError.badRequest("temperature must be null or between 0 and 2")
            }
        }
        if let value = object["max_tokens"] {
            if value is NSNull {
                patch.maxTokens = .clear
            } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                maxTokensRange.contains(number.intValue), Double(number.intValue) == number.doubleValue
            {
                patch.maxTokens = .set(number.intValue)
            } else {
                throw EditError.badRequest("max_tokens must be null or a whole number from 1 to 1,000,000")
            }
        }
        guard !patch.isEmpty else { throw EditError.badRequest("Nothing to change") }
        return patch
    }

    /// Applies `patch` to a custom agent as the Mac's editor would.
    @MainActor
    static func apply(_ patch: Patch, to agentId: UUID) async throws {
        let manager = AgentManager.shared
        guard var agent = manager.agent(for: agentId), !agent.isBuiltIn else { throw EditError.notEditable }
        if patch.autonomousExecEnabled == true, !SandboxManager.State.shared.availability.isAvailable {
            throw EditError.sandboxUnavailable
        }
        if let name = patch.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw EditError.badRequest("name must not be empty") }
            agent.name = String(trimmed.prefix(80))
        }
        if let description = patch.description {
            agent.description = AgentDescriptionPolicy.normalized(description)
        }
        if let prompt = patch.systemPrompt { agent.systemPrompt = prompt }
        if let tools = patch.toolsEnabled { agent.toolsEnabled = tools }
        if let memory = patch.memoryEnabled { agent.memoryEnabled = memory }
        if let webSearch = patch.webSearchEnabled { agent.settings.webSearchEnabled = webSearch }
        switch patch.temperature {
        case .set(let value): agent.temperature = value
        case .clear: agent.temperature = nil
        case nil: break
        }
        switch patch.maxTokens {
        case .set(let value): agent.maxTokens = value
        case .clear: agent.maxTokens = nil
        case nil: break
        }
        manager.update(agent)
        // Last, through the call that also boots the sandbox when it turns on:
        // started, not waited for, as a cold boot outlives the request.
        if let enabled = patch.autonomousExecEnabled {
            var config = manager.effectiveAutonomousExec(for: agentId) ?? .default
            if config.enabled != enabled {
                config.enabled = enabled
                try await manager.updateAutonomousExec(config, for: agentId, waitForSandbox: false)
            }
        }
    }

    /// Deletes a custom agent as the Mac's Delete Agent does, refusing one
    /// still shared to a workspace as the Mac does, and the one the phone
    /// is connected through (`connectedThrough`, its Secure Channel's
    /// address): with it gone the phone has no channel or relay tunnel left
    /// to reach the Mac by. False when the delete itself fails.
    @MainActor
    static func delete(_ agentId: UUID, connectedThrough: String? = nil) async throws -> Bool {
        guard let agent = AgentManager.shared.agent(for: agentId), !agent.isBuiltIn else {
            throw EditError.notEditable
        }
        if let connectedThrough, agent.agentAddress?.lowercased() == connectedThrough.lowercased() {
            throw EditError.connectionAgent
        }
        if let address = agent.agentAddress,
            !WorkspaceRosterStore.shared.workspacesSharing(agentAddress: address).isEmpty
        {
            throw EditError.sharedInWorkspace
        }
        return await AgentManager.shared.delete(id: agentId).deleted
    }

    // MARK: Tools

    /// The Tools window's presets. Built-in tools can't be picked one by
    /// one: they follow the agent's own switches while Tools is on.
    enum ToolPreset: String {
        /// Every plugin and MCP tool on.
        case all
        /// Only the built-in tools: every plugin and MCP tool off.
        case essential
        /// Nothing: the agent's Tools switch off.
        case none
    }

    /// Built-in and runtime-managed tools: always loaded, not chosen per
    /// agent.
    @MainActor
    static func isBuiltInTool(_ name: String) -> Bool {
        let registry = ToolRegistry.shared
        return registry.builtInToolNames.contains(name) || registry.runtimeManagedToolNames.contains(name)
    }

    /// Whether the agent has the tool on. Built-ins follow its switches, so
    /// they count as on; a plugin or MCP tool is on unless the agent's own
    /// list leaves it out (no list yet means every tool, as on the Mac).
    @MainActor
    static func agentHasTool(_ name: String, agent: Agent) -> Bool {
        if isBuiltInTool(name) { return true }
        guard let allowed = AgentManager.shared.effectiveEnabledToolNames(for: agent.id) else { return true }
        return allowed.contains(name)
    }

    /// Turns one plugin or MCP tool on or off for the agent alone.
    @MainActor
    static func setTool(_ name: String, enabled: Bool, for agentId: UUID) throws {
        let manager = AgentManager.shared
        guard let agent = manager.agent(for: agentId), !agent.isBuiltIn else { throw EditError.notEditable }
        guard !isBuiltInTool(name) else {
            throw EditError.badRequest("Built-in tools follow the agent's own switches")
        }
        seedToolListIfNeeded(for: agentId)
        var names = Set(manager.effectiveEnabledToolNames(for: agentId) ?? [])
        if enabled { names.insert(name) } else { names.remove(name) }
        manager.updateEnabledToolNames(names.sorted(), for: agentId)
    }

    @MainActor
    static func apply(_ preset: ToolPreset, to agentId: UUID) throws {
        let manager = AgentManager.shared
        guard var agent = manager.agent(for: agentId), !agent.isBuiltIn else { throw EditError.notEditable }
        switch preset {
        case .all, .essential:
            if !agent.toolsEnabled {
                agent.toolsEnabled = true
                manager.update(agent)
            }
            let names = preset == .all ? ToolRegistry.shared.listDynamicTools().map(\.name) : []
            manager.updateEnabledToolNames(names, for: agentId)
        case .none:
            // The agent's own list stays, so turning Tools back on restores it.
            agent.toolsEnabled = false
            manager.update(agent)
        }
    }

    /// The agent's list starts as every tool the Mac has, the first time one
    /// is turned off, as the Mac's own picker seeds it.
    @MainActor
    private static func seedToolListIfNeeded(for agentId: UUID) {
        let names = ToolRegistry.shared.listDynamicTools().map(\.name)
        guard !names.isEmpty else { return }
        AgentManager.shared.seedEnabledCapabilitiesIfNeeded(for: agentId, defaultToolNames: names)
    }
}
