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

/// Marketplace.json plugin definition
public struct MarketplacePlugin: Codable, Sendable {
    public let name: String
    public let description: String?
    public let source: String?
    public let strict: Bool?
    public let skills: [String]
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

    /// Fetch available skills from a GitHub repository
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

            // Extract skills from plugins
            var skills: [GitHubSkillPreview] = []
            for plugin in marketplace.plugins {
                for skillPath in plugin.skills {
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

    /// Fetch the SKILL.md content for a specific skill
    public func fetchSkillContent(from repo: GitHubRepo, skillPath: String) async throws -> String {
        // Clean up the path
        var cleanPath = skillPath
        if cleanPath.hasPrefix("./") {
            cleanPath = String(cleanPath.dropFirst(2))
        }

        let skillURL = "\(repo.rawBaseURL)/\(cleanPath)/SKILL.md"

        guard let url = URL(string: skillURL) else {
            throw GitHubSkillError.invalidURL(skillURL)
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubSkillError.networkError(NSError(domain: "HTTPError", code: -1))
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw GitHubSkillError.skillFetchFailed(
                    skillPath,
                    NSError(
                        domain: "GitHubSkillService",
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "SKILL.md not found"]
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
                skillPath,
                NSError(
                    domain: "GitHubSkillService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 content"]
                )
            )
        }

        return content
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

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return repo
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let defaultBranch = json["default_branch"] as? String
            {
                return GitHubRepo(owner: repo.owner, name: repo.name, branch: defaultBranch)
            }
        } catch {
            // Ignore and use default
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
