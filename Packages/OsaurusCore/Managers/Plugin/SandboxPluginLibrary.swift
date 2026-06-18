//
//  SandboxPluginLibrary.swift
//  osaurus
//
//  Central store for sandbox plugin definitions, decoupled from per-agent
//  installation. Plugin recipes live in ~/.osaurus/sandbox-plugins/ as JSON
//  files and can be installed to any agent via SandboxPluginManager.
//

import Foundation

@MainActor
public final class SandboxPluginLibrary: ObservableObject {
    public static let shared = SandboxPluginLibrary()

    @Published public private(set) var plugins: [SandboxPlugin] = []

    private init() {
        loadAll()
    }

    // MARK: - CRUD

    public func save(_ plugin: SandboxPlugin) {
        var pluginToSave = plugin
        pluginToSave.modifiedAt = Date()

        let dir = OsaurusPaths.sandboxPluginLibrary()
        let fm = FileManager.default
        OsaurusPaths.ensureExistsSilent(dir)
        let file = dir.appendingPathComponent("\(pluginToSave.id).json")

        let versionsDir = Self.versionsDirectory(for: pluginToSave.id)
        let highest = Self.highestVersion(in: versionsDir)

        if highest == 0 && fm.fileExists(atPath: file.path) {
            archiveLegacyPlugin(at: file, to: versionsDir)
            pluginToSave.version = "2"
        } else {
            pluginToSave.version = "\(highest + 1)"
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(pluginToSave) else { return }

        try? data.write(to: file, options: .atomic)

        OsaurusPaths.ensureExistsSilent(versionsDir)
        let versionFile = versionsDir.appendingPathComponent("\(pluginToSave.version!).json")
        try? data.write(to: versionFile, options: .atomic)

        if let index = plugins.firstIndex(where: { $0.id == pluginToSave.id }) {
            plugins[index] = pluginToSave
        } else {
            plugins.append(pluginToSave)
        }
    }

    public func update(oldId: String, plugin: SandboxPlugin) {
        if oldId != plugin.id {
            let fm = FileManager.default
            let oldVersionsDir = Self.versionsDirectory(for: oldId)
            let newVersionsDir = Self.versionsDirectory(for: plugin.id)
            if fm.fileExists(atPath: oldVersionsDir.path) {
                OsaurusPaths.ensureExistsSilent(newVersionsDir.deletingLastPathComponent())
                try? fm.moveItem(at: oldVersionsDir, to: newVersionsDir)
            }
            delete(id: oldId)
        }
        save(plugin)
    }

    public func delete(id: String) {
        let dir = OsaurusPaths.sandboxPluginLibrary()
        let fm = FileManager.default
        try? fm.removeItem(at: dir.appendingPathComponent("\(id).json"))
        try? fm.removeItem(at: Self.versionsDirectory(for: id))
        plugins.removeAll { $0.id == id }
    }

    public func plugin(id: String) -> SandboxPlugin? {
        plugins.first { $0.id == id }
    }

    // MARK: - Version History

    public func availableVersions(for pluginId: String) -> [PluginVersionEntry] {
        let versionsDir = Self.versionsDirectory(for: pluginId)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil)
        else { return [] }

        let currentVersion = plugin(id: pluginId).flatMap { Int($0.version ?? "") }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var entries: [PluginVersionEntry] = []
        for file in files where file.pathExtension == "json" {
            guard let versionNum = Int(file.deletingPathExtension().lastPathComponent),
                versionNum != currentVersion
            else { continue }

            var modifiedAt: Date?
            if let data = try? Data(contentsOf: file),
                let p = try? decoder.decode(SandboxPlugin.self, from: data)
            {
                modifiedAt = p.modifiedAt
            }
            entries.append(PluginVersionEntry(version: versionNum, modifiedAt: modifiedAt))
        }

        return entries.sorted { $0.version > $1.version }
    }

