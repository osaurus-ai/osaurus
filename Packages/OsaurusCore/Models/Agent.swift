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
    /// Per-agent tool overrides. nil = use global config, otherwise map of tool name -> enabled
    public var enabledTools: [String: Bool]?
    /// Per-agent skill overrides. nil = use global config, otherwise map of skill name -> enabled
    public var enabledSkills: [String: Bool]?
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

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        systemPrompt: String = "",
        enabledTools: [String: Bool]? = nil,
        enabledSkills: [String: Bool]? = nil,
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
        agentAddress: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.enabledTools = enabledTools
        self.enabledSkills = enabledSkills
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
            systemPrompt: "",  // Uses global system prompt from settings
            enabledTools: nil,
            enabledSkills: nil,
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
                enabledTools: exportedAgent.enabledTools,
                enabledSkills: exportedAgent.enabledSkills,
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
                agentAddress: nil
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
    /// Tools and skills that don't exist in the current system will be filtered out
    @MainActor
    public static func importFromJSON(_ data: Data) throws -> Agent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportData = try decoder.decode(ExportData.self, from: data)
        var imported = exportData.agent

        // Filter out tools that don't exist in the current registry
        if let tools = imported.enabledTools {
            let availableToolNames = Set(ToolRegistry.shared.listTools().map { $0.name })
            let filteredTools = tools.filter { availableToolNames.contains($0.key) }
            imported.enabledTools = filteredTools.isEmpty ? nil : filteredTools
        }

        // Filter out skills that don't exist in the current manager
        if let skills = imported.enabledSkills {
            let availableSkillNames = Set(SkillManager.shared.skills.map { $0.name })
            let filteredSkills = skills.filter { availableSkillNames.contains($0.key) }
            imported.enabledSkills = filteredSkills.isEmpty ? nil : filteredSkills
        }

        return imported
    }
}
