//
//  Agent.swift
//  osaurus
//
//  Defines an Agent - a customizable assistant configuration with its own
//  system prompt, tools, theme, and generation settings.
//

import Foundation

/// A quick action prompt template shown in the empty state
public struct AgentQuickAction: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var icon: String
    public var text: String
    public var prompt: String

    public init(id: UUID = UUID(), icon: String, text: String, prompt: String) {
        self.id = id
        self.icon = icon
        self.text = text
        self.prompt = prompt
    }

    /// Built-in chat quick actions. Localized at access time (Option A):
    /// defaults only appear in the UI as a read-only fallback when an agent
    /// has `chatQuickActions == nil`; they are never persisted unless the
    /// user explicitly customizes them. A new UUID is generated on each
    /// access, matching the previous `static let` semantics for consumers.
    public static var defaultChatQuickActions: [AgentQuickAction] {
        [
            AgentQuickAction(icon: "lightbulb", text: L("Explain a concept"), prompt: L("Explain ")),
            AgentQuickAction(icon: "doc.text", text: L("Summarize text"), prompt: L("Summarize the following: ")),
            AgentQuickAction(
                icon: "chevron.left.forwardslash.chevron.right",
                text: L("Write code"),
                prompt: L("Write code that ")
            ),
            AgentQuickAction(icon: "pencil.line", text: L("Help me write"), prompt: L("Help me write ")),
        ]
    }

    public static var defaultWorkQuickActions: [AgentQuickAction] {
        [
            AgentQuickAction(icon: "globe", text: L("Build a site"), prompt: L("Build a landing page for ")),
            AgentQuickAction(icon: "magnifyingglass", text: L("Research a topic"), prompt: L("Research ")),
            AgentQuickAction(icon: "doc.text", text: L("Write a blog post"), prompt: L("Write a blog post about ")),
            AgentQuickAction(icon: "folder", text: L("Organize my files"), prompt: L("Help me organize ")),
        ]
    }
}

/// Controls whether tools are selected automatically via RAG or manually by the user
public enum ToolSelectionMode: String, Codable, Sendable {
    case auto
    case manual
}

/// A customizable assistant agent for ChatView
public struct Agent: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for the agent
    public let id: UUID
    /// Display name of the agent
    public var name: String
    /// Brief description of what this agent does
    public var description: String
    /// System prompt prepended to all chat sessions with this agent
    public var systemPrompt: String
    /// Optional custom theme ID to apply when this agent is active
    public var themeId: UUID?
    /// Optional default model for this agent
    public var defaultModel: String?
    /// Optional temperature override
    public var temperature: Float?
    /// Optional max tokens override
    public var maxTokens: Int?
    /// Per-agent chat quick actions. nil = use defaults, empty = hidden, non-empty = custom list
    public var chatQuickActions: [AgentQuickAction]?
    /// Per-agent work quick actions. nil = use defaults, empty = hidden, non-empty = custom list
    public var workQuickActions: [AgentQuickAction]?
    /// Whether this is a built-in agent (cannot be deleted)
    public let isBuiltIn: Bool
    /// When the agent was created
    public let createdAt: Date
    /// When the agent was last modified
    public var updatedAt: Date
    /// Derivation index for the agent's cryptographic identity (nil = no address yet)
    public var agentIndex: UInt32?
    /// Derived cryptographic address for this agent (nil = no address yet)
    public var agentAddress: String?
    /// Controls the agent's ability to run arbitrary commands in the sandbox
    public var autonomousExec: AutonomousExecConfig?
    /// Per-agent plugin instruction overrides keyed by plugin ID
    public var pluginInstructions: [String: String]?
    /// Whether this agent is advertised via Bonjour on the local network
    public var bonjourEnabled: Bool
    /// Controls whether tools are selected automatically (RAG preflight) or manually by the user
    public var toolSelectionMode: ToolSelectionMode?
    /// Tool names explicitly selected by the user when toolSelectionMode is .manual
    public var manualToolNames: [String]?
    /// Skill names explicitly selected by the user when toolSelectionMode is .manual
    public var manualSkillNames: [String]?
    /// When true, no tools or preflight context are sent for this agent
    public var disableTools: Bool?
    /// When true, memory is neither injected into prompts nor recorded for this agent
    public var disableMemory: Bool?

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        systemPrompt: String = "",
        themeId: UUID? = nil,
        defaultModel: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        chatQuickActions: [AgentQuickAction]? = nil,
        workQuickActions: [AgentQuickAction]? = nil,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        agentIndex: UInt32? = nil,
        agentAddress: String? = nil,
        autonomousExec: AutonomousExecConfig? = nil,
        pluginInstructions: [String: String]? = nil,
        bonjourEnabled: Bool = false,
        toolSelectionMode: ToolSelectionMode? = nil,
        manualToolNames: [String]? = nil,
        manualSkillNames: [String]? = nil,
        disableTools: Bool? = nil,
        disableMemory: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.themeId = themeId
        self.defaultModel = defaultModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.chatQuickActions = chatQuickActions
        self.workQuickActions = workQuickActions
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.agentIndex = agentIndex
        self.agentAddress = agentAddress
        self.autonomousExec = autonomousExec
        self.pluginInstructions = pluginInstructions
        self.bonjourEnabled = bonjourEnabled
        self.toolSelectionMode = toolSelectionMode
        self.manualToolNames = manualToolNames
        self.manualSkillNames = manualSkillNames
        self.disableTools = disableTools
        self.disableMemory = disableMemory
    }

    // MARK: - Localized Display Helpers

    /// Display name for UI rendering. Built-in agents (currently only the
    /// Default agent) resolve their English `name` through the localization
    /// catalog so the sidebar, pickers, menus, etc. render in the user's
    /// language. User-created agents always render their stored name verbatim.
    public var displayName: String {
        isBuiltIn ? L(String.LocalizationValue(name)) : name
    }

    /// Display description for UI rendering. Same rules as `displayName`.
    public var displayDescription: String {
        guard isBuiltIn, !description.isEmpty else { return description }
        return L(String.LocalizationValue(description))
    }

    // MARK: - Built-in Agents

    /// Well-known UUID for the default Osaurus agent
    public static let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Check whether an agent ID string refers to the default (built-in) agent.
    /// The default agent operates in read-only memory mode.
    public static func isDefaultAgentId(_ id: String) -> Bool {
        id == defaultId.uuidString
    }

    /// The default agent - uses global settings
    public static var `default`: Agent {
        Agent(
            id: defaultId,
            name: "Default",
            description: "Uses your global chat settings",
            systemPrompt: "",
            themeId: nil,
            defaultModel: nil,
            temperature: nil,
            maxTokens: nil,
            isBuiltIn: true,
            createdAt: Date.distantPast,
            updatedAt: Date.distantPast
        )
    }

    /// All built-in agents
    public static var builtInAgents: [Agent] {
        [.default]
    }
}

