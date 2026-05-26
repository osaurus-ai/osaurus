//
//  ClaudePluginManifestStore.swift
//  osaurus
//
//  Persists a snapshot of every Claude plugin's `ClaudePluginManifest`
//  metadata so the Plugins tab can render rich Claude-plugin cards
//  without re-fetching from GitHub on every launch. The store is the
//  single source of truth for "what was installed under this pluginId",
//  separate from the live artifact records owned by `SkillManager`,
//  `ScheduleManager`, `SlashCommandRegistry`, and `MCPProviderManager`.
//

import Foundation

/// On-disk snapshot of a Claude-plugin manifest captured at install time.
/// Lightweight enough to round-trip as JSON. Avoids retaining the heavy
/// fetched assets — those live with the per-artifact managers — and
/// stores only enough to reconstruct the card / detail UI plus drive
/// version checks and the user-config sheet.
public struct ClaudePluginManifestSnapshot: Codable, Sendable, Hashable {
    public let pluginId: String
    public let name: String
    public let displayName: String
    public let description: String?
    public let version: String?
    public let sourceOwner: String
    public let sourceRepo: String
    public let sourceBranch: String?
    public let sourcePath: String?
    public let authorName: String?
    public let authorEmail: String?
    public let authorURL: String?
    public let homepage: String?
    public let repository: String?
    public let license: String?
    public let keywords: [String]
    public let installedAt: Date
    public let userConfigSpec: [ClaudePluginUserConfigField]
    public let declaresHooks: Bool
    public let declaresUnsupportedComponents: [String]

    /// Declared artifact counts captured at install. Used to seed the card
    /// before the manager-side counts settle (e.g. on cold launch right
    /// before SkillManager.loadAll completes).
    public let declaredCounts: DeclaredCounts

    public struct DeclaredCounts: Codable, Sendable, Hashable {
        public let skills: Int
        public let agents: Int
        public let commands: Int
        public let mcp: Int

        public init(skills: Int, agents: Int, commands: Int, mcp: Int) {
            self.skills = skills
            self.agents = agents
            self.commands = commands
            self.mcp = mcp
        }
    }

    public init(
        pluginId: String,
        name: String,
        displayName: String,
        description: String?,
        version: String?,
        sourceOwner: String,
        sourceRepo: String,
        sourceBranch: String? = nil,
        sourcePath: String? = nil,
        authorName: String? = nil,
        authorEmail: String? = nil,
        authorURL: String? = nil,
        homepage: String? = nil,
        repository: String? = nil,
        license: String? = nil,
        keywords: [String] = [],
        installedAt: Date,
        userConfigSpec: [ClaudePluginUserConfigField] = [],
        declaresHooks: Bool = false,
        declaresUnsupportedComponents: [String] = [],
        declaredCounts: DeclaredCounts
    ) {
        self.pluginId = pluginId
        self.name = name
        self.displayName = displayName
        self.description = description
        self.version = version
        self.sourceOwner = sourceOwner
        self.sourceRepo = sourceRepo
        self.sourceBranch = sourceBranch
        self.sourcePath = sourcePath
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorURL = authorURL
        self.homepage = homepage
        self.repository = repository
        self.license = license
        self.keywords = keywords
        self.installedAt = installedAt
        self.userConfigSpec = userConfigSpec
        self.declaresHooks = declaresHooks
        self.declaresUnsupportedComponents = declaresUnsupportedComponents
        self.declaredCounts = declaredCounts
    }

    /// Convenience GitHub URL pointing at the plugin's source tree. Used
    /// by the detail view's "Open on GitHub" button when an explicit
    /// `repository` URL was not provided by `plugin.json`.
    public var githubSourceURL: String {
        let base = "https://github.com/\(sourceOwner)/\(sourceRepo)"
        let branch = sourceBranch ?? "main"
        if let sourcePath, !sourcePath.isEmpty {
            return "\(base)/tree/\(branch)/\(sourcePath)"
        }
        return "\(base)/tree/\(branch)"
    }
}

