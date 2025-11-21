import Foundation

public struct PluginReceipt: Codable, Equatable {
    public struct ArtifactInfo: Codable, Equatable {
        public let url: String
        public let sha256: String
        public let minisign: MinisignInfo?
        public let size: Int?
    }

    public let plugin_id: String
    public let version: SemanticVersion
    public let installed_at: Date
    public let dylib_filename: String
    public let dylib_sha256: String
    public let platform: String
    public let arch: String
    public let public_keys: [String: String]?
    public let artifact: ArtifactInfo
}

public final class InstalledPluginsStore: @unchecked Sendable {
    public static let shared = InstalledPluginsStore()
    private init() {}

    private struct Index: Codable {
        var receipts: [String: [String: PluginReceipt]]  // plugin_id -> version -> receipt
    }

    private func loadIndex() -> Index {
        let fm = FileManager.default
        let url = ToolsPaths.receiptsIndexURL()
        guard fm.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let idx = try? JSONDecoder().decode(Index.self, from: data)
        else {
            return Index(receipts: [:])
        }
        return idx
    }

    private func saveIndex(_ idx: Index) {
        let fm = FileManager.default
        let url = ToolsPaths.receiptsIndexURL()
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? JSONEncoder().encode(idx) {
            try? data.write(to: url)
        }
    }

    public func record(_ receipt: PluginReceipt) {
        var idx = loadIndex()
        var versions = idx.receipts[receipt.plugin_id] ?? [:]
        versions[receipt.version.description] = receipt
        idx.receipts[receipt.plugin_id] = versions
        saveIndex(idx)
    }

    public func receipt(pluginId: String, version: SemanticVersion) -> PluginReceipt? {
        let idx = loadIndex()
        return idx.receipts[pluginId]?[version.description]
    }

    public func installedVersions(pluginId: String) -> [SemanticVersion] {
        let idx = loadIndex()
        guard let vers = idx.receipts[pluginId] else { return [] }
        return vers.keys.compactMap(SemanticVersion.parse).sorted(by: >)
    }

    public func latestInstalledVersion(pluginId: String) -> SemanticVersion? {
        installedVersions(pluginId: pluginId).first
    }
}