    public func rollback(id: String, to version: Int) {
        let versionsDir = Self.versionsDirectory(for: id)
        let versionFile = versionsDir.appendingPathComponent("\(version).json")
        let fm = FileManager.default

        guard let data = try? Data(contentsOf: versionFile) else { return }

        let dir = OsaurusPaths.sandboxPluginLibrary()
        try? data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)

        if let files = try? fm.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let num = Int(file.deletingPathExtension().lastPathComponent), num > version {
                    try? fm.removeItem(at: file)
                }
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let restored = try? decoder.decode(SandboxPlugin.self, from: data),
            let index = plugins.firstIndex(where: { $0.id == id })
        {
            plugins[index] = restored
        }
    }

    // MARK: - Export / Import

    public func exportData(for pluginId: String) -> Data? {
        guard let plugin = plugin(id: pluginId) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(plugin)
    }

    public func importFromData(_ data: Data) throws -> SandboxPlugin {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plugin = try decoder.decode(SandboxPlugin.self, from: data)
        let errors = plugin.validateFilePaths()
        guard errors.isEmpty else {
            throw SandboxPluginLibraryError.invalidPlugin(errors.joined(separator: "; "))
        }
        save(plugin)
        return plugin
    }

    public func importFromFile(_ url: URL) throws -> SandboxPlugin {
        let data = try Data(contentsOf: url)
        return try importFromData(data)
    }

    // MARK: - Persistence

    /// Kick off an off-main load of the recipe library, publishing results on
    /// the main actor when done. The previous synchronous version scanned the
    /// recipe directory and JSON-decoded every file inline, which blocked the
    /// UI the first time the management/Tools surface touched `.shared`
    /// (`ManagementBadgeStore` wiring + the Tools header). `plugins` starts
    /// empty and populates a beat later.
    private func loadAll() {
        Task { [weak self] in
            let loaded = await Self.readLibraryFromDisk()
            self?.plugins = loaded
        }
    }

    /// Read + decode + sort the recipe library entirely off the main thread.
    private static func readLibraryFromDisk() async -> [SandboxPlugin] {
        await Task.detached(priority: .userInitiated) {
            let dir = OsaurusPaths.sandboxPluginLibrary()
            let fm = FileManager.default
            OsaurusPaths.ensureExistsSilent(dir)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { return [] }

            var loaded: [SandboxPlugin] = []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                    let plugin = try? decoder.decode(SandboxPlugin.self, from: data)
                else { continue }
                loaded.append(plugin)
            }
            return loaded.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
    }

    // MARK: - Version Helpers

    private static func versionsDirectory(for pluginId: String) -> URL {
        OsaurusPaths.sandboxPluginLibrary()
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)
    }

    private static func highestVersion(in versionsDir: URL) -> Int {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: versionsDir,
                includingPropertiesForKeys: nil
            )
        else { return 0 }
        return
            files
            .filter { $0.pathExtension == "json" }
            .compactMap { Int($0.deletingPathExtension().lastPathComponent) }
            .max() ?? 0
    }

    private func archiveLegacyPlugin(at file: URL, to versionsDir: URL) {
        let fm = FileManager.default
        OsaurusPaths.ensureExistsSilent(versionsDir)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: file),
            var existing = try? decoder.decode(SandboxPlugin.self, from: data)
        else {
            try? fm.copyItem(at: file, to: versionsDir.appendingPathComponent("1.json"))
            return
        }

        existing.version = "1"
        if existing.modifiedAt == nil,
            let attrs = try? fm.attributesOfItem(atPath: file.path),
            let modDate = attrs[.modificationDate] as? Date
        {
            existing.modifiedAt = modDate
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let archiveData = try? encoder.encode(existing) {
            try? archiveData.write(
                to: versionsDir.appendingPathComponent("1.json"),
                options: .atomic
            )
        }
    }
}

// MARK: - Plugin Version Entry

public struct PluginVersionEntry: Identifiable {
    public var id: Int { version }
    public let version: Int
    public let modifiedAt: Date?
}

// MARK: - Errors

public enum SandboxPluginLibraryError: Error, LocalizedError {
    case invalidPlugin(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPlugin(let msg): "Invalid plugin: \(msg)"
        }
    }
}
