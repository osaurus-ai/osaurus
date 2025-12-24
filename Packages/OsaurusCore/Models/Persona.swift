//
//  Persona.swift
//  osaurus
//
//  Defines a Persona - a customizable assistant configuration with its own
//  system prompt, tools, theme, and generation settings.
//

import Foundation

/// A customizable assistant persona for ChatView
public struct Persona: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for the persona
    public let id: UUID
    /// Display name of the persona
    public var name: String
    /// Brief description of what this persona does
    public var description: String
    /// System prompt prepended to all chat sessions with this persona
    public var systemPrompt: String
    /// Per-persona tool overrides. nil = use global config, otherwise map of tool name -> enabled
    public var enabledTools: [String: Bool]?
    /// Optional custom theme ID to apply when this persona is active
    public var themeId: UUID?
    /// Optional default model for this persona
    public var defaultModel: String?
    /// Optional temperature override
    public var temperature: Float?
    /// Optional max tokens override
    public var maxTokens: Int?
    /// Whether this is a built-in persona (cannot be deleted)
    public let isBuiltIn: Bool
    /// When the persona was created
    public let createdAt: Date
    /// When the persona was last modified
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        systemPrompt: String = "",
        enabledTools: [String: Bool]? = nil,
        themeId: UUID? = nil,
        defaultModel: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.enabledTools = enabledTools
        self.themeId = themeId
        self.defaultModel = defaultModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Built-in Personas

    /// Well-known UUID for the default Osaurus persona
    public static let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The default persona - uses global settings
    public static var `default`: Persona {
        Persona(
            id: defaultId,
            name: "Default",
            description: "Uses your global chat settings",
            systemPrompt: "",  // Uses global system prompt from settings
            enabledTools: nil,
            themeId: nil,
            defaultModel: nil,
            temperature: nil,
            maxTokens: nil,
            isBuiltIn: true,
            createdAt: Date.distantPast,
            updatedAt: Date.distantPast
        )
    }

    /// All built-in personas
    public static var builtInPersonas: [Persona] {
        [.default]
    }
}

// MARK: - Export/Import Support

extension Persona {
    /// Export format for sharing personas
    public struct ExportData: Codable {
        public let version: Int
        public let persona: Persona

        public init(persona: Persona) {
            self.version = 1
            // Create a copy without built-in flag for export
            let exportedPersona = persona
            // When exporting, we create a new instance that's not built-in
            self.persona = Persona(
                id: UUID(),  // Generate new ID on export
                name: exportedPersona.name,
                description: exportedPersona.description,
                systemPrompt: exportedPersona.systemPrompt,
                enabledTools: exportedPersona.enabledTools,
                themeId: nil,  // Don't export theme (may not exist on target system)
                defaultModel: exportedPersona.defaultModel,
                temperature: exportedPersona.temperature,
                maxTokens: exportedPersona.maxTokens,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        }
    }

    /// Export this persona to JSON data
    public func exportToJSON() throws -> Data {
        let exportData = ExportData(persona: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exportData)
    }

    /// Import a persona from JSON data
    /// Tools that don't exist in the current system will be filtered out
    @MainActor
    public static func importFromJSON(_ data: Data) throws -> Persona {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportData = try decoder.decode(ExportData.self, from: data)
        var imported = exportData.persona

        // Filter out tools that don't exist in the current registry
        if let tools = imported.enabledTools {
            let availableToolNames = Set(ToolRegistry.shared.listTools().map { $0.name })
            let filteredTools = tools.filter { availableToolNames.contains($0.key) }
            imported.enabledTools = filteredTools.isEmpty ? nil : filteredTools
        }

        return imported
    }
}
