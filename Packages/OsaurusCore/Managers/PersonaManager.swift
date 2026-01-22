//
//  PersonaManager.swift
//  osaurus
//
//  Manages persona lifecycle - loading, saving, switching, and notifications
//

import Combine
import Foundation
import SwiftUI

/// Notification posted when the active persona changes
extension Notification.Name {
    static let activePersonaChanged = Notification.Name("activePersonaChanged")
}

/// Manages all personas and the currently active persona
@MainActor
public final class PersonaManager: ObservableObject {
    public static let shared = PersonaManager()

    /// All available personas (built-in + custom)
    @Published public private(set) var personas: [Persona] = []

    /// The currently active persona ID
    @Published public private(set) var activePersonaId: UUID = Persona.defaultId

    /// The currently active persona
    public var activePersona: Persona {
        personas.first { $0.id == activePersonaId } ?? Persona.default
    }

    private init() {
        refresh()

        // Load saved active persona
        if let savedId = loadActivePersonaId() {
            // Verify persona still exists
            if personas.contains(where: { $0.id == savedId }) {
                activePersonaId = savedId
            }
        }
    }

    // MARK: - Public API

    /// Reload personas from disk
    public func refresh() {
        personas = PersonaStore.loadAll()
    }

    /// Set the active persona
    public func setActivePersona(_ id: UUID) {
        // Verify persona exists, fallback to default if not
        let targetId = personas.contains(where: { $0.id == id }) ? id : Persona.defaultId

        if activePersonaId != targetId {
            activePersonaId = targetId
            saveActivePersonaId(targetId)
            NotificationCenter.default.post(name: .activePersonaChanged, object: nil)
        }
    }

    /// Create a new persona
    @discardableResult
    public func create(
        name: String,
        description: String = "",
        systemPrompt: String = "",
        enabledTools: [String: Bool]? = nil,
        enabledSkills: [String: Bool]? = nil,
        themeId: UUID? = nil,
        defaultModel: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil
    ) -> Persona {
        let persona = Persona(
            id: UUID(),
            name: name,
            description: description,
            systemPrompt: systemPrompt,
            enabledTools: enabledTools,
            enabledSkills: enabledSkills,
            themeId: themeId,
            defaultModel: defaultModel,
            temperature: temperature,
            maxTokens: maxTokens,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        PersonaStore.save(persona)
        refresh()
        return persona
    }

    /// Update an existing persona
    public func update(_ persona: Persona) {
        guard !persona.isBuiltIn else {
            print("[Osaurus] Cannot update built-in persona")
            return
        }
        var updated = persona
        updated.updatedAt = Date()
        PersonaStore.save(updated)
        refresh()
    }

    /// Delete a persona by ID
    /// Returns true if deletion was successful
    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard PersonaStore.delete(id: id) else {
            return false
        }

        // If we deleted the active persona, switch to default
        if activePersonaId == id {
            setActivePersona(Persona.defaultId)
        }

        refresh()
        return true
    }

    /// Get a persona by ID
    public func persona(for id: UUID) -> Persona? {
        personas.first { $0.id == id }
    }

    /// Import a persona from JSON data
    @discardableResult
    public func importPersona(from data: Data) throws -> Persona {
        let persona = try Persona.importFromJSON(data)
        PersonaStore.save(persona)
        refresh()
        return persona
    }

    /// Export a persona to JSON data
    public func exportPersona(_ persona: Persona) throws -> Data {
        try persona.exportToJSON()
    }

    // MARK: - Active Persona Persistence

    private func loadActivePersonaId() -> UUID? {
        let url = activePersonaIdFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let uuidString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return uuidString.flatMap { UUID(uuidString: $0) }
        } catch {
            print("[Osaurus] Failed to load active persona ID: \(error)")
            return nil
        }
    }

    private func saveActivePersonaId(_ id: UUID) {
        let url = activePersonaIdFileURL()
        do {
            let data = id.uuidString.data(using: .utf8)!
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save active persona ID: \(error)")
        }
    }

    private func activePersonaIdFileURL() -> URL {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.personas())
        return OsaurusPaths.resolveFile(new: OsaurusPaths.activePersonaFile(), legacy: "ActivePersonaId.txt")
    }
}

