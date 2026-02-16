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
        agentId: UUID?
    ) -> String {
        let effectiveAgentId = agentId ?? Agent.defaultId
        let effectivePrompt = AgentManager.shared.effectiveSystemPrompt(for: effectiveAgentId)
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
        enhanced += "Apply the following skill guidance contextually based on the task. "
        enhanced += "If multiple skills are relevant, synthesize their guidance coherently.\n\n"

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
    /// Uses agent-level overrides to filter available capabilities.
    public func buildSystemPromptWithCatalog(
        basePrompt: String,
        agentId: UUID?
    ) -> String {
        let effectiveAgentId = agentId ?? Agent.defaultId
        let effectivePrompt = AgentManager.shared.effectiveSystemPrompt(for: effectiveAgentId)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Build catalog with agent-level overrides
        let catalog = CapabilityCatalogBuilder.build(for: effectiveAgentId)

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
            if ToolRegistry.shared.listTools().contains(where: { $0.name == name && $0.enabled }) {
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

    /// Estimate the token count for enabled skills (full instructions).
    /// Uses rough heuristic of ~4 characters per token.
    public func estimateSkillTokens() -> Int {
        let enabledSkills = SkillManager.shared.skills.filter { $0.enabled }
        let totalChars = enabledSkills.reduce(0) { sum, skill in
            sum + skill.name.count + skill.description.count + skill.instructions.count + 50  // overhead
        }
        return max(0, totalChars / 4)
    }

    /// Estimate tokens for skill catalog entries (name + description only).
    /// Used in two-phase loading for the selection phase.
    public func estimateCatalogSkillTokens(for agentId: UUID?) -> Int {
        let skills = enabledSkills(for: agentId)
        // Format: "- **name**: description\n" ≈ 6 chars overhead per skill
        let totalChars = skills.reduce(0) { sum, skill in
            sum + skill.name.count + skill.description.count + 6
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

    // MARK: - Agent-Aware Skill Checking

    /// Check if a skill is enabled for a given agent.
    /// Takes into account agent-level overrides.
    public func isSkillEnabled(_ skillName: String, for agentId: UUID?) -> Bool {
        guard let skill = SkillManager.shared.skill(named: skillName) else {
            return false
        }

        let effectiveAgentId = agentId ?? Agent.defaultId

        // Check agent override first
        if let overrides = AgentManager.shared.effectiveSkillOverrides(for: effectiveAgentId),
            let override = overrides[skillName]
        {
            return override
        }

        // Fall back to global skill state
        return skill.enabled
    }

    /// Get enabled skills for a given agent.
    /// Takes into account agent-level overrides.
    public func enabledSkills(for agentId: UUID?) -> [Skill] {
        SkillManager.shared.skills.filter { skill in
            isSkillEnabled(skill.name, for: agentId)
        }
    }

    /// Check if any skills are enabled for a given agent.
    public func hasEnabledSkills(for agentId: UUID?) -> Bool {
        SkillManager.shared.skills.contains { skill in
            isSkillEnabled(skill.name, for: agentId)
        }
    }

}
