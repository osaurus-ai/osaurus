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
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        folderPath: String,
        isEnabled: Bool = true,
        gitRemoteURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.folderPath = folderPath
        self.isEnabled = isEnabled
        self.gitRemoteURL = gitRemoteURL
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
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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
