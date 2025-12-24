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
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        let dir = supportDir.appendingPathComponent(bundleId, isDirectory: true)

        // Ensure directory exists
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir.appendingPathComponent("ActivePersonaId.txt")
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
}
