//
//  PersonaStore.swift
//  osaurus
//
//  Persistence for Personas (Application Support bundle directory)
//

import Foundation

@MainActor
public enum PersonaStore {
    /// Optional directory override for tests
    static var overrideDirectory: URL?

    // MARK: - Public API

    /// Load all personas sorted by name, including built-ins
    public static func loadAll() -> [Persona] {
        // Start with built-in personas
        var personas = Persona.builtInPersonas

        // Load custom personas from disk
        let directory = personasDirectory()
        ensureDirectoryExists(directory)

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return personas
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let persona = try decoder.decode(Persona.self, from: data)
                // Don't load if it conflicts with built-in IDs
                if !Persona.builtInPersonas.contains(where: { $0.id == persona.id }) {
                    personas.append(persona)
                }
            } catch {
                print("[Osaurus] Failed to load persona from \(file.lastPathComponent): \(error)")
            }
        }

        // Sort: built-ins first (Default, then Osaurus), then custom by name
        return personas.sorted { a, b in
            if a.isBuiltIn && !b.isBuiltIn { return true }
            if !a.isBuiltIn && b.isBuiltIn { return false }
            if a.isBuiltIn && b.isBuiltIn {
                // Default comes before Osaurus
                if a.id == Persona.defaultId { return true }
                if b.id == Persona.defaultId { return false }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Load a specific persona by ID
    public static func load(id: UUID) -> Persona? {
        // Check built-ins first
        if let builtIn = Persona.builtInPersonas.first(where: { $0.id == id }) {
            return builtIn
        }

        // Load from disk
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
        // Don't persist built-in personas
        guard !persona.isBuiltIn else {
            print("[Osaurus] Cannot save built-in persona: \(persona.name)")
            return
        }

        let url = personaFileURL(for: persona.id)
        ensureDirectoryExists(url.deletingLastPathComponent())

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
    /// Returns true if deletion was successful
    @discardableResult
    public static func delete(id: UUID) -> Bool {
        // Cannot delete built-in personas
        if Persona.builtInPersonas.contains(where: { $0.id == id }) {
            print("[Osaurus] Cannot delete built-in persona")
            return false
        }

        let url = personaFileURL(for: id)
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("[Osaurus] Failed to delete persona \(id): \(error)")
            return false
        }
    }

    /// Check if a persona exists
    public static func exists(id: UUID) -> Bool {
        if Persona.builtInPersonas.contains(where: { $0.id == id }) {
            return true
        }
        let url = personaFileURL(for: id)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Private

    private static func personasDirectory() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("Personas", isDirectory: true)
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return
            supportDir
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("Personas", isDirectory: true)
    }

    private static func personaFileURL(for id: UUID) -> URL {
        personasDirectory().appendingPathComponent("\(id.uuidString).json")
    }

    private static func ensureDirectoryExists(_ url: URL) {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                print("[Osaurus] Failed to create directory \(url.path): \(error)")
            }
        }
    }
}
