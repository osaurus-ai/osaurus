//
//  ThemeConfigurationStore.swift
//  osaurus
//
//  Handles persistence of custom themes
//

import Foundation

/// Handles persistence of custom themes
@MainActor
public enum ThemeConfigurationStore {
    private static let activeThemeKey = "activeThemeId"
    private static var builtInThemesInstalled = false

    // MARK: - Active Theme

    static func loadActiveThemeId() -> UUID? {
        guard let string = UserDefaults.standard.string(forKey: activeThemeKey) else { return nil }
        return UUID(uuidString: string)
    }

    static func saveActiveThemeId(_ themeId: UUID?) {
        if let themeId = themeId {
            UserDefaults.standard.set(themeId.uuidString, forKey: activeThemeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeThemeKey)
        }
    }

    static func loadActiveTheme() -> CustomTheme? {
        guard let themeId = loadActiveThemeId() else { return nil }
        return loadTheme(id: themeId)
    }

    // MARK: - Theme CRUD

    static func listThemes() -> [CustomTheme] {
        ensureThemesDirectoryAndBuiltIns()

        let themesDir = themesDirectoryURL()
        guard FileManager.default.fileExists(atPath: themesDir.path) else { return [] }

        do {
            let contents = try FileManager.default.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: nil)
            return
                contents
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> CustomTheme? in
                    do {
                        return try decodeTheme(from: url)
                    } catch {
                        handleCorruptedThemeFile(url)
                        return nil
                    }
                }
        } catch {
            return []
        }
    }

    static func loadTheme(id: UUID) -> CustomTheme? {
        let url = themeFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? decodeTheme(from: url)
    }

    static func saveTheme(_ theme: CustomTheme) {
        do {
            try OsaurusPaths.ensureExists(themesDirectoryURL())
            let data = try encodeTheme(theme)
            try data.write(to: themeFileURL(for: theme.metadata.id), options: .atomic)
        } catch {
            print("[Osaurus] Failed to save theme '\(theme.metadata.name)': \(error)")
        }
    }

    @discardableResult
    static func deleteTheme(id: UUID) -> Bool {
        // Don't allow deleting built-in themes
        if let theme = loadTheme(id: id), theme.isBuiltIn { return false }

        let url = themeFileURL(for: id)
        try? FileManager.default.removeItem(at: url)

        // Clear active reference if this was the active theme
        if loadActiveThemeId() == id {
            saveActiveThemeId(nil)
        }
        return true
    }

    // MARK: - Import/Export

    static func exportTheme(_ theme: CustomTheme, to url: URL) throws {
        let data = try encodeTheme(theme)
        try data.write(to: url, options: .atomic)
    }

    static func importTheme(from url: URL) throws -> CustomTheme {
        var theme = try decodeTheme(from: url)
        theme.metadata.id = UUID()
        theme.metadata.createdAt = Date()
        theme.metadata.updatedAt = Date()
        theme.isBuiltIn = false
        saveTheme(theme)
        return theme
    }

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

    static func installBuiltInThemesIfNeeded() {
        guard (try? OsaurusPaths.ensureExists(themesDirectoryURL())) != nil else { return }

        for theme in CustomTheme.allBuiltInPresets {
            let url = themeFileURL(for: theme.metadata.id)
            if !FileManager.default.fileExists(atPath: url.path) {
                saveTheme(theme)
            }
        }
        builtInThemesInstalled = true
    }

    static func forceReinstallBuiltInThemes() {
        guard (try? OsaurusPaths.ensureExists(themesDirectoryURL())) != nil else { return }

        for theme in CustomTheme.allBuiltInPresets {
            saveTheme(theme)
        }
        builtInThemesInstalled = true
    }

    // MARK: - Private Helpers

    private static func ensureThemesDirectoryAndBuiltIns() {
        if !builtInThemesInstalled {
            installBuiltInThemesIfNeeded()
        }
    }

    private static func handleCorruptedThemeFile(_ url: URL) {
        let filename = url.deletingPathExtension().lastPathComponent
        guard let uuid = UUID(uuidString: filename) else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        if let builtInTheme = CustomTheme.allBuiltInPresets.first(where: { $0.metadata.id == uuid }) {
            try? FileManager.default.removeItem(at: url)
            saveTheme(builtInTheme)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func themesDirectoryURL() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.themes(), legacy: "Themes")
    }

    private static func themeFileURL(for id: UUID) -> URL {
        themesDirectoryURL().appendingPathComponent("\(id.uuidString).json")
    }

    private static func decodeTheme(from url: URL) throws -> CustomTheme {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CustomTheme.self, from: data)
    }

    private static func encodeTheme(_ theme: CustomTheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(theme)
    }
}