// MARK: - Persona Configuration Helpers

extension PersonaManager {
    /// Get the effective system prompt for a persona (combining with global if needed)
    public func effectiveSystemPrompt(for personaId: UUID) -> String {
        guard let persona = persona(for: personaId) else {
            return ChatConfigurationStore.load().systemPrompt
        }

        // Default persona uses global settings
        if persona.id == Persona.defaultId {
            return ChatConfigurationStore.load().systemPrompt
        }

        // Custom personas use their own system prompt
        return persona.systemPrompt
    }

    /// Get the effective tool overrides for a persona
    public func effectiveToolOverrides(for personaId: UUID) -> [String: Bool]? {
        guard let persona = persona(for: personaId) else {
            return nil
        }

        // Default persona uses global settings
        if persona.id == Persona.defaultId {
            return nil
        }

        return persona.enabledTools
    }

    /// Get the effective skill overrides for a persona
    public func effectiveSkillOverrides(for personaId: UUID) -> [String: Bool]? {
        guard let persona = persona(for: personaId) else {
            return nil
        }

        // Default persona uses global settings
        if persona.id == Persona.defaultId {
            return nil
        }

        return persona.enabledSkills
    }

    /// Get the effective model for a persona
    /// For custom personas without a model set, falls back to Default persona's model
    public func effectiveModel(for personaId: UUID) -> String? {
        guard let persona = persona(for: personaId) else {
            return ChatConfigurationStore.load().defaultModel
        }

        // Default persona uses global settings
        if persona.id == Persona.defaultId {
            return ChatConfigurationStore.load().defaultModel
        }

        // Custom persona: use persona's model if set, otherwise fall back to Default persona's model
        return persona.defaultModel ?? ChatConfigurationStore.load().defaultModel
    }

    /// Get the effective temperature for a persona
    public func effectiveTemperature(for personaId: UUID) -> Float? {
        guard let persona = persona(for: personaId) else {
            return ChatConfigurationStore.load().temperature
        }

        // Default persona uses global settings
        if persona.id == Persona.defaultId {
            return ChatConfigurationStore.load().temperature
        }

        return persona.temperature
    }

    /// Get the effective max tokens for a persona
    public func effectiveMaxTokens(for personaId: UUID) -> Int? {
        guard let persona = persona(for: personaId) else {
            return ChatConfigurationStore.load().maxTokens
        }

        // Default persona uses global settings
        if persona.id == Persona.defaultId {
            return ChatConfigurationStore.load().maxTokens
        }

        return persona.maxTokens
    }

    /// Get the theme ID for a persona (nil if persona uses global theme)
    public func themeId(for personaId: UUID) -> UUID? {
        guard let persona = persona(for: personaId) else {
            return nil
        }

        // Default persona uses global theme
        if persona.id == Persona.defaultId {
            return nil
        }

        return persona.themeId
    }

    /// Update the default model for a persona
    /// - Parameters:
    ///   - personaId: The persona to update
    ///   - model: The model ID to set as default (nil to clear/use global)
    public func updateDefaultModel(for personaId: UUID, model: String?) {
        // Handle Default persona by saving to ChatConfiguration
        if personaId == Persona.defaultId {
            var config = ChatConfigurationStore.load()
            config.defaultModel = model
            ChatConfigurationStore.save(config)
            return
        }

        // Handle custom personas
        guard var persona = persona(for: personaId) else { return }
        guard !persona.isBuiltIn else {
            print("[Osaurus] Cannot update built-in persona's model")
            return
        }

        persona.defaultModel = model
        persona.updatedAt = Date()
        PersonaStore.save(persona)
        refresh()
    }

    // MARK: - Tool/Skill Override Updates

