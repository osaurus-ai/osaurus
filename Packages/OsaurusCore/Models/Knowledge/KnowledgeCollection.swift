//
//  KnowledgeCollection.swift
//  osaurus
//
//  A knowledge collection is a user-curated folder of markdown documents
//  ("knowledge": SOPs, templates, guides — human-governed reference
//  material) that agents can search and read on demand. Distinct from
//  memory, which is agent-written and distilled from conversations.
//
//  The folder is the source of truth and is indexed in place — the
//  knowledge feature never mutates it. All indexes (SQLite + vectors)
//  are derived, rebuildable artifacts. Documents are plain markdown,
//  optionally carrying YAML frontmatter; when present, the Open
//  Knowledge Format (OKF) reserved fields (`type`, `title`,
//  `description`, `tags`, `timestamp`) are recognized for faceting.
//

import Foundation

public struct KnowledgeCollection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// Display name; also how the model addresses the collection in tool
    /// arguments (matched case-insensitively).
    public var name: String
    /// Short summary of what the corpus contains, surfaced to agents so
    /// they know when to consult it.
    public var summary: String
    /// Absolute path to the folder of markdown documents.
    public var folderPath: String
    /// Disabled collections stay registered but are excluded from
    /// indexing, search, and agent grants resolution.
    public var isEnabled: Bool
    /// Git remote this collection syncs with (`nil` for plain local
    /// folders). Set when the collection was added by cloning a URL, or
    /// detected from an existing repo's `origin`. Sync is always
    /// user-triggered or approval-triggered; there is no background poll.
    public var gitRemoteURL: String?
    /// Optional path patterns restricting which files are indexed, matched
    /// against each file's collection-relative path (e.g. `docs/ENGINES.md`).
    /// When `includeGlobs` is non-empty a file must match one of them to be
    /// indexed; a file matching any `excludeGlobs` pattern is always dropped.
    /// Both empty (the default) means "index everything", so existing
    /// collections are unaffected. Changing either requires re-indexing the
    /// collection (newly-excluded files are pruned, newly-included ones
    /// added). See `KnowledgeGlob` for the supported syntax.
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        folderPath: String,
        isEnabled: Bool = true,
        gitRemoteURL: String? = nil,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.folderPath = folderPath
        self.isEnabled = isEnabled
        self.gitRemoteURL = gitRemoteURL
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        folderPath = try c.decode(String.self, forKey: .folderPath)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        gitRemoteURL = try c.decodeIfPresent(String.self, forKey: .gitRemoteURL)
        includeGlobs = try c.decodeIfPresent([String].self, forKey: .includeGlobs) ?? []
        excludeGlobs = try c.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// True when `relPath` (collection-relative, `/`-separated) should be
    /// indexed under this collection's include/exclude globs.
    public func indexPathAllowed(_ relPath: String) -> Bool {
        KnowledgeGlob.matches(relPath, include: includeGlobs, exclude: excludeGlobs)
    }

    public var folderURL: URL {
        URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Whether the collection's folder currently exists on disk. A missing
    /// folder (unmounted volume, deleted directory) degrades search to the
    /// already-indexed rows; `read_knowledge` reports it as unavailable.
    public var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // `fileExists` against an unmounted network volume or slow external disk
    // can block for seconds, and the knowledge list evaluates `folderExists`
    // per row per SwiftUI body pass — an observed main-thread hang. The memo
    // pays that probe once per path, then serves the cached verdict and
    // refreshes it off the calling thread when stale.
    private static let folderExistsCacheLock = NSLock()
    private nonisolated(unsafe) static var folderExistsCache: [String: (value: Bool, at: Date)] =
        [:]
    private nonisolated(unsafe) static var folderExistsRefreshInFlight: Set<String> = []
    private static let folderExistsRefreshInterval: TimeInterval = 10.0

    /// Eventually-consistent variant of `folderExists` for view bodies and
    /// other latency-sensitive callers. Correctness-critical paths (indexing,
    /// curation, watchers — all off-main) should keep using `folderExists`.
    public var folderExistsCached: Bool {
        let path = folderURL.path
        return Self.cachedProbe(key: path) {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// Eventually-consistent variant of `isGitRepository` (same body-eval
    /// call sites as `folderExistsCached`, same slow-volume hazard).
    public var isGitRepositoryCached: Bool {
        let path = folderURL.appendingPathComponent(".git").path
        return Self.cachedProbe(key: path) {
            FileManager.default.fileExists(atPath: path)
        }
    }

    private static func cachedProbe(key: String, probe: @escaping @Sendable () -> Bool) -> Bool {
        folderExistsCacheLock.lock()
        let known = folderExistsCache[key]
        folderExistsCacheLock.unlock()

        if let known {
            if Date().timeIntervalSince(known.at) >= folderExistsRefreshInterval {
                folderExistsCacheLock.lock()
                let alreadyRefreshing = !folderExistsRefreshInFlight.insert(key).inserted
                folderExistsCacheLock.unlock()
                if !alreadyRefreshing {
                    DispatchQueue.global(qos: .utility).async {
                        let value = probe()
                        folderExistsCacheLock.lock()
                        folderExistsCache[key] = (value, Date())
                        folderExistsRefreshInFlight.remove(key)
                        folderExistsCacheLock.unlock()
                    }
                }
            }
            return known.value
        }

        let probed = probe()
        folderExistsCacheLock.lock()
        folderExistsCache[key] = (probed, Date())
        folderExistsCacheLock.unlock()
        return probed
    }

    /// Whether the collection folder is a git repository (a `.git` entry
    /// at its root — a plain directory for normal repos, a file for
    /// worktrees/submodules).
    public var isGitRepository: Bool {
        FileManager.default.fileExists(
            atPath: folderURL.appendingPathComponent(".git").path
        )
    }

    /// Prompt-facing slice of this grant (see `KnowledgeGrantDescriptor`).
    public var grantDescriptor: KnowledgeGrantDescriptor {
        KnowledgeGrantDescriptor(name: name, summary: summary)
    }
}

/// Prompt-facing slice of a granted collection — the name + summary pair
/// the `## Knowledge` system prompt section enumerates so agents know when
/// to consult the corpus. This is the surfacing the `summary` field's doc
/// comment promises; without it the model only sees the generic knowledge
/// tool descriptions and never connects a domain question to the corpus.
public struct KnowledgeGrantDescriptor: Sendable, Equatable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}
