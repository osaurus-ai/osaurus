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

    public static let defaultChatQuickActions: [AgentQuickAction] = [
        AgentQuickAction(icon: "lightbulb", text: "Explain a concept", prompt: "Explain "),
        AgentQuickAction(icon: "doc.text", text: "Summarize text", prompt: "Summarize the following: "),
        AgentQuickAction(
            icon: "chevron.left.forwardslash.chevron.right",
            text: "Write code",
            prompt: "Write code that "
        ),
        AgentQuickAction(icon: "pencil.line", text: "Help me write", prompt: "Help me write "),
    ]

    public static let defaultWorkQuickActions: [AgentQuickAction] = [
        AgentQuickAction(icon: "globe", text: "Build a site", prompt: "Build a landing page for "),
        AgentQuickAction(icon: "magnifyingglass", text: "Research a topic", prompt: "Research "),
        AgentQuickAction(icon: "doc.text", text: "Write a blog post", prompt: "Write a blog post about "),
        AgentQuickAction(icon: "folder", text: "Organize my files", prompt: "Help me organize "),
    ]
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
    /// Sandbox plugin IDs assigned to this agent
    public var sandboxPlugins: [String]?
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
        sandboxPlugins: [String]? = nil,
        autonomousExec: AutonomousExecConfig? = nil,
        pluginInstructions: [String: String]? = nil,
        bonjourEnabled: Bool = false,
        toolSelectionMode: ToolSelectionMode? = nil,
        manualToolNames: [String]? = nil,
        manualSkillNames: [String]? = nil
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
        self.sandboxPlugins = sandboxPlugins
        self.autonomousExec = autonomousExec
        self.pluginInstructions = pluginInstructions
        self.bonjourEnabled = bonjourEnabled
        self.toolSelectionMode = toolSelectionMode
        self.manualToolNames = manualToolNames
        self.manualSkillNames = manualSkillNames
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
        sandboxPlugins = try c.decodeIfPresent([String].self, forKey: .sandboxPlugins)
        autonomousExec = try c.decodeIfPresent(AutonomousExecConfig.self, forKey: .autonomousExec)
        pluginInstructions = try c.decodeIfPresent([String: String].self, forKey: .pluginInstructions)
        bonjourEnabled = try c.decodeIfPresent(Bool.self, forKey: .bonjourEnabled) ?? false
        toolSelectionMode = try c.decodeIfPresent(ToolSelectionMode.self, forKey: .toolSelectionMode)
        manualToolNames = try c.decodeIfPresent([String].self, forKey: .manualToolNames)
        manualSkillNames = try c.decodeIfPresent([String].self, forKey: .manualSkillNames)
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
                sandboxPlugins: exportedAgent.sandboxPlugins,
                autonomousExec: exportedAgent.autonomousExec,
                toolSelectionMode: exportedAgent.toolSelectionMode,
                manualToolNames: exportedAgent.manualToolNames,
                manualSkillNames: exportedAgent.manualSkillNames
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