    /// Update a single tool override for a persona
    /// For Default persona, updates global config. For custom personas, updates persona's enabledTools.
    public func setToolEnabled(_ enabled: Bool, tool: String, for personaId: UUID) {
        // Default persona -> update global config (this posts .toolsListChanged)
        if personaId == Persona.defaultId {
            ToolRegistry.shared.setEnabled(enabled, for: tool)
            return
        }

        // Custom persona -> update persona's enabledTools
        guard var persona = persona(for: personaId) else { return }
        var overrides = persona.enabledTools ?? [:]
        overrides[tool] = enabled
        persona.enabledTools = overrides
        persona.updatedAt = Date()
        PersonaStore.save(persona)
        refresh()
        // Post notification to trigger token cache invalidation
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    /// Update a single skill override for a persona
    /// For Default persona, updates global config. For custom personas, updates persona's enabledSkills.
    public func setSkillEnabled(_ enabled: Bool, skill: String, for personaId: UUID) {
        // Default persona -> update global skill config (this posts .skillsListChanged)
        if personaId == Persona.defaultId {
            if let s = SkillManager.shared.skill(named: skill) {
                SkillManager.shared.setEnabled(enabled, for: s.id)
            }
            return
        }

        // Custom persona -> update persona's enabledSkills
        guard var persona = persona(for: personaId) else { return }
        var overrides = persona.enabledSkills ?? [:]
        overrides[skill] = enabled
        persona.enabledSkills = overrides
        persona.updatedAt = Date()
        PersonaStore.save(persona)
        refresh()
        // Post notification to trigger token cache invalidation
        NotificationCenter.default.post(name: .skillsListChanged, object: nil)
    }

    /// Enable all tools for a persona (batched for efficiency)
    public func enableAllTools(for personaId: UUID, tools: [String]) {
        setAllTools(enabled: true, for: personaId, tools: tools)
    }

    /// Disable all tools for a persona (batched for efficiency)
    public func disableAllTools(for personaId: UUID, tools: [String]) {
        setAllTools(enabled: false, for: personaId, tools: tools)
    }

    /// Enable all skills for a persona (batched for efficiency)
    public func enableAllSkills(for personaId: UUID, skills: [String]) {
        setAllSkills(enabled: true, for: personaId, skills: skills)
    }

    /// Disable all skills for a persona (batched for efficiency)
    public func disableAllSkills(for personaId: UUID, skills: [String]) {
        setAllSkills(enabled: false, for: personaId, skills: skills)
    }

    // MARK: - Private Batch Helpers

    private func setAllTools(enabled: Bool, for personaId: UUID, tools: [String]) {
        // Default persona -> update global config
        if personaId == Persona.defaultId {
            for tool in tools {
                ToolRegistry.shared.setEnabled(enabled, for: tool)
            }
            return
        }

        // Custom persona -> batch update persona's enabledTools
        guard var persona = persona(for: personaId) else { return }
        var overrides = persona.enabledTools ?? [:]
        for tool in tools {
            overrides[tool] = enabled
        }
        persona.enabledTools = overrides
        persona.updatedAt = Date()
        PersonaStore.save(persona)
        refresh()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    private func setAllSkills(enabled: Bool, for personaId: UUID, skills: [String]) {
        // Default persona -> update global skill config
        if personaId == Persona.defaultId {
            for skillName in skills {
                if let s = SkillManager.shared.skill(named: skillName) {
                    SkillManager.shared.setEnabled(enabled, for: s.id)
                }
            }
            return
        }

        // Custom persona -> batch update persona's enabledSkills
        guard var persona = persona(for: personaId) else { return }
        var overrides = persona.enabledSkills ?? [:]
        for skill in skills {
            overrides[skill] = enabled
        }
        persona.enabledSkills = overrides
        persona.updatedAt = Date()
        PersonaStore.save(persona)
        refresh()
        NotificationCenter.default.post(name: .skillsListChanged, object: nil)
    }
}
