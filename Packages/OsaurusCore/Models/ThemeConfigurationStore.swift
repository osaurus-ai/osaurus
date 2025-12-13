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

    /// Track if built-in themes have been installed this session
    private static var builtInThemesInstalled = false

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
                print("[Osaurus] Saved active theme ID: \(themeId)")
            } else {
                // Remove active theme file if set to nil
                try? FileManager.default.removeItem(at: url)
                print("[Osaurus] Cleared active theme")
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

    /// List all installed custom themes, ensuring built-in themes exist first
    static func listThemes() -> [CustomTheme] {
        // Ensure themes directory and built-in themes exist
        ensureThemesDirectoryAndBuiltIns()

        let themesDir = themesDirectoryURL()
        guard FileManager.default.fileExists(atPath: themesDir.path) else {
            print("[Osaurus] Themes directory does not exist: \(themesDir.path)")
            return []
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: themesDir,
                includingPropertiesForKeys: nil
            )
            let themeFiles = contents.filter { $0.pathExtension == "json" }
            print("[Osaurus] Found \(themeFiles.count) theme files in \(themesDir.path)")

            let themes = themeFiles.compactMap { url -> CustomTheme? in
                do {
                    let data = try Data(contentsOf: url)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    return try decoder.decode(CustomTheme.self, from: data)
                } catch {
                    print("[Osaurus] Failed to load theme from \(url.lastPathComponent): \(error)")
                    // Try to recover by deleting corrupted file and reinstalling if built-in
                    handleCorruptedThemeFile(url)
                    return nil
                }
            }
            print("[Osaurus] Successfully loaded \(themes.count) themes")
            return themes
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CustomTheme.self, from: data)
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
            print("[Osaurus] Saved theme '\(theme.metadata.name)' to \(url.lastPathComponent)")
        } catch {
            print("[Osaurus] Failed to save theme \(theme.metadata.name): \(error)")
        }
    }

    /// Delete a custom theme by ID
    /// Returns true if deletion was successful
    @discardableResult
    static func deleteTheme(id: UUID) -> Bool {
        let url = themeFileURL(for: id)

        // Don't allow deleting built-in themes
        if let theme = loadTheme(id: id), theme.isBuiltIn {
            print("[Osaurus] Cannot delete built-in theme: \(theme.metadata.name)")
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                print("[Osaurus] Deleted theme: \(id)")
            }
            // If this was the active theme, clear the active reference
            if loadActiveThemeId() == id {
                saveActiveThemeId(nil)
            }
            return true
        } catch {
            print("[Osaurus] Failed to delete theme \(id): \(error)")
            return false
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
        do {
            try ensureDirectoryExists(themesDirectoryURL())
            print("[Osaurus] Themes directory: \(themesDirectoryURL().path)")
        } catch {
            print("[Osaurus] Failed to create themes directory: \(error)")
            return
        }

        for theme in CustomTheme.allBuiltInPresets {
            let url = themeFileURL(for: theme.metadata.id)
            if !FileManager.default.fileExists(atPath: url.path) {
                print("[Osaurus] Installing built-in theme: \(theme.metadata.name)")
                saveTheme(theme)
            }
        }
        builtInThemesInstalled = true
    }

    /// Force reinstall all built-in themes (useful for recovery)
    static func forceReinstallBuiltInThemes() {
        print("[Osaurus] Force reinstalling all built-in themes...")
        do {
            try ensureDirectoryExists(themesDirectoryURL())
        } catch {
            print("[Osaurus] Failed to create themes directory: \(error)")
            return
        }

        for theme in CustomTheme.allBuiltInPresets {
            print("[Osaurus] Reinstalling built-in theme: \(theme.metadata.name)")
            saveTheme(theme)
        }
        builtInThemesInstalled = true
    }

    /// Ensure themes directory exists and built-in themes are installed
    private static func ensureThemesDirectoryAndBuiltIns() {
        if !builtInThemesInstalled {
            installBuiltInThemesIfNeeded()
        }
    }

    /// Handle a corrupted theme file
    private static func handleCorruptedThemeFile(_ url: URL) {
        // Extract UUID from filename
        let filename = url.deletingPathExtension().lastPathComponent
        guard let uuid = UUID(uuidString: filename) else {
            // Not a valid UUID filename, just delete it
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Check if this is a built-in theme that needs to be reinstalled
        if let builtInTheme = CustomTheme.allBuiltInPresets.first(where: { $0.metadata.id == uuid }) {
            print("[Osaurus] Reinstalling corrupted built-in theme: \(builtInTheme.metadata.name)")
            try? FileManager.default.removeItem(at: url)
            saveTheme(builtInTheme)
        } else {
            // Custom theme - just delete the corrupted file
            print("[Osaurus] Removing corrupted custom theme file: \(filename)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private Helpers

    private static func baseDirectoryURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Use a consistent bundle ID for the app
        let bundleId = Bundle.main.bundleIdentifier ?? "com.osaurus.app"
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
            print("[Osaurus] Created directory: \(url.path)")
        }
    }
}

// MARK: - Helper Types

private struct ActiveThemeReference: Codable {
    let themeId: UUID
}
