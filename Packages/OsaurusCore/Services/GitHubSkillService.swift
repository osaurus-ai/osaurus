//
//  GitHubSkillService.swift
//  osaurus
//
//  Service for importing skills from GitHub repositories.
//  Supports repositories with .claude-plugin/marketplace.json format.
//

import Foundation
import OsaurusRepository

// MARK: - Models

/// Represents a GitHub repository reference
public struct GitHubRepo: Sendable {
    public let owner: String
    public let name: String
    public let branch: String

    public init(owner: String, name: String, branch: String = "main") {
        self.owner = owner
        self.name = name
        self.branch = branch
    }

    /// Raw content URL base
    public var rawBaseURL: String {
        "https://raw.githubusercontent.com/\(owner)/\(name)/\(branch)"
    }

    /// GitHub API URL for repo info
    public var apiURL: String {
        "https://api.github.com/repos/\(owner)/\(name)"
    }
}

/// Marketplace.json owner field
public struct MarketplaceOwner: Codable, Sendable {
    public let name: String?
    public let url: String?
}

/// Marketplace.json metadata field
public struct MarketplaceMetadata: Codable, Sendable {
    public let description: String?
    public let version: String?
    public let repository: String?
}

/// Where a plugin's content actually lives.
///
/// `marketplace.json` files in the wild use one of three shapes for `source`:
///   - A path string `"./<dir>"` (claude-for-legal, knowledge-work-plugins,
///     financial-services).
///   - An object `{ "source": "url", "url": "https://github.com/...", "sha": "..." }`
///     pointing to an entire external repo (claude-plugins-community).
///   - An object `{ "source": "git-subdir", "url": "owner/repo", "path": "...",
///     "ref": "main", "sha": "..." }` pointing to a sub-path inside an external
///     repo (claude-plugins-community).
public enum MarketplaceSource: Sendable {
    /// Plugin content lives at `<relativeDirectory>` inside the marketplace repo.
    case localDirectory(String)
    /// Plugin content is an entire external repo, pinned at `ref` (sha or ref).
    case externalRepo(GitHubRepo, ref: String?)
    /// Plugin content is at `path` inside an external repo, pinned at `ref`.
    case externalSubdir(GitHubRepo, path: String, ref: String?)

    private enum ObjectKey: String, CodingKey {
        case source, url, sha, ref, path
        // Aliases used by some marketplace entries (e.g. `fullstory`,
        // `jfrog` in claude-plugins-official) that ship `repo`/`commit`
        // instead of `url`/`sha`.
        case repo, commit
    }

    /// Hand-rolled decode: try `String` first (legacy shape), fall back to the
    /// object form keyed by an inner `"source"` discriminator.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
            let str = try? single.decode(String.self)
        {
            self = .localDirectory(str)
            return
        }
        let container = try decoder.container(keyedBy: ObjectKey.self)
        let kind = (try? container.decode(String.self, forKey: .source)) ?? "url"
        // Accept `url` or its `repo` alias (bare `owner/repo` slug).
        let urlValue = try? container.decode(String.self, forKey: .url)
        let repoValue = try? container.decode(String.self, forKey: .repo)
        guard let urlOrSlug = urlValue ?? repoValue else {
            throw DecodingError.dataCorruptedError(
                forKey: .url,
                in: container,
                debugDescription: "MarketplaceSource object requires `url` or `repo`"
            )
        }
        // Prefer `sha`, then its `commit` alias, then `ref`.
        let sha =
            (try? container.decode(String.self, forKey: .sha))
            ?? (try? container.decode(String.self, forKey: .commit))
        let ref = try? container.decode(String.self, forKey: .ref)
        let path = try? container.decode(String.self, forKey: .path)
        // Prefer a pinned sha over a moving ref for reproducibility.
        let pinned = sha ?? ref
        guard let parsed = Self.parseRepoURL(urlOrSlug) else {
            throw DecodingError.dataCorruptedError(
                forKey: .url,
                in: container,
                debugDescription: "Could not parse repo url/slug: \(urlOrSlug)"
            )
        }
        // GitHubRepo.branch is what we pass to raw.githubusercontent.com as
        // the ref, so an opaque SHA works just as well as a branch name.
        let repo = GitHubRepo(
            owner: parsed.owner,
            name: parsed.name,
            branch: pinned ?? parsed.branch
        )
        switch kind {
        case "git-subdir":
            guard let path = path, !path.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: "git-subdir requires `path`"
                )
            }
            self = .externalSubdir(repo, path: path, ref: pinned)
        case "url", "github", "":
            self = .externalRepo(repo, ref: pinned)
        default:
            // Unknown discriminator → fall through to "external repo" so we
            // make a best-effort attempt rather than failing the whole file.
            self = .externalRepo(repo, ref: pinned)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .localDirectory(let str):
            var c = encoder.singleValueContainer()
            try c.encode(str)
        case .externalRepo(let repo, let ref):
            var c = encoder.container(keyedBy: ObjectKey.self)
            try c.encode("url", forKey: .source)
            try c.encode("https://github.com/\(repo.owner)/\(repo.name).git", forKey: .url)
            if let ref = ref { try c.encode(ref, forKey: .ref) }
        case .externalSubdir(let repo, let path, let ref):
            var c = encoder.container(keyedBy: ObjectKey.self)
            try c.encode("git-subdir", forKey: .source)
            try c.encode("\(repo.owner)/\(repo.name)", forKey: .url)
            try c.encode(path, forKey: .path)
            if let ref = ref { try c.encode(ref, forKey: .ref) }
        }
    }

    /// Parse an `https://github.com/owner/repo.git` URL or a bare `owner/repo`
    /// slug into a `GitHubRepo` with branch defaulting to `main`.
    private static func parseRepoURL(_ urlOrSlug: String) -> GitHubRepo? {
        var s = urlOrSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        while s.hasSuffix("/") { s = String(s.dropLast()) }

        var components: [String] = []
        if s.contains("github.com") {
            if let url = URL(string: s.hasPrefix("http") ? s : "https://\(s)") {
                components = url.pathComponents.filter { $0 != "/" }
            } else {
                let parts = s.components(separatedBy: "github.com/")
                if parts.count == 2 {
                    components = parts[1].components(separatedBy: "/")
                }
            }
        } else if s.contains("/") {
            components = s.components(separatedBy: "/")
        }

        guard components.count >= 2, !components[0].isEmpty, !components[1].isEmpty else {
            return nil
        }
        return GitHubRepo(owner: components[0], name: components[1], branch: "main")
    }
}

extension MarketplaceSource: Codable {}

/// Marketplace.json plugin definition.
///
/// Supports three schemas:
/// - Legacy flat: declares `skills: [String]` listing SKILL.md paths.
/// - Directory-based: declares `source: "./<dir>"` and skills/agents/commands/MCP
///   servers are discovered by directory convention.
/// - Source-as-object: declares `source: { source: "url"|"git-subdir", url: ..., sha: ... }`
///   pointing to an external repo (used by claude-plugins-community).
public struct MarketplacePlugin: Codable, Sendable {
    public let name: String
    public let description: String?
    public let source: MarketplaceSource?
    public let strict: Bool?
    public let skills: [String]?
    public let author: MarketplaceOwner?
    /// Optional `version` field declared on the marketplace entry itself.
    /// Falls back to `plugin.json.version` per the spec resolution order
    /// (see `ClaudePluginVersionResolver`).
    public let version: String?
    public let homepage: String?
    public let repository: String?
    public let license: String?
    public let keywords: [String]?
    /// Discovery category declared on the marketplace entry (e.g.
    /// `development`, `productivity`, `database`). Drives the browse-tab
    /// category chips. `nil` when the entry omits it.
    public let category: String?

    public init(
        name: String,
        description: String? = nil,
        source: MarketplaceSource? = nil,
        strict: Bool? = nil,
        skills: [String]? = nil,
        author: MarketplaceOwner? = nil,
        version: String? = nil,
        homepage: String? = nil,
        repository: String? = nil,
        license: String? = nil,
        keywords: [String]? = nil,
        category: String? = nil
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.strict = strict
        self.skills = skills
        self.author = author
        self.version = version
        self.homepage = homepage
        self.repository = repository
        self.license = license
        self.keywords = keywords
        self.category = category
    }
}

/// Decodes `T` but never throws — a failed element yields `nil`. Used to make
/// array decoding resilient so one malformed entry can't fail the whole list.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}

