//
//  ThemeLibraryStore.swift
//  osaurus
//
//  User themes as JSON files under `themes/library/<uuid>.json`, kept apart
//  from Classic's `themes/<uuid>.json` so rolling back to Classic still
//  works. Presets are read-only and never written here.
//

import AppKit
import Foundation

enum ThemeLibraryError: LocalizedError {
    case readOnly
    case notFound
    case invalid([ThemePolicyFinding])

    var errorDescription: String? {
        switch self {
        case .readOnly: return L("Bundled themes can't be changed. Duplicate it to make your own.")
        case .notFound: return L("That theme no longer exists.")
        case .invalid(let findings):
            let first = findings.first { $0.severity == .error }?.message ?? ""
            return L("The theme isn't valid. \(first)")
        }
    }
}

/// File operations, safe off the main actor (used by the Classic migrator).
enum ThemeLibraryFiles {
    static func directory(root: URL = OsaurusPaths.themes()) -> URL {
        root.appendingPathComponent("library", isDirectory: true)
    }

    static func url(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    static func read(_ url: URL) -> ThemeDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ThemeDocumentCodec.decoder().decode(ThemeDocument.self, from: data)
    }

    static func list(in directory: URL) -> [ThemeDocument] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap(read)
    }

    static func write(_ document: ThemeDocument, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ThemeDocumentCodec.encode(document).write(to: url(for: document.id, in: directory), options: .atomic)
    }
}

@MainActor
final class ThemeLibraryStore: ObservableObject {
    static let shared = ThemeLibraryStore()

    /// User themes, sorted by name.
    @Published private(set) var themes: [ThemeDocument] = []

    private let directoryOverride: URL?
    /// Deleted themes go to the Trash so they can be recovered.
    private let trashesDeletedThemes: Bool

    init(directory: URL? = nil, trashesDeletedThemes: Bool = true) {
        directoryOverride = directory
        self.trashesDeletedThemes = trashesDeletedThemes
        reload()
    }

    var directory: URL { directoryOverride ?? ThemeLibraryFiles.directory() }

    /// Presets first, then the user's themes.
    var all: [ThemeDocument] { ThemePresets.all + themes }

    func reload() {
        let loaded = ThemeLibraryFiles.list(in: directory)
            .filter { !ThemePresets.isPreset($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if loaded != themes { themes = loaded }
    }

    /// nil is the Osaurus preset.
    func document(id: UUID?) -> ThemeDocument? {
        guard let id else { return ThemePresets.osaurus }
        return ThemePresets.preset(id: id) ?? themes.first { $0.id == id }
    }

    func isPreset(_ id: UUID) -> Bool { ThemePresets.isPreset(id) }

    func fileURL(for id: UUID) -> URL { ThemeLibraryFiles.url(for: id, in: directory) }

    // MARK: - CRUD

    /// Saves a user theme, stamping `updatedAt` and clamping overrides.
    @discardableResult
    func save(_ document: ThemeDocument) throws -> ThemeDocument {
        guard !isPreset(document.id) else { throw ThemeLibraryError.readOnly }
        var saved = document
        let (clean, findings) = ThemeTokenPolicy.sanitize(document.overrides, base: ThemeCompiler.library)
        if findings.contains(where: { $0.severity == .error }) { throw ThemeLibraryError.invalid(findings) }
        saved.overrides = clean.isEmpty ? nil : clean
        saved.schemaVersion = ThemeDocument.currentSchemaVersion
        saved.updatedAt = Date()
        try ThemeLibraryFiles.write(saved, in: directory)
        reload()
        return saved
    }

    func delete(id: UUID) throws {
        guard !isPreset(id) else { throw ThemeLibraryError.readOnly }
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            let trashed = trashesDeletedThemes && (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
            if !trashed { try FileManager.default.removeItem(at: url) }
        }
        reload()
    }

    /// Copies any theme, preset or user, into a new editable theme.
    @discardableResult
    func duplicate(id: UUID?) throws -> ThemeDocument {
        guard let source = document(id: id) else { throw ThemeLibraryError.notFound }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueName(L("\(source.name) Copy"))
        copy.author = ""
        copy.createdAt = Date()
        return try save(copy)
    }

    /// A fresh theme based on the given one's preferences.
    func makeNew(basedOn base: ThemeDocument? = nil) -> ThemeDocument {
        ThemeDocument(
            name: uniqueName(L("New Theme")),
            appearance: base?.appearance ?? .both,
            preferences: base?.preferences ?? .default
        )
    }

    func uniqueName(_ name: String) -> String {
        let taken = Set(all.map(\.name))
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    // MARK: - JSON

    /// Validates `text` and, when it has no errors, saves it over `id`.
    func updateJSON(id: UUID, text: String) -> ThemeJSONValidation {
        var validation = ThemeTokenPolicy.validateJSON(text, base: ThemeCompiler.library)
        guard var document = validation.document else { return validation }
        document.id = id
        do {
            validation.document = try save(document)
        } catch {
            validation.document = nil
            validation.findings.append(ThemePolicyFinding(severity: .error, message: error.localizedDescription))
        }
        return validation
    }

    /// Imports a theme file. A theme whose id is taken gets a new one.
    @discardableResult
    func importTheme(from url: URL) throws -> ThemeDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try importJSON(text)
    }

    @discardableResult
    func importJSON(_ text: String) throws -> ThemeDocument {
        let validation = ThemeTokenPolicy.validateJSON(text, base: ThemeCompiler.library)
        guard var document = validation.document else { throw ThemeLibraryError.invalid(validation.findings) }
        if document.id == UUID(uuidString: "00000000-0000-0000-0000-000000000000")
            || isPreset(document.id) || themes.contains(where: { $0.id == document.id })
        {
            document.id = UUID()
        }
        document.name = uniqueName(document.name)
        return try save(document)
    }

    func export(id: UUID?, to url: URL) throws {
        guard let document = document(id: id) else { throw ThemeLibraryError.notFound }
        try ThemeDocumentCodec.encode(document).write(to: url, options: .atomic)
    }

    func revealInFinder(id: UUID) {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
