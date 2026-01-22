//
//  CapabilityService.swift
//  osaurus
//
//  Service for building system prompts with capability catalog and skill instructions.
//  Supports two-phase loading: catalog-only for selection, full content for execution.
//

import Foundation

/// Service for managing capability (tools + skills) integration with chat
@MainActor
public final class CapabilityService {
    public static let shared = CapabilityService()

    private init() {}

    // MARK: - System Prompt Building

    /// Build an enhanced system prompt that includes enabled skill instructions.
    /// This is the simple integration path - all enabled skills are included.
    public func buildSystemPromptWithSkills(
        basePrompt: String,
        personaId: UUID?
    ) -> String {
        // Get the base system prompt
        let effectivePrompt = PersonaManager.shared.effectiveSystemPrompt(for: personaId ?? Persona.defaultId)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Get enabled skills
        let enabledSkills = SkillManager.shared.skills.filter { $0.enabled }

        guard !enabledSkills.isEmpty else {
            return effectivePrompt
        }

        // Build the enhanced prompt
        var enhanced = effectivePrompt

        if !enhanced.isEmpty {
            enhanced += "\n\n"
        }

        enhanced += "# Active Skills\n\n"
        enhanced += "The following skills provide specialized guidance for this conversation:\n\n"

        for skill in enabledSkills {
            enhanced += "## \(skill.name)\n"
            if !skill.description.isEmpty {
                enhanced += "*\(skill.description)*\n\n"
            }
            enhanced += skill.instructions
            enhanced += "\n\n---\n\n"
        }

        return enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Two-Phase Loading (Advanced)

    /// Build a capability catalog for the selection phase.
    /// Returns only metadata, not full content.
    public func buildCatalog() -> CapabilityCatalog {
        CapabilityCatalogBuilder.build()
    }

    /// Build system prompt with capability catalog for two-phase loading.
    /// The model will see metadata only and can call select_capabilities.
    public func buildSystemPromptWithCatalog(
        basePrompt: String,
        personaId: UUID?
    ) -> String {
        let effectivePrompt = PersonaManager.shared.effectiveSystemPrompt(for: personaId ?? Persona.defaultId)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let catalog = buildCatalog()

        guard !catalog.isEmpty else {
            return effectivePrompt
        }

        var enhanced = effectivePrompt

        if !enhanced.isEmpty {
            enhanced += "\n\n"
        }

        enhanced += catalog.asSystemPromptSection()

        return enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Load full content for selected capabilities.
    /// Returns tool schemas and skill instructions for the selected items.
    func loadSelectedCapabilities(
        toolNames: [String],
        skillNames: [String]
    ) -> (tools: [Tool], skillInstructions: String) {
        // Load tool specs for selected tools
        var tools: [Tool] = []
        for name in toolNames {
            if let entry = ToolRegistry.shared.listTools().first(where: { $0.name == name && $0.enabled }) {
                // Get the full tool spec
                let specs = ToolRegistry.shared.specs()
                if let spec = specs.first(where: { $0.function.name == name }) {
                    tools.append(spec)
                }
            }
        }

        // Load skill instructions for selected skills
        var instructions: [String] = []
        for name in skillNames {
            if let skill = SkillManager.shared.skill(named: name), skill.enabled {
                instructions.append("## \(skill.name)\n\n\(skill.instructions)")
            }
        }

        let combinedInstructions =
            instructions.isEmpty
            ? ""
            : "# Activated Skills\n\n" + instructions.joined(separator: "\n\n---\n\n")

        return (tools, combinedInstructions)
    }

    // MARK: - SelectCapabilities Tool

    /// Create a SelectCapabilitiesTool with a callback for handling selection.
    func createSelectCapabilitiesTool(
        onSelected: @escaping (CapabilitySelectionResult) -> Void
    ) -> SelectCapabilitiesTool {
        SelectCapabilitiesTool(onCapabilitiesSelected: onSelected)
    }

    // MARK: - Token Estimation

    /// Estimate the token count for enabled skills.
    /// Uses rough heuristic of ~4 characters per token.
    public func estimateSkillTokens() -> Int {
        let enabledSkills = SkillManager.shared.skills.filter { $0.enabled }
        let totalChars = enabledSkills.reduce(0) { sum, skill in
            sum + skill.name.count + skill.description.count + skill.instructions.count + 50  // overhead
        }
        return max(0, totalChars / 4)
    }

    /// Check if any skills are enabled.
    public var hasEnabledSkills: Bool {
        SkillManager.shared.skills.contains { $0.enabled }
    }

    /// Get count of enabled skills.
    public var enabledSkillCount: Int {
        SkillManager.shared.enabledCount
    }
}
