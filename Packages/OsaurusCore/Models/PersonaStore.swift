//
//  PersonaStore.swift
//  osaurus
//
//  Persistence for Personas
//

import Foundation

@MainActor
public enum PersonaStore {
    // MARK: - Public API

    /// Load all personas sorted by name, including built-ins
    public static func loadAll() -> [Persona] {
        var personas = Persona.builtInPersonas
        let directory = personasDirectory()
        OsaurusPaths.ensureExistsSilent(directory)

        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return personas
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let persona = try decoder.decode(Persona.self, from: data)
                if !Persona.builtInPersonas.contains(where: { $0.id == persona.id }) {
                    personas.append(persona)
                }
            } catch {
                print("[Osaurus] Failed to load persona from \(file.lastPathComponent): \(error)")
            }
        }

        return personas.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            if a.isBuiltIn && b.isBuiltIn {
                if a.id == Persona.defaultId { return true }
                if b.id == Persona.defaultId { return false }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Load a specific persona by ID
    public static func load(id: UUID) -> Persona? {
        if let builtIn = Persona.builtInPersonas.first(where: { $0.id == id }) {
            return builtIn
        }

        let url = personaFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Persona.self, from: data)
        } catch {
            print("[Osaurus] Failed to load persona \(id): \(error)")
            return nil
        }
    }

    /// Save a persona (creates or updates). Cannot save built-in personas.
    public static func save(_ persona: Persona) {
        guard !persona.isBuiltIn else {
            print("[Osaurus] Cannot save built-in persona: \(persona.name)")
            return
        }

        let url = personaFileURL(for: persona.id)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persona)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save persona \(persona.id): \(error)")
        }
    }

    /// Delete a persona by ID. Cannot delete built-in personas.
    @discardableResult
    public static func delete(id: UUID) -> Bool {
        if Persona.builtInPersonas.contains(where: { $0.id == id }) {
            print("[Osaurus] Cannot delete built-in persona")
            return false
        }

        do {
            try FileManager.default.removeItem(at: personaFileURL(for: id))
            return true
        } catch {
            print("[Osaurus] Failed to delete persona \(id): \(error)")
            return false
        }
    }

    /// Check if a persona exists
    public static func exists(id: UUID) -> Bool {
        Persona.builtInPersonas.contains(where: { $0.id == id })
            || FileManager.default.fileExists(atPath: personaFileURL(for: id).path)
    }

    // MARK: - Private

    private static func personasDirectory() -> URL {
        OsaurusPaths.resolveDirectory(new: OsaurusPaths.personas(), legacy: "Personas")
    }

    private static func personaFileURL(for id: UUID) -> URL {
        personasDirectory().appendingPathComponent("\(id.uuidString).json")
    }
}