// MARK: - Decodable Migration

extension Agent {
    /// Custom decoder that provides default values for fields added after the initial release,
    /// ensuring older persisted JSON files remain loadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        themeId = try c.decodeIfPresent(UUID.self, forKey: .themeId)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        chatQuickActions = try c.decodeIfPresent([AgentQuickAction].self, forKey: .chatQuickActions)
        workQuickActions = try c.decodeIfPresent([AgentQuickAction].self, forKey: .workQuickActions)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        agentIndex = try c.decodeIfPresent(UInt32.self, forKey: .agentIndex)
        agentAddress = try c.decodeIfPresent(String.self, forKey: .agentAddress)
        autonomousExec = try c.decodeIfPresent(AutonomousExecConfig.self, forKey: .autonomousExec)
        pluginInstructions = try c.decodeIfPresent([String: String].self, forKey: .pluginInstructions)
        bonjourEnabled = try c.decodeIfPresent(Bool.self, forKey: .bonjourEnabled) ?? false
        toolSelectionMode = try c.decodeIfPresent(ToolSelectionMode.self, forKey: .toolSelectionMode)
        manualToolNames = try c.decodeIfPresent([String].self, forKey: .manualToolNames)
        manualSkillNames = try c.decodeIfPresent([String].self, forKey: .manualSkillNames)
        disableTools = try c.decodeIfPresent(Bool.self, forKey: .disableTools)
        disableMemory = try c.decodeIfPresent(Bool.self, forKey: .disableMemory)
    }
}

// MARK: - Autonomous Exec Configuration

public struct AutonomousExecConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var maxCommandsPerTurn: Int
    public var commandTimeout: Int
    public var pluginCreate: Bool

    public static let `default` = AutonomousExecConfig(
        enabled: false,
        maxCommandsPerTurn: 10,
        commandTimeout: 30,
        pluginCreate: true
    )

    public init(
        enabled: Bool = false,
        maxCommandsPerTurn: Int = 10,
        commandTimeout: Int = 30,
        pluginCreate: Bool = true
    ) {
        self.enabled = enabled
        self.maxCommandsPerTurn = maxCommandsPerTurn
        self.commandTimeout = commandTimeout
        self.pluginCreate = pluginCreate
    }
}

// MARK: - Export/Import Support

extension Agent {
    /// Export format for sharing agents
    public struct ExportData: Codable {
        public let version: Int
        public let agent: Agent

        enum CodingKeys: String, CodingKey {
            case version
            case agent = "persona"
        }

        public init(agent: Agent) {
            self.version = 1
            let exportedAgent = agent
            self.agent = Agent(
                id: UUID(),
                name: exportedAgent.name,
                description: exportedAgent.description,
                systemPrompt: exportedAgent.systemPrompt,
                themeId: nil,
                defaultModel: exportedAgent.defaultModel,
                temperature: exportedAgent.temperature,
                maxTokens: exportedAgent.maxTokens,
                chatQuickActions: exportedAgent.chatQuickActions,
                workQuickActions: exportedAgent.workQuickActions,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date(),
                agentIndex: nil,
                agentAddress: nil,
                autonomousExec: exportedAgent.autonomousExec,
                toolSelectionMode: exportedAgent.toolSelectionMode,
                manualToolNames: exportedAgent.manualToolNames,
                manualSkillNames: exportedAgent.manualSkillNames,
                disableTools: exportedAgent.disableTools,
                disableMemory: exportedAgent.disableMemory
            )
        }
    }

    /// Export this agent to JSON data
    public func exportToJSON() throws -> Data {
        let exportData = ExportData(agent: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exportData)
    }

    /// Import an agent from JSON data
    @MainActor
    public static func importFromJSON(_ data: Data) throws -> Agent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportData = try decoder.decode(ExportData.self, from: data)
        return exportData.agent
    }
}
