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
        let effectivePersonaId = personaId ?? Persona.defaultId
        let effectivePrompt = PersonaManager.shared.effectiveSystemPrompt(for: effectivePersonaId)
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
    /// Uses persona-level overrides to filter available capabilities.
    public func buildSystemPromptWithCatalog(
        basePrompt: String,
        personaId: UUID?
    ) -> String {
        let effectivePersonaId = personaId ?? Persona.defaultId
        let effectivePrompt = PersonaManager.shared.effectiveSystemPrompt(for: effectivePersonaId)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Build catalog with persona-level overrides
        let catalog = CapabilityCatalogBuilder.build(for: effectivePersonaId)

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
    public func estimateCatalogSkillTokens(for personaId: UUID?) -> Int {
        let skills = enabledSkills(for: personaId)
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

    // MARK: - Persona-Aware Skill Checking

    /// Check if a skill is enabled for a given persona.
    /// Takes into account persona-level overrides.
    public func isSkillEnabled(_ skillName: String, for personaId: UUID?) -> Bool {
        guard let skill = SkillManager.shared.skill(named: skillName) else {
            return false
        }

        let effectivePersonaId = personaId ?? Persona.defaultId

        // Check persona override first
        if let overrides = PersonaManager.shared.effectiveSkillOverrides(for: effectivePersonaId),
            let override = overrides[skillName]
        {
            return override
        }

        // Fall back to global skill state
        return skill.enabled
    }

    /// Get enabled skills for a given persona.
    /// Takes into account persona-level overrides.
    public func enabledSkills(for personaId: UUID?) -> [Skill] {
        SkillManager.shared.skills.filter { skill in
            isSkillEnabled(skill.name, for: personaId)
        }
    }

    /// Check if any skills are enabled for a given persona.
    public func hasEnabledSkills(for personaId: UUID?) -> Bool {
        SkillManager.shared.skills.contains { skill in
            isSkillEnabled(skill.name, for: personaId)
        }
    }

    // MARK: - Agent Mode System Prompt

    /// Build system prompt for agent mode execution.
    /// Includes agent-specific instructions for planning, execution, and discovery.
    public func buildAgentSystemPrompt(
        basePrompt: String,
        personaId: UUID?
    ) -> String {
        let effectivePersonaId = personaId ?? Persona.defaultId
        let effectivePrompt = PersonaManager.shared.effectiveSystemPrompt(for: effectivePersonaId)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var enhanced = effectivePrompt

        if !enhanced.isEmpty {
            enhanced += "\n\n"
        }

        enhanced += agentModeInstructions

        return enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Agent mode instructions appended to the system prompt
    private var agentModeInstructions: String {
        """
        # Agent Mode

        You are operating in Agent Mode, which means you will systematically plan and execute tasks.

        ## Execution Model

        1. **Planning Phase**: When given a task, first create a step-by-step plan
           - Each step should be concrete and actionable
           - Maximum 10 steps per execution cycle
           - If a task requires more steps, it will be decomposed into subtasks

        2. **Execution Phase**: Execute each step methodically
           - Use available tools to accomplish tasks
           - Report progress after each step
           - Note any issues or blockers encountered

        3. **Discovery**: During execution, watch for:
           - Errors or bugs that need fixing
           - TODO/FIXME comments that should be tracked
           - Prerequisites that weren't initially known
           - Follow-up work to be done later

        4. **Verification**: After completing steps, verify the goal was achieved
           - Provide a summary of what was accomplished
           - Note any remaining work

        ## Guidelines

        - Be systematic and thorough
        - Use tools when they help accomplish the task
        - Report discoveries so they can be tracked
        - Stay focused on the current issue
        - If stuck, explain what's blocking progress

        ## Bounded Context

        Each task execution is limited to 10 tool calls to keep work focused.
        If more work is needed, the task will be split into smaller subtasks
        that execute sequentially.
        """
    }
}
