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
        let dir = OsaurusPaths.sandboxPluginLibrary()
        OsaurusPaths.ensureExistsSilent(dir)
        let file = dir.appendingPathComponent("\(plugin.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(plugin) else { return }
        try? data.write(to: file, options: .atomic)

        if let index = plugins.firstIndex(where: { $0.id == plugin.id }) {
            plugins[index] = plugin
        } else {
            plugins.append(plugin)
        }
    }

    public func update(oldId: String, plugin: SandboxPlugin) {
        if oldId != plugin.id {
            delete(id: oldId)
        }
        save(plugin)
    }

    public func delete(id: String) {
        let file = OsaurusPaths.sandboxPluginLibrary().appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: file)
        plugins.removeAll { $0.id == id }
    }

    public func plugin(id: String) -> SandboxPlugin? {
        plugins.first { $0.id == id }
    }

    // MARK: - Export / Import

    public func exportData(for pluginId: String) -> Data? {
        guard let plugin = plugin(id: pluginId) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(plugin)
    }

    public func importFromData(_ data: Data) throws -> SandboxPlugin {
        let decoder = JSONDecoder()
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

    private func loadAll() {
        let dir = OsaurusPaths.sandboxPluginLibrary()
        let fm = FileManager.default
        OsaurusPaths.ensureExistsSilent(dir)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        var loaded: [SandboxPlugin] = []
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let plugin = try? decoder.decode(SandboxPlugin.self, from: data)
            else { continue }
            loaded.append(plugin)
        }
        plugins = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
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