/// Root marketplace.json structure
public struct GitHubMarketplace: Codable, Sendable {
    public let name: String
    public let owner: MarketplaceOwner?
    public let metadata: MarketplaceMetadata?
    public let plugins: [MarketplacePlugin]

    public init(
        name: String,
        owner: MarketplaceOwner?,
        metadata: MarketplaceMetadata?,
        plugins: [MarketplacePlugin]
    ) {
        self.name = name
        self.owner = owner
        self.metadata = metadata
        self.plugins = plugins
    }

    private enum CodingKeys: String, CodingKey {
        case name, owner, metadata, plugins
    }

    /// Lossy decode for `plugins`: entries that fail to decode (e.g. a future
    /// `source` shape we don't understand) are skipped rather than failing the
    /// entire catalog. The official marketplace ships 200+ entries; losing one
    /// must not blank out the whole Browse grid.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
        self.owner = try? container.decode(MarketplaceOwner.self, forKey: .owner)
        self.metadata = try? container.decode(MarketplaceMetadata.self, forKey: .metadata)
        let lossy =
            (try? container.decode([FailableDecodable<MarketplacePlugin>].self, forKey: .plugins))
            ?? []
        self.plugins = lossy.compactMap { $0.value }
    }
}

/// Preview of a skill available for import
public struct GitHubSkillPreview: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let displayName: String
    public let pluginName: String
    public let pluginDescription: String?

    public init(path: String, pluginName: String, pluginDescription: String?) {
        self.id = path
        self.path = path
        self.pluginName = pluginName
        self.pluginDescription = pluginDescription

        // Convert path like "./skills/copywriting" to "Copywriting"
        let name =
            path
            .replacingOccurrences(of: "./", with: "")
            .components(separatedBy: "/")
            .last ?? path

        self.displayName =
            name
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Result of fetching a GitHub repository's skills
public struct GitHubSkillsResult: Sendable {
    public let repo: GitHubRepo
    public let marketplace: GitHubMarketplace
    public let skills: [GitHubSkillPreview]

    public var repoName: String { marketplace.name }
    public var repoDescription: String? { marketplace.metadata?.description }
    public var ownerName: String? { marketplace.owner?.name }
}

// MARK: - Claude Plugin Manifest

/// A discovered SKILL.md path inside a plugin.
public struct ClaudeSkillEntry: Sendable, Hashable {
    public let path: String  // path to the skill directory (e.g. "commercial-legal/skills/review")
    public let displayName: String

    public init(path: String) {
        self.path = path
        let leaf =
            path
            .components(separatedBy: "/")
            .last ?? path
        self.displayName =
            leaf
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// A discovered scheduled-agent markdown file inside a plugin.
public struct ClaudeAgentEntry: Sendable, Hashable {
    public let path: String  // path to the .md file
    public let displayName: String

    public init(path: String) {
        self.path = path
        let file = (path as NSString).lastPathComponent
        let stem = (file as NSString).deletingPathExtension
        self.displayName =
            stem
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// A discovered slash-command markdown file inside a plugin.
public struct ClaudeCommandEntry: Sendable, Hashable {
    public let path: String  // path to the .md file
    public let displayName: String

    public init(path: String) {
        self.path = path
        let file = (path as NSString).lastPathComponent
        let stem = (file as NSString).deletingPathExtension
        self.displayName = stem
    }
}

/// A manifest of every importable artifact discovered for a single plugin.
public struct ClaudePluginManifest: Sendable {
    public let name: String
    public let description: String?
    public let source: String  // root path inside `sourceRepo` (e.g. "commercial-legal")
    /// Repo that hosts this plugin's files. For `localDirectory` sources this
    /// is the marketplace repo itself; for `externalRepo` / `externalSubdir`
    /// this points at the external repo, pinned at the declared sha or ref.
    public let sourceRepo: GitHubRepo
    public let authorName: String?
    public let skills: [ClaudeSkillEntry]
    public let agents: [ClaudeAgentEntry]
    public let commands: [ClaudeCommandEntry]
    /// Kept for backwards compatibility — equals the first entry of
    /// `auxMarkdownPaths` when a CLAUDE.md was found.
    public let claudeMdPath: String?
    /// Every auxiliary markdown file we picked up at the plugin root
    /// (CLAUDE.md, CONNECTORS.md, README.md). Attached to imported skills as
    /// references so SKILL.md cross-references like `[CONNECTORS.md](../../CONNECTORS.md)`
    /// can resolve locally.
    public let auxMarkdownPaths: [String]
    public let mcpJsonPath: String?
    /// True when the plugin came from a legacy marketplace.json (`skills: [String]`).
    /// In that case only `skills` is populated.
    public let isLegacy: Bool

    // MARK: - Spec fields lifted from `.claude-plugin/plugin.json`
    //
    // All optional: legacy marketplaces and plugins without a per-plugin
    // `plugin.json` keep working with these nil. The installer treats
    // `displayName` as falling back to `name`, `version` as resolving via
    // the precedence list in `resolvedVersion`, and `keywords/license/...`
    // as purely display-side metadata.

    /// Human-readable name. Falls back to `name` when omitted.
    public let displayName: String?
    /// Pinned version per spec resolution (plugin.json > marketplace > git SHA).
    /// `nil` only when none of the three sources had a value.
    public let version: String?
    public let authorEmail: String?
    public let authorURL: String?
    public let homepage: String?
    public let repository: String?
    public let license: String?
    public let keywords: [String]
    public let userConfigSpec: [ClaudePluginUserConfigField]
    /// Explicit `dependencies` array from `plugin.json` (vs the body-scan
    /// heuristic). Stored but not yet honored (see `dependencies` in plan).
    public let declaredDependencies: [String]
    /// True when the plugin declared `hooks` (any shape). We don't execute
    /// hooks yet — the detail view surfaces this so users know.
    public let declaresHooks: Bool
    /// True when the plugin declared `monitors` / `lspServers` / `themes`
    /// / `outputStyles` / `bin/` (collectively the things we don't run yet).
    public let declaresUnsupportedComponents: [String]

    public init(
        name: String,
        description: String?,
        source: String,
        sourceRepo: GitHubRepo,
        authorName: String? = nil,
        skills: [ClaudeSkillEntry] = [],
        agents: [ClaudeAgentEntry] = [],
        commands: [ClaudeCommandEntry] = [],
        claudeMdPath: String? = nil,
        auxMarkdownPaths: [String] = [],
        mcpJsonPath: String? = nil,
        isLegacy: Bool = false,
        displayName: String? = nil,
        version: String? = nil,
        authorEmail: String? = nil,
        authorURL: String? = nil,
        homepage: String? = nil,
        repository: String? = nil,
        license: String? = nil,
        keywords: [String] = [],
        userConfigSpec: [ClaudePluginUserConfigField] = [],
        declaredDependencies: [String] = [],
        declaresHooks: Bool = false,
        declaresUnsupportedComponents: [String] = []
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.sourceRepo = sourceRepo
        self.authorName = authorName
        self.skills = skills
        self.agents = agents
        self.commands = commands
        self.claudeMdPath = claudeMdPath
        self.auxMarkdownPaths = auxMarkdownPaths
        self.mcpJsonPath = mcpJsonPath
        self.isLegacy = isLegacy
        self.displayName = displayName
        self.version = version
        self.authorEmail = authorEmail
        self.authorURL = authorURL
        self.homepage = homepage
        self.repository = repository
        self.license = license
        self.keywords = keywords
        self.userConfigSpec = userConfigSpec
        self.declaredDependencies = declaredDependencies
        self.declaresHooks = declaresHooks
        self.declaresUnsupportedComponents = declaresUnsupportedComponents
    }

    /// User-facing display name. Falls back to `name`.
    public var resolvedDisplayName: String { displayName ?? name }

    /// True when there is anything importable beyond skills.
    public var hasNonSkillArtifacts: Bool {
        !agents.isEmpty || !commands.isEmpty || claudeMdPath != nil || mcpJsonPath != nil
            || !auxMarkdownPaths.isEmpty
    }

    /// True when the plugin ships at least one component Osaurus can actually
    /// import: a skill, agent, command, or MCP server. Plugins composed only
    /// of `hooks` / `outputStyles` / `monitors` / `lspServers` / `themes` /
    /// `bin` resolve to `false` here — there's nothing for Osaurus to install.
    /// Auxiliary markdown (CLAUDE.md/README) does NOT count, since those are
    /// only attached as references to skills that get imported.
    public var hasImportableComponents: Bool {
        !skills.isEmpty || !agents.isEmpty || !commands.isEmpty || mcpJsonPath != nil
    }
}

/// One entry in a plugin's `userConfig` block. Mirrors the schema documented
/// at https://code.claude.com/docs/en/plugins-reference#user-configuration
public struct ClaudePluginUserConfigField: Codable, Sendable, Hashable {
    public enum FieldType: String, Codable, Sendable {
        case string
        case number
        case boolean
        case directory
        case file
    }

    public let key: String
    public let type: FieldType
    public let title: String
    public let description: String
    public let sensitive: Bool
    public let required: Bool
    public let defaultValue: String?
    /// For `string`, allow an array of values rather than a single one.
    public let multiple: Bool
    public let min: Double?
    public let max: Double?

    public init(
        key: String,
        type: FieldType,
        title: String,
        description: String,
        sensitive: Bool = false,
        required: Bool = false,
        defaultValue: String? = nil,
        multiple: Bool = false,
        min: Double? = nil,
        max: Double? = nil
    ) {
        self.key = key
        self.type = type
        self.title = title
        self.description = description
        self.sensitive = sensitive
        self.required = required
        self.defaultValue = defaultValue
        self.multiple = multiple
        self.min = min
        self.max = max
    }
}

/// Decoded shape of `.claude-plugin/plugin.json`. Unknown top-level keys are
/// ignored per the spec ("Unrecognized fields"). The decoder is *defensive*:
/// fields with the wrong type are dropped instead of failing the whole file,
/// because the only thing the installer truly needs is the manifest from
/// `marketplace.json` — `plugin.json` is purely additive metadata.
public struct ClaudePluginJSON: Sendable {
    public let name: String?
    public let displayName: String?
    public let version: String?
    public let description: String?
    public let authorName: String?
    public let authorEmail: String?
    public let authorURL: String?
    public let homepage: String?
    public let repository: String?
    public let license: String?
    public let keywords: [String]
    public let userConfig: [ClaudePluginUserConfigField]
    public let declaredDependencies: [String]
    public let hasHooks: Bool
    public let unsupportedComponents: [String]

    /// Parse a `plugin.json` payload tolerantly. Returns `nil` on malformed
    /// JSON; otherwise extracts whatever recognised fields are present and
    /// silently drops the rest.
    public static func parse(_ raw: String) -> ClaudePluginJSON? {
        guard let data = raw.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let name = root["name"] as? String
        let displayName = root["displayName"] as? String
        let version = root["version"] as? String
        let description = root["description"] as? String

        var authorName: String? = nil
        var authorEmail: String? = nil
        var authorURL: String? = nil
        if let author = root["author"] as? [String: Any] {
            authorName = author["name"] as? String
            authorEmail = author["email"] as? String
            authorURL = author["url"] as? String
        } else if let authorStr = root["author"] as? String {
            authorName = authorStr
        }

        let homepage = root["homepage"] as? String
        let repository = root["repository"] as? String
        let license = root["license"] as? String

        let keywords: [String] = (root["keywords"] as? [String]) ?? []

        let userConfig = Self.parseUserConfig(root["userConfig"])
        let declaredDependencies = Self.parseDependencies(root["dependencies"])

        // Hooks may show up as an object, an array, or a path string. We
        // treat any of them as "declares hooks". The installer just surfaces
        // this — it doesn't execute them yet.
        let hasHooks = root["hooks"] != nil

        var unsupported: [String] = []
        if root["lspServers"] != nil { unsupported.append("lspServers") }
        if root["outputStyles"] != nil { unsupported.append("outputStyles") }
        if root["channels"] != nil { unsupported.append("channels") }
        if let experimental = root["experimental"] as? [String: Any] {
            if experimental["themes"] != nil { unsupported.append("themes") }
            if experimental["monitors"] != nil { unsupported.append("monitors") }
        }

        return ClaudePluginJSON(
            name: name,
            displayName: displayName,
            version: version,
            description: description,
            authorName: authorName,
            authorEmail: authorEmail,
            authorURL: authorURL,
            homepage: homepage,
            repository: repository,
            license: license,
            keywords: keywords,
            userConfig: userConfig,
            declaredDependencies: declaredDependencies,
            hasHooks: hasHooks,
            unsupportedComponents: unsupported
        )
    }

    private static func parseUserConfig(_ value: Any?) -> [ClaudePluginUserConfigField] {
        guard let dict = value as? [String: Any] else { return [] }
        var out: [ClaudePluginUserConfigField] = []
        for (key, entryAny) in dict {
            guard let entry = entryAny as? [String: Any] else { continue }
            let typeStr = (entry["type"] as? String) ?? "string"
            let type = ClaudePluginUserConfigField.FieldType(rawValue: typeStr) ?? .string
            let title = (entry["title"] as? String) ?? key
            let description = (entry["description"] as? String) ?? ""
            let sensitive = (entry["sensitive"] as? Bool) ?? false
            let required = (entry["required"] as? Bool) ?? false
            let multiple = (entry["multiple"] as? Bool) ?? false
            var defaultValue: String? = nil
            if let s = entry["default"] as? String {
                defaultValue = s
            } else if let n = entry["default"] as? NSNumber {
                defaultValue = n.stringValue
            } else if let b = entry["default"] as? Bool {
                defaultValue = b ? "true" : "false"
            }
            let minV =
                (entry["min"] as? Double)
                ?? (entry["min"] as? NSNumber).map { $0.doubleValue }
            let maxV =
                (entry["max"] as? Double)
                ?? (entry["max"] as? NSNumber).map { $0.doubleValue }
            out.append(
                ClaudePluginUserConfigField(
                    key: key,
                    type: type,
                    title: title,
                    description: description,
                    sensitive: sensitive,
                    required: required,
                    defaultValue: defaultValue,
                    multiple: multiple,
                    min: minV,
                    max: maxV
                )
            )
        }
        return out.sorted { $0.key < $1.key }
    }

    private static func parseDependencies(_ value: Any?) -> [String] {
        guard let arr = value as? [Any] else { return [] }
        var out: [String] = []
        for entry in arr {
            if let s = entry as? String {
                out.append(s)
            } else if let dict = entry as? [String: Any],
                let name = dict["name"] as? String
            {
                out.append(name)
            }
        }
        return out
    }
}

/// Result of fetching a GitHub repository's full plugin manifests.
public struct GitHubPluginsResult: Sendable {
    public let repo: GitHubRepo
    public let marketplace: GitHubMarketplace
    public let plugins: [ClaudePluginManifest]

    public var repoName: String { marketplace.name }
    public var repoDescription: String? { marketplace.metadata?.description }
    public var ownerName: String? { marketplace.owner?.name }
    public var totalSkillCount: Int { plugins.reduce(0) { $0 + $1.skills.count } }

    /// True when every plugin uses the legacy `skills: [String]` schema (no agents,
    /// commands, CLAUDE.md, or `.mcp.json` discovered). UI can fall back to the
    /// older flat skill picker.
    public var isLegacyOnly: Bool {
        plugins.allSatisfy { $0.isLegacy && !$0.hasNonSkillArtifacts }
    }
}

/// Lightweight result of fetching just a repo's `marketplace.json` without
/// resolving each plugin's full manifest. Used by the browse/discovery grid
/// where rendering 200+ entries should cost a single network request — the
/// per-plugin `buildManifest` round-trips only happen at install time.
public struct MarketplaceCatalog: Sendable {
    public let repo: GitHubRepo
    public let marketplace: GitHubMarketplace

    public init(repo: GitHubRepo, marketplace: GitHubMarketplace) {
        self.repo = repo
        self.marketplace = marketplace
    }

    public var entries: [MarketplacePlugin] { marketplace.plugins }
}

/// Sibling-plugin dependency map computed by `resolvePluginDependencies(_:)`.
///
/// Each key is a plugin name; the value is the set of *other* plugins it
/// depends on (because one of its agents invokes a skill that lives in those
/// plugins). The picker uses this to auto-select cross-plugin dependencies
/// when the user toggles a parent plugin on — so e.g. selecting `pitch-agent`
/// in `anthropics/financial-services` also selects `financial-analysis`.
public struct PluginDependencyGraph: Sendable {
    public let dependencies: [String: Set<String>]

    public init(dependencies: [String: Set<String>]) {
        self.dependencies = dependencies
    }

    /// All dependencies of `plugin`, including transitive ones, *excluding*
    /// `plugin` itself. Returns an empty set if there are no dependencies.
    public func transitiveDependencies(of plugin: String) -> Set<String> {
        var out = Set<String>()
        var stack = [plugin]
        while let next = stack.popLast() {
            for dep in dependencies[next] ?? [] where !out.contains(dep) && dep != plugin {
                out.insert(dep)
                stack.append(dep)
            }
        }
        return out
    }
}

/// Minimal `contents` API entry. We only need name / path / type / size.
public struct GitHubTreeEntry: Decodable, Sendable {
    public let name: String
    public let path: String
    public let type: String  // "dir" or "file"
    /// File size in bytes (GitHub contents API). `nil` / 0 for directories.
    public let size: Int?

    public init(name: String, path: String, type: String, size: Int? = nil) {
        self.name = name
        self.path = path
        self.type = type
        self.size = size
    }
}

/// One file inside (or under) a skill directory on GitHub. Carries the
/// `relativePath` from the skill's own root so the installer can stash it
/// under `references/` or `assets/` with a predictable name.
public struct GitHubSkillAsset: Sendable {
    public let path: String  // full path within the repo
    public let relativePath: String  // path relative to the skill dir
    public let size: Int

    public init(path: String, relativePath: String, size: Int) {
        self.path = path
        self.relativePath = relativePath
        self.size = size
    }
}

// MARK: - Errors

public enum GitHubSkillError: Error, LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case notFound
    case noMarketplaceFile
    case invalidMarketplace(String)
    case noSkillsFound
    case skillFetchFailed(String, Error)
    case branchNotFound
    /// Hit GitHub's unauthenticated rate limit (60 req/hour per IP). The
    /// optional date carries the `X-RateLimit-Reset` value so the UI can
    /// tell the user when to try again.
    case rateLimited(resetAt: Date?)
    /// The plugin resolved cleanly but ships nothing Osaurus can import
    /// (only hooks / output styles / monitors / etc.). Carries the plugin
    /// name so the UI can name it in the message.
    case noImportableComponents(pluginName: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid GitHub URL: \(url)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .notFound:
            return "Repository not found"
        case .noMarketplaceFile:
            return "No .claude-plugin/marketplace.json found in this repository"
        case .invalidMarketplace(let reason):
            return "Invalid marketplace.json: \(reason)"
        case .noSkillsFound:
            return "No skills found in the repository"
        case .skillFetchFailed(let name, let error):
            return "Failed to fetch skill '\(name)': \(error.localizedDescription)"
        case .branchNotFound:
            return "Could not determine the default branch"
        case .rateLimited(let resetAt):
            // #1719: when no token is configured we're on the 60/hr anonymous
            // limit; tell the user how to raise it instead of only "wait an hour"
            // (which, for a large repo, never finishes anyway).
            let tokenHint =
                GitHubSkillService.gitHubToken() == nil
                ? " Set GITHUB_TOKEN or GH_TOKEN to raise the limit to 5,000/hr."
                : ""
            if let resetAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                let when = formatter.localizedString(for: resetAt, relativeTo: Date())
                return "GitHub rate-limited this app. Try again \(when).\(tokenHint)"
            }
            return "GitHub rate-limited this app. Wait an hour to retry.\(tokenHint)"
        case .noImportableComponents(let pluginName):
            return
                "\(pluginName) has no components Osaurus can import (it only ships hooks, output styles, or other unsupported parts)."
        }
    }
}

// MARK: - Service

@MainActor
public final class GitHubSkillService: ObservableObject {
    public static let shared = GitHubSkillService()

    @Published public var isLoading = false
    @Published public var error: GitHubSkillError?

    private let session: URLSession

    private init() {
        self.session = Self.makeSession()
    }

    nonisolated static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        // Optional GitHub auth (#1719): unauthenticated GitHub is capped at
        // 60 req/hr per IP, so importing a large plugin/skill repo (e.g.
        // anthropics/knowledge-work-plugins, ~200 SKILL.md across ~22 plugins)
        // fans out enough Contents-API calls to trip a 403 mid-enumeration and
        // never completes. Attach a token when GITHUB_TOKEN / GH_TOKEN is set to
        // raise the limit to 5,000/hr. Absent ⇒ byte-identical prior behavior.
        // This session is dedicated to GitHubSkillService and only contacts
        // GitHub-controlled hosts (api.github.com / *.githubusercontent.com), so
        // the header stays on GitHub. The token is never logged or surfaced in
        // any error string.
        if let token = Self.gitHubToken() {
            var headers = config.httpAdditionalHeaders ?? [:]
            headers["Authorization"] = "Bearer \(token)"
            config.httpAdditionalHeaders = headers
        }
        return GlobalProxySettings.makeSession(base: config)
    }

    /// A GitHub API token from the process environment, if present and
    /// non-empty. Never logged. Honors GITHUB_TOKEN then GH_TOKEN.
    nonisolated static func gitHubToken() -> String? {
        gitHubToken(from: ProcessInfo.processInfo.environment)
    }

    /// Pure token resolution over an explicit environment, so the precedence
    /// and trimming rules are unit-testable without mutating the process env.
    /// GITHUB_TOKEN wins over GH_TOKEN; values are whitespace-trimmed; blank or
    /// whitespace-only values are treated as absent.
    nonisolated static func gitHubToken(from env: [String: String]) -> String? {
        for key in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        return nil
    }

    // MARK: - URL Parsing

    /// Parse a GitHub URL to extract owner and repo.
    ///
    /// Supports formats:
    /// - `https://github.com/owner/repo`
    /// - `https://github.com/owner/repo.git`
    /// - `github.com/owner/repo`
    /// - `owner/repo`
    public func parseGitHubURL(_ urlString: String) throws -> GitHubRepo {
        var cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove .git suffix if present
        if cleaned.hasSuffix(".git") {
            cleaned = String(cleaned.dropLast(4))
        }

        // Remove trailing slashes
        while cleaned.hasSuffix("/") {
            cleaned = String(cleaned.dropLast())
        }

        // Handle different URL formats
        var pathComponents: [String] = []

        if cleaned.contains("github.com") {
            // Full URL format
            if let url = URL(string: cleaned.hasPrefix("http") ? cleaned : "https://\(cleaned)") {
                pathComponents = url.pathComponents.filter { $0 != "/" }
            } else {
                // Try parsing as path
                let parts = cleaned.components(separatedBy: "github.com/")
                if parts.count == 2 {
                    pathComponents = parts[1].components(separatedBy: "/")
                }
            }
        } else if cleaned.contains("/") {
            // owner/repo format
            pathComponents = cleaned.components(separatedBy: "/")
        }

        // We need at least owner and repo
        guard pathComponents.count >= 2 else {
            throw GitHubSkillError.invalidURL(urlString)
        }

        let owner = pathComponents[0]
        let repo = pathComponents[1]

        guard !owner.isEmpty, !repo.isEmpty else {
            throw GitHubSkillError.invalidURL(urlString)
        }

        return GitHubRepo(owner: owner, name: repo)
    }

    // MARK: - Fetching

    /// Fetch available skills from a GitHub repository (legacy flat-skills API).
    ///
    /// Kept for backward compatibility — for full plugin discovery (new-style
    /// repos like `anthropics/claude-for-legal`) prefer `fetchPlugins(from:)`.
    public func fetchSkills(from urlString: String) async throws -> GitHubSkillsResult {
        isLoading = true
        error = nil

        defer { isLoading = false }

        do {
            // Parse the URL
            var repo = try parseGitHubURL(urlString)

            // Try to detect the default branch
            repo = try await detectDefaultBranch(repo)

            // Fetch marketplace.json
            let marketplace = try await fetchMarketplace(repo)

            // Extract skills. For legacy plugins we have the array directly;
            // for new-style plugins fall back to directory discovery so the
            // existing flat picker keeps working.
            //
            // Note: the legacy "flat picker" path can't surface external-
            // source plugins because it doesn't carry the source repo.
            // Anything with a `MarketplaceSource.externalRepo` /
            // `.externalSubdir` source falls through `fetchPlugins(from:)`
            // instead — `isLegacyOnly` is false for those repos so callers
            // never land here.
            var skills: [GitHubSkillPreview] = []
            for plugin in marketplace.plugins {
                let skillPaths: [String]
                if let declared = plugin.skills, !declared.isEmpty {
                    skillPaths = declared
                } else if case .localDirectory(let source) = plugin.source {
                    let discovered = try await discoverSkillDirectories(repo: repo, source: source)
                    skillPaths = discovered.map { $0.path }
                } else {
                    skillPaths = []
                }

                for skillPath in skillPaths {
                    let preview = GitHubSkillPreview(
                        path: skillPath,
                        pluginName: plugin.name,
                        pluginDescription: plugin.description
                    )
                    skills.append(preview)
                }
            }

            guard !skills.isEmpty else {
                throw GitHubSkillError.noSkillsFound
            }

            return GitHubSkillsResult(
                repo: repo,
                marketplace: marketplace,
                skills: skills
            )
        } catch let err as GitHubSkillError {
            error = err
            throw err
        } catch {
            let skillError = GitHubSkillError.networkError(error)
            self.error = skillError
            throw skillError
        }
    }

    /// Fetch full plugin manifests from a GitHub repository.
    ///
    /// For each plugin in `marketplace.json`, discovers skills, scheduled agents,
    /// slash commands, CLAUDE.md, and `.mcp.json` by listing the plugin's source
    /// directory via the GitHub Contents API. Falls back to the declared
    /// `skills: [String]` array for legacy marketplaces.
    ///
    /// Plugin manifests are discovered concurrently — for a marketplace with
    /// N plugins this collapses ~5N sequential GETs into one parallel batch,
    /// which is the difference between an instant picker and ~10 seconds of
    /// dead air for repos like `anthropics/claude-for-legal`.
    public func fetchPlugins(from urlString: String) async throws -> GitHubPluginsResult {
        isLoading = true
        error = nil

        defer { isLoading = false }

        do {
            var repo = try parseGitHubURL(urlString)
            repo = try await detectDefaultBranch(repo)

            let marketplace = try await fetchMarketplace(repo)

            // Capture the data we need explicitly so the closure body is
            // free of any MainActor-isolated captures. `buildManifest` is
            // `nonisolated` and its inputs are `Sendable`.
            let repoForTasks = repo
            let plugins = marketplace.plugins
            let manifests = try await withThrowingTaskGroup(
                of: (Int, ClaudePluginManifest).self
            ) { [weak self] group -> [ClaudePluginManifest] in
                guard let self else { return [] }
                for (index, plugin) in plugins.enumerated() {
                    let pluginCopy = plugin
                    let repoCopy = repoForTasks
                    group.addTask {
                        let manifest = try await self.buildManifest(
                            rootRepo: repoCopy,
                            plugin: pluginCopy
                        )
                        return (index, manifest)
                    }
                }
                var collected: [(Int, ClaudePluginManifest)] = []
                for try await pair in group {
                    collected.append(pair)
                }
                // Preserve marketplace.json declaration order so the UI is
                // deterministic regardless of which fetch finished first.
                return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
            }

            let hasAnything = manifests.contains { !$0.skills.isEmpty || $0.hasNonSkillArtifacts }
            guard hasAnything else {
                throw GitHubSkillError.noSkillsFound
            }

            return GitHubPluginsResult(
                repo: repo,
                marketplace: marketplace,
                plugins: manifests
            )
        } catch let err as GitHubSkillError {
            error = err
            throw err
        } catch {
            let skillError = GitHubSkillError.networkError(error)
            self.error = skillError
            throw skillError
        }
    }

    /// Fetch just the repo's `marketplace.json` and return its entries
    /// without resolving each plugin's full manifest.
    ///
    /// This is the cheap path that powers the browse/discovery grid: the
    /// official `claude-plugins-official` marketplace lists 200+ plugins,
    /// each carrying enough metadata (name, description, author, category,
    /// homepage, source) to render a card. Resolving every manifest up front
    /// would fan out to ~9 round-trips per plugin and blow GitHub's
    /// unauthenticated rate limit, so `buildManifest` is deferred to install
    /// time via `resolveManifest(rootRepo:entry:)`.
    public func fetchMarketplaceCatalog(from urlString: String) async throws -> MarketplaceCatalog {
        do {
            var repo = try parseGitHubURL(urlString)
            repo = try await detectDefaultBranch(repo)
            let marketplace = try await fetchMarketplace(repo)
            return MarketplaceCatalog(repo: repo, marketplace: marketplace)
        } catch let err as GitHubSkillError {
            throw err
        } catch {
            throw GitHubSkillError.networkError(error)
        }
    }

    /// Resolve a single marketplace entry into a full `ClaudePluginManifest`.
    ///
    /// Wraps the private `buildManifest` so the browse grid can defer the
    /// expensive per-plugin directory probing until the user actually
    /// installs (or opens the detail for) one plugin.
    public func resolveManifest(
        rootRepo: GitHubRepo,
        entry: MarketplacePlugin
    ) async throws -> ClaudePluginManifest {
        try await buildManifest(rootRepo: rootRepo, plugin: entry)
    }

    /// Fetch the SKILL.md content for a specific skill
    public nonisolated func fetchSkillContent(from repo: GitHubRepo, skillPath: String) async throws -> String {
        // Clean up the path
        var cleanPath = skillPath
        if cleanPath.hasPrefix("./") {
            cleanPath = String(cleanPath.dropFirst(2))
        }

        return try await fetchFileContent(from: repo, path: "\(cleanPath)/SKILL.md")
    }

    /// Fetch any text file from the repo at `path`. Throws on 404 / network error.
    public nonisolated func fetchFileContent(from repo: GitHubRepo, path: String) async throws -> String {
        var cleanPath = path
        if cleanPath.hasPrefix("./") {
            cleanPath = String(cleanPath.dropFirst(2))
        }

        let fileURL = "\(repo.rawBaseURL)/\(cleanPath)"
        guard let url = URL(string: fileURL) else {
            throw GitHubSkillError.invalidURL(fileURL)
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubSkillError.networkError(NSError(domain: "HTTPError", code: -1))
        }

        if let rateLimit = rateLimitError(from: httpResponse) {
            throw rateLimit
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw GitHubSkillError.skillFetchFailed(
                    path,
                    NSError(
                        domain: "GitHubSkillService",
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "File not found"]
                    )
                )
            }
            throw GitHubSkillError.networkError(
                NSError(
                    domain: "HTTPError",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]
                )
            )
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw GitHubSkillError.skillFetchFailed(
                path,
                NSError(
                    domain: "GitHubSkillService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 content"]
                )
            )
        }

        return content
    }

    /// Fetch a file but return nil on 404 instead of throwing.
    public nonisolated func fetchOptionalFileContent(from repo: GitHubRepo, path: String) async -> String? {
        do {
            return try await fetchFileContent(from: repo, path: path)
        } catch {
            return nil
        }
    }

    /// Fetch multiple skills and return their markdown contents
    public func fetchMultipleSkills(
        from repo: GitHubRepo,
        skillPaths: [String],
        progressHandler: ((Int, Int) -> Void)? = nil
    ) async throws -> [(path: String, content: String)] {
        var results: [(path: String, content: String)] = []
        var errors: [(path: String, error: Error)] = []

        for (index, path) in skillPaths.enumerated() {
            progressHandler?(index + 1, skillPaths.count)

            do {
                let content = try await fetchSkillContent(from: repo, skillPath: path)
                results.append((path: path, content: content))
            } catch {
                errors.append((path: path, error: error))
            }
        }

        // If all failed, throw an error
        if results.isEmpty && !errors.isEmpty {
            let firstError = errors[0]
            throw GitHubSkillError.skillFetchFailed(firstError.path, firstError.error)
        }

        return results
    }

    // MARK: - Directory Listing

    /// List the contents of a directory in the repo via the GitHub Contents API.
    /// Returns nil on 404 (directory does not exist); throws on other errors.
    ///
    /// `nonisolated` so it can run concurrently from inside a `TaskGroup` —
    /// it only touches the `URLSession` (which is `Sendable`) and its
    /// `Sendable` inputs.
    public nonisolated func listDirectory(repo: GitHubRepo, path: String) async throws -> [GitHubTreeEntry]? {
        var clean = path
        if clean.hasPrefix("./") { clean = String(clean.dropFirst(2)) }
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard
            var components = URLComponents(
                string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)/contents/\(clean)"
            )
        else {
            throw GitHubSkillError.invalidURL(clean)
        }
        components.queryItems = [URLQueryItem(name: "ref", value: repo.branch)]

        guard let url = components.url else {
            throw GitHubSkillError.invalidURL(components.string ?? clean)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GitHubSkillError.networkError(NSError(domain: "HTTPError", code: -1))
        }

        if let rateLimit = rateLimitError(from: http) {
            throw rateLimit
        }

        switch http.statusCode {
        case 200:
            // A directory returns an array; a file returns a single object. We
            // only care about the array form.
            if let entries = try? JSONDecoder().decode([GitHubTreeEntry].self, from: data) {
                return entries
            }
            return []
        case 404:
            return nil
        default:
            throw GitHubSkillError.networkError(
                NSError(
                    domain: "HTTPError",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )
            )
        }
    }

    /// Discover `SKILL.md` directories under `<source>/skills/*` for a plugin
    /// that doesn't declare a flat `skills: [String]` array.
    private nonisolated func discoverSkillDirectories(repo: GitHubRepo, source: String) async throws
        -> [ClaudeSkillEntry]
    {
        let sourceClean = normalizedSource(source)
        // When `source` is empty (external repo at root) we just probe
        // `skills/` directly.
        let skillsDir = sourceClean.isEmpty ? "skills" : "\(sourceClean)/skills"

        guard let entries = try await listDirectory(repo: repo, path: skillsDir) else {
            return []
        }

        var result: [ClaudeSkillEntry] = []
        for entry in entries where entry.type == "dir" {
            // Keep the relative path so existing fetchSkillContent works:
            // it expects "<dir>/SKILL.md".
            result.append(ClaudeSkillEntry(path: entry.path))
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Tolerant discovery probes

    // Tolerate a missing directory (404 → none) but re-throw `.rateLimited`
    // so `fetchPlugins` surfaces it. Plain `try?` swallowed the 403 too,
    // making a throttled import silently report 0 skills.

    private nonisolated func discoverSkillDirectoriesTolerant(
        repo: GitHubRepo,
        source: String
    ) async throws -> [ClaudeSkillEntry] {
        do {
            return try await discoverSkillDirectories(repo: repo, source: source)
        } catch let error as GitHubSkillError {
            if case .rateLimited = error { throw error }
            return []
        } catch {
            return []
        }
    }

    private nonisolated func listDirectoryTolerant(
        repo: GitHubRepo,
        path: String
    ) async throws -> [GitHubTreeEntry]? {
        do {
            return try await listDirectory(repo: repo, path: path)
        } catch let error as GitHubSkillError {
            if case .rateLimited = error { throw error }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Sibling Dependency Resolution

    /// Walk every plugin's agent markdown files looking for references to
    /// sibling skills (`Invoke the \`comps-analysis\` skill`), and produce
    /// a dependency map keyed by plugin name. Used by the import picker to
    /// auto-select cross-plugin dependencies.
    ///
    /// Agent-body fetches are gated through the shared
    /// `GitHubFetchLimiter` so this never bursts past GitHub's
    /// unauthenticated rate limit even when called on a 20-plugin
    /// marketplace.
    public func resolvePluginDependencies(
        _ result: GitHubPluginsResult
    ) async -> PluginDependencyGraph {
        // 1. Index every skill name → which plugin owns it. Skill display
        // names look like "Comps Analysis"; the on-disk dir is
        // "comps-analysis". We match against the dir-style form because
        // that's what plugin authors use in backtick references.
        var ownersBySkillName: [String: String] = [:]
        for plugin in result.plugins {
            for skill in plugin.skills {
                let dirName = (skill.path as NSString).lastPathComponent
                let normalised = dirName.lowercased()
                ownersBySkillName[normalised] = plugin.name
            }
        }

        // 2. For every agent in every plugin, fetch its body and scan for
        // sibling skill references. Run in parallel under the shared
        // limiter; this is the main cost of this method.
        let limiter = GitHubFetchLimiter.shared
        let svc = self
        struct AgentTarget: Sendable {
            let pluginName: String
            let repo: GitHubRepo
            let path: String
        }
        var targets: [AgentTarget] = []
        for plugin in result.plugins {
            for agent in plugin.agents {
                targets.append(
                    AgentTarget(
                        pluginName: plugin.name,
                        repo: plugin.sourceRepo,
                        path: agent.path
                    )
                )
            }
        }

        let bodies: [(pluginName: String, body: String)] = await withTaskGroup(
            of: (String, String?).self
        ) { group in
            for target in targets {
                group.addTask {
                    let body = await limiter.runNoThrow {
                        await svc.fetchOptionalFileContent(from: target.repo, path: target.path)
                    }
                    return (target.pluginName, body)
                }
            }
            var out: [(String, String)] = []
            for await (pluginName, maybeBody) in group {
                if let body = maybeBody {
                    out.append((pluginName, body))
                }
            }
            return out
        }

        // 3. Walk the bodies, extract referenced skill names, look up
        // owning plugins. Skip the plugin's own skills so we don't say a
        // plugin depends on itself.
        var deps: [String: Set<String>] = [:]
        for (pluginName, body) in bodies {
            let referenced = ClaudePluginInstaller.extractSiblingSkillNames(from: body)
            var pluginDeps = deps[pluginName] ?? Set<String>()
            for name in referenced {
                if let owner = ownersBySkillName[name.lowercased()], owner != pluginName {
                    pluginDeps.insert(owner)
                }
            }
            if !pluginDeps.isEmpty {
                deps[pluginName] = pluginDeps
            }
        }

        return PluginDependencyGraph(dependencies: deps)
    }

    // MARK: - Skill Asset Discovery

    /// List every non-`SKILL.md` file inside a skill directory plus the
    /// conventional first-level subdirectories (`scripts/`, `references/`,
    /// `assets/`, `templates/`). Used by the installer to fetch co-located
    /// supporting files (Python helpers, requirements.txt, troubleshooting
    /// markdown, etc.) alongside the SKILL.md itself.
    ///
    /// Bounded to one level deep for each conventional subdir so we don't
    /// recurse into giant trees (e.g. a `references/data/...` corpus).
    public nonisolated func listSkillAssets(
        repo: GitHubRepo,
        skillDir: String
    ) async throws -> [GitHubSkillAsset] {
        let cleanDir = normalizedSource(skillDir)
        guard let topEntries = try await listDirectory(repo: repo, path: cleanDir) else {
            return []
        }

        var results: [GitHubSkillAsset] = []
        for entry in topEntries {
            if entry.type == "file" {
                if entry.name == "SKILL.md" { continue }
                results.append(
                    GitHubSkillAsset(
                        path: entry.path,
                        relativePath: entry.name,
                        size: entry.size ?? 0
                    )
                )
            } else if entry.type == "dir",
                Self.conventionalAssetSubdirs.contains(entry.name)
            {
                if let sub = try? await listDirectory(repo: repo, path: entry.path) {
                    for inner in sub where inner.type == "file" {
                        results.append(
                            GitHubSkillAsset(
                                path: inner.path,
                                relativePath: "\(entry.name)/\(inner.name)",
                                size: inner.size ?? 0
                            )
                        )
                    }
                }
            }
        }
        return results
    }

    /// Subdirectories of a skill folder we walk one level deep when fetching
    /// co-located assets. Anthropic plugins land their Python helpers under
    /// `scripts/`, supporting docs under `references/`, binary templates
    /// under `assets/` or `templates/`.
    nonisolated private static let conventionalAssetSubdirs: Set<String> = [
        "scripts", "references", "assets", "templates",
    ]

    /// Build the full manifest of importable artifacts for one plugin.
    ///
    /// `nonisolated` so a `TaskGroup` in `fetchPlugins(from:)` can drive
    /// many `buildManifest` calls in parallel — at MainActor isolation each
    /// call would serialize through the actor.
    private nonisolated func buildManifest(
        rootRepo: GitHubRepo,
        plugin: MarketplacePlugin
    ) async throws -> ClaudePluginManifest {
        // Resolve where this plugin's files actually live (could be the
        // marketplace repo, or an external repo entirely).
        let resolved = await resolveSource(
            rootRepo: rootRepo,
            source: plugin.source,
            pluginName: plugin.name
        )
        let sourceRepo = resolved.repo
        let source = resolved.basePath

        // Legacy plugins: declared `skills: [String]` paths are already
        // explicit; just resolve them and stop. We still record the
        // resolved sourceRepo so external-source legacy plugins (if anyone
        // ever ships them) keep working.
        if let declared = plugin.skills, !declared.isEmpty {
            let entries = declared.map { decl -> ClaudeSkillEntry in
                let p = normalizedSource(decl)
                let rebased: String
                if source.isEmpty || p.hasPrefix("\(source)/") || p == source {
                    rebased = p
                } else {
                    rebased = "\(source)/\(p)"
                }
                return ClaudeSkillEntry(path: rebased)
            }
            return ClaudePluginManifest(
                name: plugin.name,
                description: plugin.description,
                source: source.isEmpty ? plugin.name : source,
                sourceRepo: sourceRepo,
                authorName: plugin.author?.name,
                skills: entries,
                isLegacy: true
            )
        }

        // New-style plugins: discover from the source directory. Empty
        // `source` (external repo at root) probes top-level `skills`/`agents`.
        let prefix = source.isEmpty ? "" : "\(source)/"

        // Probe concurrently — serializing these round-trips was the main
        // cause of the ~10s picker wait for repos with ~13 plugins.
        async let skillsTask: [ClaudeSkillEntry] =
            discoverSkillDirectoriesTolerant(repo: sourceRepo, source: source)
        async let agentsListing: [GitHubTreeEntry]? =
            listDirectoryTolerant(repo: sourceRepo, path: "\(prefix)agents")
        async let commandsListing: [GitHubTreeEntry]? =
            listDirectoryTolerant(repo: sourceRepo, path: "\(prefix)commands")
        async let hasClaudeMd: Bool = fileExists(repo: sourceRepo, path: "\(prefix)CLAUDE.md")
        async let hasConnectorsMd: Bool = fileExists(
            repo: sourceRepo,
            path: "\(prefix)CONNECTORS.md"
        )
        async let hasReadmeMd: Bool = fileExists(repo: sourceRepo, path: "\(prefix)README.md")
        async let hasMCPJson: Bool = fileExists(repo: sourceRepo, path: "\(prefix).mcp.json")
        async let pluginJSONRaw: String? = fetchOptionalFileContent(
            from: sourceRepo,
            path: "\(prefix).claude-plugin/plugin.json"
        )
        async let sha: String? = fetchSourceSHA(
            repo: sourceRepo,
            path: source.isEmpty ? nil : source
        )

        let skills = try await skillsTask
        let agents: [ClaudeAgentEntry] =
            (try await agentsListing).map { entries in
                entries
                    .filter { $0.type == "file" && $0.name.hasSuffix(".md") }
                    .map { ClaudeAgentEntry(path: $0.path) }
                    .sorted { $0.displayName < $1.displayName }
            } ?? []
        let commands: [ClaudeCommandEntry] =
            (try await commandsListing).map { entries in
                entries
                    .filter { $0.type == "file" && $0.name.hasSuffix(".md") }
                    .map { ClaudeCommandEntry(path: $0.path) }
                    .sorted { $0.displayName < $1.displayName }
            } ?? []
        let claudeMdPath = await hasClaudeMd ? "\(prefix)CLAUDE.md" : nil
        var auxPaths: [String] = []
        if let claudeMdPath { auxPaths.append(claudeMdPath) }
        if await hasConnectorsMd { auxPaths.append("\(prefix)CONNECTORS.md") }
        if await hasReadmeMd { auxPaths.append("\(prefix)README.md") }
        let mcpJsonPath = await hasMCPJson ? "\(prefix).mcp.json" : nil

        // Merge per-plugin `plugin.json` metadata on top of marketplace
        // entry fields. Spec precedence:
        //   displayName: plugin.json > <none>; falls back to `name` at use.
        //   version: plugin.json > marketplace entry > git SHA > nil.
        //   description: plugin.json > marketplace entry.
        //   keywords/license/homepage/repository: plugin.json > marketplace entry.
        //   author.{name,email,url}: plugin.json author block > marketplace `author.name`.
        let pluginJSONString = await pluginJSONRaw
        let parsedJSON = pluginJSONString.flatMap { ClaudePluginJSON.parse($0) }
        let sourceSHA = await sha

        let resolvedDescription = parsedJSON?.description ?? plugin.description
        let resolvedAuthorName = parsedJSON?.authorName ?? plugin.author?.name
        let resolvedAuthorEmail = parsedJSON?.authorEmail
        let resolvedAuthorURL = parsedJSON?.authorURL
        let resolvedHomepage = parsedJSON?.homepage ?? plugin.homepage
        let resolvedRepository = parsedJSON?.repository ?? plugin.repository
        let resolvedLicense = parsedJSON?.license ?? plugin.license
        let resolvedKeywords: [String] = {
            if let kw = parsedJSON?.keywords, !kw.isEmpty { return kw }
            return plugin.keywords ?? []
        }()
        let resolvedVersion = ClaudePluginVersionResolver.resolve(
            pluginJSONVersion: parsedJSON?.version,
            marketplaceVersion: plugin.version,
            sha: sourceSHA
        )

        return ClaudePluginManifest(
            name: plugin.name,
            description: resolvedDescription,
            source: source.isEmpty ? plugin.name : source,
            sourceRepo: sourceRepo,
            authorName: resolvedAuthorName,
            skills: skills,
            agents: agents,
            commands: commands,
            claudeMdPath: claudeMdPath,
            auxMarkdownPaths: auxPaths,
            mcpJsonPath: mcpJsonPath,
            isLegacy: false,
            displayName: parsedJSON?.displayName,
            version: resolvedVersion,
            authorEmail: resolvedAuthorEmail,
            authorURL: resolvedAuthorURL,
            homepage: resolvedHomepage,
            repository: resolvedRepository,
            license: resolvedLicense,
            keywords: resolvedKeywords,
            userConfigSpec: parsedJSON?.userConfig ?? [],
            declaredDependencies: parsedJSON?.declaredDependencies ?? [],
            declaresHooks: parsedJSON?.hasHooks ?? false,
            declaresUnsupportedComponents: parsedJSON?.unsupportedComponents ?? []
        )
    }

    /// Spec-defined version resolution: prefer the value declared in
    /// `plugin.json`, fall back to the marketplace entry, then the git
    /// SHA at fetch time, then `nil`.
    public enum ClaudePluginVersionResolver {
        public static func resolve(
            pluginJSONVersion: String?,
            marketplaceVersion: String?,
            sha: String?
        ) -> String? {
            if let v = pluginJSONVersion?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !v.isEmpty
            {
                return v
            }
            if let v = marketplaceVersion?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !v.isEmpty
            {
                return v
            }
            if let s = sha?.trimmingCharacters(in: .whitespacesAndNewlines),
                !s.isEmpty
            {
                // Short SHA (first 7 chars) matches the Claude Code spec's
                // SHA-as-version convention.
                return String(s.prefix(7))
            }
            return nil
        }

        /// True when `available` is strictly newer than `installed`.
        ///
        /// Both sides parse as semver → compare semver. Either side is a
        /// SHA (or unparseable) → fall back to string inequality, matching
        /// the spec's "SHA-versioned plugins update whenever the recorded
        /// SHA differs" behavior.
        public static func hasUpdate(installed: String?, available: String?) -> Bool {
            guard
                let available = available?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !available.isEmpty
            else {
                return false
            }
            let installedTrimmed = (installed ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if installedTrimmed.isEmpty { return true }
            if installedTrimmed == available { return false }
            if let lhs = SemanticVersion.parse(installedTrimmed),
                let rhs = SemanticVersion.parse(available)
            {
                return lhs < rhs
            }
            // Either side is a SHA / non-semver → any difference counts.
            return true
        }
    }

    /// Public helper used by `InstalledClaudePluginsAggregator` to probe
    /// the source path's HEAD commit when checking for SHA-versioned
    /// plugin updates.
    public nonisolated func fetchSourceSHANonIsolated(
        owner: String,
        repo: String,
        branch: String,
        path: String?
    ) async -> String? {
        let r = GitHubRepo(owner: owner, name: repo, branch: branch)
        return await fetchSourceSHA(repo: r, path: path)
    }

    /// Fetch the head commit SHA for the source path. Used to pin a
    /// SHA-style version when neither `plugin.json` nor the marketplace
    /// entry declare one (per the Claude Code plugin spec).
    ///
    /// Returns `nil` when the API call fails or the response is
    /// unexpected — version resolution then falls back to `nil` and the
    /// plugin is recorded as "unknown" version. `path == nil` queries
    /// the whole repo HEAD (used when the plugin lives at the repo root).
    private nonisolated func fetchSourceSHA(
        repo: GitHubRepo,
        path: String?
    ) async -> String? {
        var urlString = "https://api.github.com/repos/\(repo.owner)/\(repo.name)/commits"
        var queryItems: [String] = ["per_page=1", "sha=\(repo.branch)"]
        if let path, !path.isEmpty {
            // Percent-encode the path so directories with characters like
            // `+` / spaces round-trip safely through GitHub's query parser.
            let allowed = CharacterSet.urlQueryAllowed.subtracting(
                CharacterSet(charactersIn: "&=?")
            )
            let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
            queryItems.append("path=\(encoded)")
        }
        urlString += "?" + queryItems.joined(separator: "&")
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                http.statusCode == 200
            else {
                return nil
            }
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                let first = arr.first
            else {
                return nil
            }
            return first["sha"] as? String
        } catch {
            return nil
        }
    }

    /// Resolve a `MarketplaceSource` to the concrete `(repo, basePath)` pair
    /// the discovery probes use. For external sources this both pins the
    /// branch/sha and rewrites the base path so subsequent `listDirectory`
    /// / `fileExists` calls hit the correct repo.
    private nonisolated func resolveSource(
        rootRepo: GitHubRepo,
        source: MarketplaceSource?,
        pluginName: String
    ) async -> (repo: GitHubRepo, basePath: String) {
        guard let source else {
            // No source declared at all → treat the plugin's name as the
            // directory (mirrors the legacy `plugin.source ?? plugin.name`
            // fallback).
            return (rootRepo, normalizedSource(pluginName))
        }
        switch source {
        case .localDirectory(let dir):
            return (rootRepo, normalizedSource(dir))
        case .externalRepo(let repo, _):
            let pinned = await pinnedExternalRepo(repo)
            return (pinned, "")
        case .externalSubdir(let repo, let path, _):
            let pinned = await pinnedExternalRepo(repo)
            return (pinned, normalizedSource(path))
        }
    }

    /// When an external source didn't ship a pinned sha, fall back to the
    /// repo's actual default branch so subsequent raw URL fetches resolve.
    private nonisolated func pinnedExternalRepo(_ repo: GitHubRepo) async -> GitHubRepo {
        // Branches like "main" or "master" usually still resolve, so only
        // consult the API when we still have the default placeholder.
        if repo.branch != "main" { return repo }
        return (try? await detectDefaultBranchNonIsolated(repo)) ?? repo
    }

    /// Same shape as `detectDefaultBranch(_:)` but callable from nonisolated
    /// contexts. Used when resolving `MarketplaceSource.externalRepo` /
    /// `.externalSubdir` to pin the correct branch without round-tripping
    /// through the main actor. Falls back to the input repo on any error.
    private nonisolated func detectDefaultBranchNonIsolated(
        _ repo: GitHubRepo
    ) async throws -> GitHubRepo {
        guard let apiURL = URL(string: repo.apiURL) else { return repo }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
            let rateLimit = rateLimitError(from: httpResponse)
        {
            throw rateLimit
        }
        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let defaultBranch = json["default_branch"] as? String
        else {
            return repo
        }
        return GitHubRepo(owner: repo.owner, name: repo.name, branch: defaultBranch)
    }

    private nonisolated func fileExists(repo: GitHubRepo, path: String) async -> Bool {
        let fileURL = "\(repo.rawBaseURL)/\(path)"
        guard let url = URL(string: fileURL) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    /// If `http` is a GitHub rate-limit response (403 with
    /// `X-RateLimit-Remaining: 0`), return a `.rateLimited` error carrying
    /// the parsed reset time. Returns nil otherwise.
    private nonisolated func rateLimitError(from http: HTTPURLResponse) -> GitHubSkillError? {
        guard http.statusCode == 403 else { return nil }
        let remaining =
            (http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                ?? http.value(forHTTPHeaderField: "x-ratelimit-remaining"))
        guard remaining == "0" else { return nil }
        let resetStr =
            http.value(forHTTPHeaderField: "X-RateLimit-Reset")
            ?? http.value(forHTTPHeaderField: "x-ratelimit-reset")
        let resetAt: Date? =
            resetStr
            .flatMap(TimeInterval.init)
            .map { Date(timeIntervalSince1970: $0) }
        return .rateLimited(resetAt: resetAt)
    }

    private nonisolated func normalizedSource(_ source: String) -> String {
        var s = source
        if s.hasPrefix("./") { s = String(s.dropFirst(2)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return s
    }

    // MARK: - Private Helpers

    private func detectDefaultBranch(_ repo: GitHubRepo) async throws -> GitHubRepo {
        // First try 'main', then 'master'
        let branches = ["main", "master"]

        for branch in branches {
            let testRepo = GitHubRepo(owner: repo.owner, name: repo.name, branch: branch)
            let testURL = "\(testRepo.rawBaseURL)/.claude-plugin/marketplace.json"

            guard let url = URL(string: testURL) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"

            do {
                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    return testRepo
                }
            } catch {
                continue
            }
        }

        // If neither worked, try the GitHub API to get default branch
        guard let apiURL = URL(string: repo.apiURL) else {
            return repo
        }

        do {
            var request = URLRequest(url: apiURL)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)

            // Surface a rate-limit hit here too — otherwise we'd silently
            // fall back to "main" and the very next request would hit the
            // limit anyway, just with a less actionable error message.
            if let httpResponse = response as? HTTPURLResponse,
                let rateLimit = rateLimitError(from: httpResponse)
            {
                throw rateLimit
            }

            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                return repo
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let defaultBranch = json["default_branch"] as? String
            {
                return GitHubRepo(owner: repo.owner, name: repo.name, branch: defaultBranch)
            }
        } catch let err as GitHubSkillError {
            // Rate-limit specifically must escape; other GitHub errors are
            // benign here (the caller falls back to "main" branch).
            if case .rateLimited = err { throw err }
        } catch {
            // Network/transient: fall back to "main".
        }

        return repo
    }

    private func fetchMarketplace(_ repo: GitHubRepo) async throws -> GitHubMarketplace {
        let marketplaceURL = "\(repo.rawBaseURL)/.claude-plugin/marketplace.json"

        guard let url = URL(string: marketplaceURL) else {
            throw GitHubSkillError.invalidURL(marketplaceURL)
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubSkillError.networkError(NSError(domain: "HTTPError", code: -1))
        }

        if let rateLimit = rateLimitError(from: httpResponse) {
            throw rateLimit
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 404:
            throw GitHubSkillError.noMarketplaceFile
        default:
            throw GitHubSkillError.networkError(
                NSError(
                    domain: "HTTPError",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]
                )
            )
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(GitHubMarketplace.self, from: data)
        } catch {
            throw GitHubSkillError.invalidMarketplace(error.localizedDescription)
        }
    }
}

// MARK: - GitHub Fetch Concurrency Limiter

/// Bounds the number of in-flight GitHub Contents-API / raw-content fetches
/// across the importer.
///
/// Without this, a plugin like `pitch-agent` (13 skills × ~5 supporting
/// files each) can burn through GitHub's 60-request unauthenticated rate
/// limit on a single import. The limiter is a simple async semaphore: each
/// `run` call waits for a permit before invoking its body and returns the
/// permit when the body completes (success or failure).
///
/// The chosen permit count (8) is small enough to leave headroom for
/// concurrent UI fetches and large enough that latency-bound calls overlap
/// well. Bumping it past ~16 starts hitting the rate limit on cold sessions.
public actor GitHubFetchLimiter {
    public static let shared = GitHubFetchLimiter(maxConcurrent: 8)

    private let maxConcurrent: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Acquire a permit, run `body`, release the permit (even if `body`
    /// throws). The body runs outside the actor so it can hit the network
    /// without blocking other waiters.
    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    /// Non-throwing variant for closures that capture their own error state.
    public func runNoThrow<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let value = await body()
        release()
        return value
    }

    private func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
            return
        }
        inFlight = max(0, inFlight - 1)
    }
}
