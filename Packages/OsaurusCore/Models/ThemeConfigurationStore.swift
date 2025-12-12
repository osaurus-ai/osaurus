//
//  ThemeConfigurationStore.swift
//  osaurus
//
//  Handles persistence of custom themes to Application Support
//

import Foundation

/// Handles persistence of custom themes
@MainActor
public enum ThemeConfigurationStore {
    /// Optional directory override for tests
    static var overrideDirectory: URL?

    /// Filename for the active theme reference
    private static let activeThemeFilename = "ActiveTheme.json"

    // MARK: - Active Theme

    /// Load the currently active custom theme ID
    static func loadActiveThemeId() -> UUID? {
        let url = activeThemeFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(ActiveThemeReference.self, from: data)
            return decoded.themeId
        } catch {
            print("[Osaurus] Failed to load active theme reference: \(error)")
            return nil
        }
    }

    /// Save the active theme ID
    static func saveActiveThemeId(_ themeId: UUID?) {
        let url = activeThemeFileURL()
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            if let themeId = themeId {
                let ref = ActiveThemeReference(themeId: themeId)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(ref)
                try data.write(to: url, options: [.atomic])
            } else {
                // Remove active theme file if set to nil
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            print("[Osaurus] Failed to save active theme reference: \(error)")
        }
    }

    /// Load the active custom theme
    static func loadActiveTheme() -> CustomTheme? {
        guard let themeId = loadActiveThemeId() else { return nil }
        return loadTheme(id: themeId)
    }

    // MARK: - Theme CRUD

    /// List all installed custom themes
    static func listThemes() -> [CustomTheme] {
        let themesDir = themesDirectoryURL()
        guard FileManager.default.fileExists(atPath: themesDir.path) else { return [] }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: themesDir,
                includingPropertiesForKeys: nil
            )
            let themeFiles = contents.filter { $0.pathExtension == "json" }

            return themeFiles.compactMap { url -> CustomTheme? in
                do {
                    let data = try Data(contentsOf: url)
                    return try JSONDecoder().decode(CustomTheme.self, from: data)
                } catch {
                    print("[Osaurus] Failed to load theme from \(url.lastPathComponent): \(error)")
                    return nil
                }
            }
        } catch {
            print("[Osaurus] Failed to list themes: \(error)")
            return []
        }
    }

    /// Load a specific theme by ID
    static func loadTheme(id: UUID) -> CustomTheme? {
        let url = themeFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CustomTheme.self, from: data)
        } catch {
            print("[Osaurus] Failed to load theme \(id): \(error)")
            return nil
        }
    }

    /// Save a custom theme
    static func saveTheme(_ theme: CustomTheme) {
        let url = themeFileURL(for: theme.metadata.id)
        do {
            try ensureDirectoryExists(themesDirectoryURL())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(theme)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save theme \(theme.metadata.name): \(error)")
        }
    }

    /// Delete a custom theme by ID
    static func deleteTheme(id: UUID) {
        let url = themeFileURL(for: id)
        do {
            try FileManager.default.removeItem(at: url)
            // If this was the active theme, clear the active reference
            if loadActiveThemeId() == id {
                saveActiveThemeId(nil)
            }
        } catch {
            print("[Osaurus] Failed to delete theme \(id): \(error)")
        }
    }

    // MARK: - Import/Export

    /// Export a theme to a portable JSON file
    static func exportTheme(_ theme: CustomTheme, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(theme)
        try data.write(to: url, options: [.atomic])
    }

    /// Import a theme from a JSON file
    static func importTheme(from url: URL) throws -> CustomTheme {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var theme = try decoder.decode(CustomTheme.self, from: data)

        // Assign a new ID to avoid conflicts
        theme.metadata.id = UUID()
        theme.metadata.createdAt = Date()
        theme.metadata.updatedAt = Date()
        // Imported themes are never built-in
        theme.isBuiltIn = false

        // Save the imported theme
        saveTheme(theme)

        return theme
    }

    /// Duplicate an existing theme with a new name
    static func duplicateTheme(_ theme: CustomTheme, newName: String) -> CustomTheme {
        var newTheme = theme
        newTheme.metadata.id = UUID()
        newTheme.metadata.name = newName
        newTheme.metadata.createdAt = Date()
        newTheme.metadata.updatedAt = Date()
        newTheme.isBuiltIn = false
        saveTheme(newTheme)
        return newTheme
    }

    // MARK: - Built-in Themes

    /// Install built-in themes if they don't exist
    static func installBuiltInThemesIfNeeded() {
        for theme in CustomTheme.allBuiltInPresets {
            let url = themeFileURL(for: theme.metadata.id)
            if !FileManager.default.fileExists(atPath: url.path) {
                saveTheme(theme)
            }
        }
    }

    // MARK: - Private Helpers

    private static func baseDirectoryURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
    }

    private static func themesDirectoryURL() -> URL {
        baseDirectoryURL().appendingPathComponent("Themes", isDirectory: true)
    }

    private static func themeFileURL(for id: UUID) -> URL {
        themesDirectoryURL().appendingPathComponent("\(id.uuidString).json")
    }

    private static func activeThemeFileURL() -> URL {
        baseDirectoryURL().appendingPathComponent(activeThemeFilename)
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Helper Types

private struct ActiveThemeReference: Codable {
    let themeId: UUID
}
