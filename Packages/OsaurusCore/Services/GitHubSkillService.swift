//
//  GitHubSkillService.swift
//  osaurus
//
//  Service for importing skills from GitHub repositories.
//  Supports repositories with .claude-plugin/marketplace.json format.
//

import Foundation

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

/// Marketplace.json plugin definition.
///
/// Supports two schemas:
/// - Legacy: declares a flat `skills: [String]` array listing SKILL.md paths.
/// - New (claude-for-legal): only declares `source: "./<dir>"` and skills/agents/
///   commands/MCP servers are discovered by directory convention.
public struct MarketplacePlugin: Codable, Sendable {
    public let name: String
    public let description: String?
    public let source: String?
    public let strict: Bool?
    public let skills: [String]?
    public let author: MarketplaceOwner?

    public init(
        name: String,
        description: String? = nil,
        source: String? = nil,
        strict: Bool? = nil,
        skills: [String]? = nil,
        author: MarketplaceOwner? = nil
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.strict = strict
        self.skills = skills
        self.author = author
    }
}

/// Root marketplace.json structure
public struct GitHubMarketplace: Codable, Sendable {
    public let name: String
    public let owner: MarketplaceOwner?
    public let metadata: MarketplaceMetadata?
    public let plugins: [MarketplacePlugin]
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
    public let source: String  // root path inside the repo (e.g. "commercial-legal")
    public let authorName: String?
    public let skills: [ClaudeSkillEntry]
    public let agents: [ClaudeAgentEntry]
    public let commands: [ClaudeCommandEntry]
    public let claudeMdPath: String?
    public let mcpJsonPath: String?
    /// True when the plugin came from a legacy marketplace.json (`skills: [String]`).
    /// In that case only `skills` is populated.
    public let isLegacy: Bool

    public init(
        name: String,
        description: String?,
        source: String,
        authorName: String? = nil,
        skills: [ClaudeSkillEntry] = [],
        agents: [ClaudeAgentEntry] = [],
        commands: [ClaudeCommandEntry] = [],
        claudeMdPath: String? = nil,
        mcpJsonPath: String? = nil,
        isLegacy: Bool = false
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.authorName = authorName
        self.skills = skills
        self.agents = agents
        self.commands = commands
        self.claudeMdPath = claudeMdPath
        self.mcpJsonPath = mcpJsonPath
        self.isLegacy = isLegacy
    }

    /// True when there is anything importable beyond skills.
    public var hasNonSkillArtifacts: Bool {
        !agents.isEmpty || !commands.isEmpty || claudeMdPath != nil || mcpJsonPath != nil
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

/// Minimal `contents` API entry. We only need name / path / type.
public struct GitHubTreeEntry: Decodable, Sendable {
    public let name: String
    public let path: String
    public let type: String  // "dir" or "file"

    public init(name: String, path: String, type: String) {
        self.name = name
        self.path = path
        self.type = type
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
            if let resetAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                let when = formatter.localizedString(for: resetAt, relativeTo: Date())
                return "GitHub rate-limited this app. Try again \(when)."
            }
            return "GitHub rate-limited this app. Sign in or wait an hour to retry."
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
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
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
            var skills: [GitHubSkillPreview] = []
            for plugin in marketplace.plugins {
                let skillPaths: [String]
                if let declared = plugin.skills, !declared.isEmpty {
                    skillPaths = declared
                } else if let source = plugin.source {
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
                            repo: repoCopy,
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
        let skillsDir = "\(sourceClean)/skills"

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

    /// Build the full manifest of importable artifacts for one plugin.
    ///
    /// `nonisolated` so a `TaskGroup` in `fetchPlugins(from:)` can drive
    /// many `buildManifest` calls in parallel — at MainActor isolation each
    /// call would serialize through the actor.
    private nonisolated func buildManifest(
        repo: GitHubRepo,
        plugin: MarketplacePlugin
    ) async throws -> ClaudePluginManifest {
        // Legacy plugins: just resolve declared skills, nothing more.
        if let declared = plugin.skills, !declared.isEmpty {
            let entries = declared.map { ClaudeSkillEntry(path: normalizedSource($0)) }
            return ClaudePluginManifest(
                name: plugin.name,
                description: plugin.description,
                source: plugin.source.map(normalizedSource) ?? plugin.name,
                authorName: plugin.author?.name,
                skills: entries,
                isLegacy: true
            )
        }

        // New-style plugins: discover from the source directory.
        let source = normalizedSource(plugin.source ?? plugin.name)

        // Run the five independent discovery probes concurrently. Each one
        // is at least one HTTP round-trip; serializing them was the main
        // contributor to the ~10-second wait on the picker for repos with
        // ~13 plugins like `claude-for-legal`.
        async let skillsTask: [ClaudeSkillEntry] =
            (try? await discoverSkillDirectories(repo: repo, source: source)) ?? []
        async let agentsListing =
            (try? await listDirectory(repo: repo, path: "\(source)/agents"))
            ?? nil
        async let commandsListing =
            (try? await listDirectory(repo: repo, path: "\(source)/commands")) ?? nil
        async let hasClaudeMd: Bool = fileExists(repo: repo, path: "\(source)/CLAUDE.md")
        async let hasMCPJson: Bool = fileExists(repo: repo, path: "\(source)/.mcp.json")

        let skills = await skillsTask
        let agents: [ClaudeAgentEntry] =
            (await agentsListing).map { entries in
                entries
                    .filter { $0.type == "file" && $0.name.hasSuffix(".md") }
                    .map { ClaudeAgentEntry(path: $0.path) }
                    .sorted { $0.displayName < $1.displayName }
            } ?? []
        let commands: [ClaudeCommandEntry] =
            (await commandsListing).map { entries in
                entries
                    .filter { $0.type == "file" && $0.name.hasSuffix(".md") }
                    .map { ClaudeCommandEntry(path: $0.path) }
                    .sorted { $0.displayName < $1.displayName }
            } ?? []
        let claudeMdPath = await hasClaudeMd ? "\(source)/CLAUDE.md" : nil
        let mcpJsonPath = await hasMCPJson ? "\(source)/.mcp.json" : nil

        return ClaudePluginManifest(
            name: plugin.name,
            description: plugin.description,
            source: source,
            authorName: plugin.author?.name,
            skills: skills,
            agents: agents,
            commands: commands,
            claudeMdPath: claudeMdPath,
            mcpJsonPath: mcpJsonPath,
            isLegacy: false
        )
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
