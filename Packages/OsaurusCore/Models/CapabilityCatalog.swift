//
//  CapabilityCatalog.swift
//  osaurus
//
//  Unified catalog combining tools and skills metadata for two-phase capability selection.
//

import Foundation

/// Type of capability in the catalog
public enum CapabilityType: String, Codable, Sendable {
    case tool
    case skill
}

/// Metadata entry for a capability (tool or skill)
public struct CapabilityEntry: Codable, Sendable, Identifiable {
    /// Unique identifier combining type and name
    public var id: String { "\(type.rawValue):\(name)" }

    public let type: CapabilityType
    public let name: String
    public let description: String
    public let category: String?

    public init(
        type: CapabilityType,
        name: String,
        description: String,
        category: String? = nil
    ) {
        self.type = type
        self.name = name
        self.description = description
        self.category = category
    }
}

/// Unified catalog of tools and skills for selection phase
public struct CapabilityCatalog: Sendable {
    public let tools: [CapabilityEntry]
    public let skills: [CapabilityEntry]

    public init(tools: [CapabilityEntry], skills: [CapabilityEntry]) {
        self.tools = tools
        self.skills = skills
    }

    /// Total number of capabilities
    public var totalCount: Int {
        tools.count + skills.count
    }

    /// Check if catalog is empty
    public var isEmpty: Bool {
        tools.isEmpty && skills.isEmpty
    }

    /// Generate catalog text for system prompt injection
    public func asSystemPromptSection() -> String {
        guard !isEmpty else {
            return ""
        }

        var sections: [String] = []
        sections.append("# Available Capabilities")
        sections.append("")
        sections.append(
            "You have access to tools and skills. For tasks requiring tools or specialized guidance, call `select_capabilities` to choose the relevant capabilities. For simple informational queries, respond directly without selection."
        )
        sections.append("")

        if !tools.isEmpty {
            sections.append("## Tools (callable functions)")
            for tool in tools {
                let categoryTag = tool.category.map { " [\($0)]" } ?? ""
                sections.append("- **\(tool.name)**\(categoryTag): \(tool.description)")
            }
            sections.append("")
        }

        if !skills.isEmpty {
            sections.append("## Skills (specialized knowledge/guidance)")
            for skill in skills {
                let categoryTag = skill.category.map { " [\($0)]" } ?? ""
                sections.append("- **\(skill.name)**\(categoryTag): \(skill.description)")
            }
            sections.append("")
        }

        sections.append("### Selection Tips")
        sections.append("- Select tools you'll actually call, not all related tools")
        sections.append("- Select skills that provide domain expertise for the task")
        sections.append("- Fewer selections = faster execution and lower token usage")
        sections.append("")

        return sections.joined(separator: "\n")
    }

    /// Generate a compact catalog for smaller context windows
    public func asCompactCatalog() -> String {
        guard !isEmpty else {
            return ""
        }

        var lines: [String] = []
        lines.append("Available: ")

        var items: [String] = []
        for tool in tools {
            items.append("tool:\(tool.name)")
        }
        for skill in skills {
            items.append("skill:\(skill.name)")
        }

        lines.append(items.joined(separator: ", "))
        return lines.joined()
    }

    /// Get all capability names as a flat list
    public func allNames() -> [String] {
        tools.map { $0.name } + skills.map { $0.name }
    }

    /// Find a capability by name
    public func find(name: String) -> CapabilityEntry? {
        if let tool = tools.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return tool
        }
        if let skill = skills.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return skill
        }
        return nil
    }

    /// Filter capabilities by type
    public func filter(type: CapabilityType) -> [CapabilityEntry] {
        switch type {
        case .tool:
            return tools
        case .skill:
            return skills
        }
    }

    /// Filter capabilities by category
    public func filter(category: String) -> [CapabilityEntry] {
        let allEntries = tools + skills
        return allEntries.filter { $0.category?.lowercased() == category.lowercased() }
    }
}

// MARK: - Catalog Builder

/// Helper to build a capability catalog from ToolRegistry and SkillManager
@MainActor
public struct CapabilityCatalogBuilder {
    /// Build catalog from current enabled tools and skills
    public static func build() -> CapabilityCatalog {
        let toolEntries = ToolRegistry.shared.enabledCatalogEntries()
        let skillEntries = SkillManager.shared.enabledCatalogEntries()
        return CapabilityCatalog(tools: toolEntries, skills: skillEntries)
    }

    /// Build catalog for a specific persona, respecting persona-level overrides
    public static func build(for personaId: UUID) -> CapabilityCatalog {
        let toolOverrides = PersonaManager.shared.effectiveToolOverrides(for: personaId)
        let skillOverrides = PersonaManager.shared.effectiveSkillOverrides(for: personaId)

        // Get tools with persona overrides applied
        let toolEntries = ToolRegistry.shared.enabledCatalogEntries(withOverrides: toolOverrides)

        // Get skills with persona overrides applied
        let skillEntries = SkillManager.shared.enabledCatalogEntries(withOverrides: skillOverrides)

        return CapabilityCatalog(tools: toolEntries, skills: skillEntries)
    }

    /// Build catalog with specific tool and skill filters
    static func build(
        toolFilter: ((ToolRegistry.ToolEntry) -> Bool)? = nil,
        skillFilter: ((Skill) -> Bool)? = nil
    ) -> CapabilityCatalog {
        var toolEntries = ToolRegistry.shared.enabledCatalogEntries()
        var skillEntries = SkillManager.shared.enabledCatalogEntries()

        if let filter = toolFilter {
            let filteredTools = ToolRegistry.shared.listTools().filter(filter)
            let filteredNames = Set(filteredTools.map { $0.name })
            toolEntries = toolEntries.filter { filteredNames.contains($0.name) }
        }

        if let filter = skillFilter {
            let filteredSkills = SkillManager.shared.skills.filter(filter)
            let filteredNames = Set(filteredSkills.map { $0.name })
            skillEntries = skillEntries.filter { filteredNames.contains($0.name) }
        }

        return CapabilityCatalog(tools: toolEntries, skills: skillEntries)
    }
}

// MARK: - ToolRegistry Extension

extension ToolRegistry {
    /// Get catalog entries for all enabled tools (metadata only)
    public func enabledCatalogEntries() -> [CapabilityEntry] {
        listTools()
            .filter { $0.enabled }
            .map { tool in
                CapabilityEntry(
                    type: .tool,
                    name: tool.name,
                    description: tool.description
                )
            }
    }

    /// Get catalog entries with persona-level overrides applied
    public func enabledCatalogEntries(withOverrides overrides: [String: Bool]?) -> [CapabilityEntry] {
        listTools()
            .filter { tool in
                // Check override first, then fall back to global state
                if let overrides = overrides, let override = overrides[tool.name] {
                    return override
                }
                return tool.enabled
            }
            .map { tool in
                CapabilityEntry(
                    type: .tool,
                    name: tool.name,
                    description: tool.description
                )
            }
    }
}

// MARK: - SkillManager Extension

extension SkillManager {
    /// Get catalog entries with persona-level overrides applied
    public func enabledCatalogEntries(withOverrides overrides: [String: Bool]?) -> [CapabilityEntry] {
        skills
            .filter { skill in
                // Check override first, then fall back to global state
                if let overrides = overrides, let override = overrides[skill.name] {
                    return override
                }
                return skill.enabled
            }
            .map { skill in
                CapabilityEntry(
                    type: .skill,
                    name: skill.name,
                    description: skill.description,
                    category: skill.category
                )
            }
    }
}