/// JSON file-backed store for `ClaudePluginManifestSnapshot`. One file
/// per `pluginId` under `~/.osaurus/claude-plugins/manifests/`. Reads
/// and writes are synchronous on disk so the aggregator can rely on
/// `all()` returning every snapshot in a single pass without await.
public enum ClaudePluginManifestStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Persist (or overwrite) a snapshot for `snapshot.pluginId`.
    @discardableResult
    public static func save(_ snapshot: ClaudePluginManifestSnapshot) -> Bool {
        let url = OsaurusPaths.claudePluginManifestFile(for: snapshot.pluginId)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Read one snapshot, or `nil` when the file is missing / unreadable.
    public static func load(pluginId: String) -> ClaudePluginManifestSnapshot? {
        let url = OsaurusPaths.claudePluginManifestFile(for: pluginId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(ClaudePluginManifestSnapshot.self, from: data)
    }

    /// Load every snapshot under the manifests directory. Returns them
    /// sorted by `displayName` for stable UI ordering. Bad JSON files
    /// are silently skipped so one corrupt file doesn't blank the grid.
    public static func all() -> [ClaudePluginManifestSnapshot] {
        let dir = OsaurusPaths.claudePluginsManifestsDir()
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        var out: [ClaudePluginManifestSnapshot] = []
        for entry in entries where entry.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: entry),
                let snap = try? decoder.decode(
                    ClaudePluginManifestSnapshot.self,
                    from: data
                )
            else { continue }
            out.append(snap)
        }
        return out.sorted { lhs, rhs in
            lhs.displayName.lowercased() < rhs.displayName.lowercased()
        }
    }

    /// Remove the snapshot + the per-plugin user-config + data directory
    /// for `pluginId`. Idempotent; missing entries are not errors.
    public static func delete(pluginId: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: OsaurusPaths.claudePluginManifestFile(for: pluginId))
        try? fm.removeItem(at: OsaurusPaths.claudePluginUserConfigFile(for: pluginId))
        try? fm.removeItem(at: OsaurusPaths.claudePluginDataDir(for: pluginId))
        try? fm.removeItem(at: OsaurusPaths.claudePluginCacheDir(for: pluginId))
    }

    // MARK: - userConfig (non-sensitive) values

    /// Per-plugin non-sensitive user_config values keyed by config key.
    /// Sensitive values live in the Keychain; the store never sees them.
    /// Wrapped in a `Snapshot` envelope so we can evolve the on-disk
    /// schema without breaking older readers.
    public struct UserConfigSnapshot: Codable, Sendable, Hashable {
        public var pluginId: String
        public var values: [String: String]
        public var updatedAt: Date

        public init(pluginId: String, values: [String: String], updatedAt: Date) {
            self.pluginId = pluginId
            self.values = values
            self.updatedAt = updatedAt
        }
    }

    @discardableResult
    public static func saveUserConfig(
        pluginId: String,
        values: [String: String]
    ) -> Bool {
        let url = OsaurusPaths.claudePluginUserConfigFile(for: pluginId)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let snapshot = UserConfigSnapshot(
            pluginId: pluginId,
            values: values,
            updatedAt: Date()
        )
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func loadUserConfig(pluginId: String) -> [String: String] {
        let url = OsaurusPaths.claudePluginUserConfigFile(for: pluginId)
        guard let data = try? Data(contentsOf: url),
            let snap = try? decoder.decode(UserConfigSnapshot.self, from: data)
        else {
            return [:]
        }
        return snap.values
    }

    public static func deleteUserConfig(pluginId: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: OsaurusPaths.claudePluginUserConfigFile(for: pluginId))
    }

    // MARK: - data directory helpers

    /// Return `~/.osaurus/claude-plugins/data/<safeId>/`, creating it on
    /// first access. Designed to be called by
    /// `ClaudePluginVariableExpander` whenever a substitution actually
    /// resolves a `${CLAUDE_PLUGIN_DATA}` token.
    @discardableResult
    public static func ensureDataDir(for pluginId: String) -> URL {
        let url = OsaurusPaths.claudePluginDataDir(for: pluginId)
        OsaurusPaths.ensureExistsSilent(url)
        return url
    }

    /// Current size of the plugin's data dir in bytes, or 0 when missing.
    public static func dataDirSize(for pluginId: String) -> Int {
        let url = OsaurusPaths.claudePluginDataDir(for: pluginId)
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return OsaurusPaths.directorySize(at: url)
    }
}
