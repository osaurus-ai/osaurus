//
//  FolderContext.swift
//  osaurus
//
//  Models for work folder context integration.
//  Provides project detection, file tree options, and folder context data.
//

import Foundation

// MARK: - Folder Context

/// Context information about a selected working folder for work operations
public struct FolderContext: Sendable {
    /// The root path of the selected folder
    public let rootPath: URL

    /// Detected project type based on manifest files
    public let projectType: ProjectType

    /// File tree representation (may be summarized for large directories)
    public let tree: String

    /// Contents of the project manifest file (e.g., Package.swift, package.json)
    public let manifest: String?

    /// Git status output if this is a git repository
    public let gitStatus: String?

    /// Whether this folder is a git repository
    public let isGitRepo: Bool

    /// Project-level guidance file loaded from the folder root, if present.
    /// First-found-wins across `.hermes.md` / `HERMES.md` → `AGENTS.md` →
    /// `CLAUDE.md` → `.cursorrules`. Capped at 20K chars with head + tail
    /// truncation so the middle of a long file is dropped instead of the
    /// trailing instructions. Pre-formatted with a `## <name>` header so
    /// the prompt composer can drop it in as-is.
    public let contextFiles: String?

    public init(
        rootPath: URL,
        projectType: ProjectType,
        tree: String,
        manifest: String?,
        gitStatus: String?,
        isGitRepo: Bool,
        contextFiles: String? = nil
    ) {
        self.rootPath = rootPath
        self.projectType = projectType
        self.tree = tree
        self.manifest = manifest
        self.gitStatus = gitStatus
        self.isGitRepo = isGitRepo
        self.contextFiles = contextFiles
    }
}

// MARK: - Project Type

/// Detected project type for a folder
public enum ProjectType: String, Sendable, CaseIterable {
    case swift
    case node
    case python
    case rust
    case go
    case unknown

    /// Patterns to ignore when building file tree
    public var ignorePatterns: [String] {
        switch self {
        case .swift:
            return [".build", "DerivedData", "Pods", ".swiftpm", "*.xcodeproj", "*.xcworkspace", ".git"]
        case .node:
            return ["node_modules", "dist", ".next", "build", ".cache", ".git"]
        case .python:
            return ["__pycache__", ".venv", "venv", "*.pyc", ".pytest_cache", ".mypy_cache", ".git"]
        case .rust:
            return ["target", ".git"]
        case .go:
            return ["vendor", ".git"]
        case .unknown:
            return [".git"]
        }
    }

    /// Files that indicate this project type
    public var manifestFiles: [String] {
        switch self {
        case .swift:
            return ["Package.swift"]
        case .node:
            return ["package.json"]
        case .python:
            return ["pyproject.toml", "setup.py", "requirements.txt"]
        case .rust:
            return ["Cargo.toml"]
        case .go:
            return ["go.mod"]
        case .unknown:
            return []
        }
    }

    /// The primary manifest file to read for context
    public var primaryManifest: String? {
        switch self {
        case .swift:
            return "Package.swift"
        case .node:
            return "package.json"
        case .python:
            return "pyproject.toml"
        case .rust:
            return "Cargo.toml"
        case .go:
            return "go.mod"
        case .unknown:
            return nil
        }
    }

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .node: return "Node.js"
        case .python: return "Python"
        case .rust: return "Rust"
        case .go: return "Go"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - File Tree Options

/// Options for building file tree representation
public struct FileTreeOptions {
    /// Maximum depth to traverse (default: 3)
    public var maxDepth: Int

    /// Patterns to ignore (combined with project-specific patterns)
    public var ignorePatterns: [String]

    /// Maximum number of files to list before summarizing (default: 300)
    public var maxFiles: Int

    /// Whether to summarize directories that exceed maxFiles (default: true)
    public var summarizeAboveThreshold: Bool

    public init(
        maxDepth: Int = 3,
        ignorePatterns: [String] = [],
        maxFiles: Int = 300,
        summarizeAboveThreshold: Bool = true
    ) {
        self.maxDepth = maxDepth
        self.ignorePatterns = ignorePatterns
        self.maxFiles = maxFiles
        self.summarizeAboveThreshold = summarizeAboveThreshold
    }

    /// Default options for building file tree
    public static var `default`: FileTreeOptions {
        FileTreeOptions()
    }
}
