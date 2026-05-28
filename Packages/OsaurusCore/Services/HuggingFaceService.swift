//
//  HuggingFaceService.swift
//  osaurus
//
//  Extracted from MLXService for clarity and reuse.
//

import Foundation

// MARK: - Hugging Face lightweight metadata fetcher
actor HuggingFaceService {
    static let shared = HuggingFaceService()

    struct RepoFile: Decodable {
        let rfilename: String
        let size: Int64?
    }

    // Minimal model metadata from HF
    struct ModelMeta: Decodable {
        let id: String
        let tags: [String]?
        let siblings: [RepoFile]?
    }

    // MARK: - Rich Model Details

    /// Comprehensive model details from Hugging Face API
    struct ModelDetails {
        let id: String
        let author: String?
        let downloads: Int?
        let likes: Int?
        let lastModified: Date?
        let license: String?
        let pipelineTag: String?
        let modelType: String?
        let tags: [String]
        let isVLM: Bool
    }

    /// Raw API response for detailed model info
    private struct ModelDetailsResponse: Decodable {
        let id: String
        let author: String?
        let downloads: Int?
        let likes: Int?
        let lastModified: String?
        let tags: [String]?
        let pipeline_tag: String?
        let config: ConfigInfo?
        let cardData: CardData?

        struct ConfigInfo: Decodable {
            let model_type: String?
        }

        struct CardData: Decodable {
            let license: String?
            let model_type: String?
        }
    }

    struct MatchedFile {
        let path: String
        let size: Int64
    }

    private init() {}

    /// Fetch files from a Hugging Face repo that match the given glob patterns.
    /// Files whose last path component appears in `excludedFiles` are skipped.
    func fetchMatchingFiles(
        repoId: String,
        patterns: [String],
        excludedFiles: Set<String> = []
    ) async -> [MatchedFile]? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models/\(repoId)/tree/main"
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = comps.url else { return nil }

        struct TreeNode: Decodable {
            let path: String
            let type: String?
            let size: Int64?
            let lfs: LFS?
            struct LFS: Decodable { let size: Int64? }
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await GlobalProxySettings.makeSession().data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            let nodes = try JSONDecoder().decode([TreeNode].self, from: data)
            if nodes.isEmpty { return nil }
            let matchers = patterns.compactMap { Glob($0) }
            let files = nodes.compactMap { node -> MatchedFile? in
                if node.type == "directory" { return nil }
                guard let safePath = Self.normalizedRemoteFilePath(node.path) else { return nil }
                let filename = (safePath as NSString).lastPathComponent
                if excludedFiles.contains(filename) { return nil }
                let matched = matchers.contains { $0.matches(filename) }
                guard matched else { return nil }
                let sz = node.size ?? node.lfs?.size ?? 0
                guard sz > 0 else { return nil }
                return MatchedFile(path: safePath, size: sz)
            }
            return files.isEmpty ? nil : files
        } catch {
            return nil
        }
    }

    /// Estimate the total size for files matching provided patterns.
    func estimateTotalSize(
        repoId: String,
        patterns: [String],
        excludedFiles: Set<String> = []
    ) async -> Int64? {
        guard
            let files = await fetchMatchingFiles(
                repoId: repoId,
                patterns: patterns,
                excludedFiles: excludedFiles
            )
        else { return nil }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        return total > 0 ? total : nil
    }

    /// Determine if a Hugging Face repo is MLX-compatible using repository metadata.
    /// Prefers explicit tags (e.g., "mlx", "apple-mlx", "library:mlx").
    /// Falls back to MLX/vMLX artifact-family id hints and required file presence
    /// when tags are unavailable.
    func isMLXCompatible(repoId: String) async -> Bool {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        // Fetch model metadata with tags and top-level file listing
        guard let meta = await fetchModelMeta(repoId: trimmed) else {
            // Network failure: conservative allowance for mlx-community repos
            if lower.hasPrefix("mlx-community/") { return true }
            return false
        }

        // Strong signal: tags explicitly indicate MLX
        if let tags = meta.tags?.map({ $0.lowercased() }) {
            if tags.contains("mlx") || tags.contains("apple-mlx") || tags.contains("library:mlx") {
                return true
            }
        }

        // Heuristic fallback: repository naming suggests MLX/vMLX-native
        // artifacts and core files exist. This covers JANG/JANGTQ/MXFP repos
        // whose display names may not include the literal `MLX` token.
        if Self.repoIdHasMLXArtifactHint(lower) && hasRequiredFiles(meta: meta) {
            return true
        }

        // As a last resort, trust curated org with required files
        if lower.hasPrefix("mlx-community/") && hasRequiredFiles(meta: meta) {
            return true
        }

        return false
    }

    /// Fetch comprehensive model details from Hugging Face
    /// Returns rich metadata including downloads, likes, license, etc.
    func fetchModelDetails(repoId: String) async -> ModelDetails? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models/\(repoId)"
        comps.queryItems = [URLQueryItem(name: "full", value: "1")]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await GlobalProxySettings.makeSession().data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }

            let decoder = JSONDecoder()
            let raw = try decoder.decode(ModelDetailsResponse.self, from: data)

            // Parse lastModified date
            var lastModified: Date?
            if let dateStr = raw.lastModified {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                lastModified = formatter.date(from: dateStr)
                // Try without fractional seconds if failed
                if lastModified == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    lastModified = formatter.date(from: dateStr)
                }
            }

            // Extract license from tags or cardData
            let tags = raw.tags ?? []
            let license = raw.cardData?.license ?? extractLicenseFromTags(tags)

            // Extract model type from config or cardData
            let modelType = raw.config?.model_type ?? raw.cardData?.model_type

            // VLM detection via model_type against VLMTypeRegistry
            let isVLM = modelType.map { VLMDetection.isVLM(modelType: $0) } ?? false

            return ModelDetails(
                id: raw.id,
                author: raw.author,
                downloads: raw.downloads,
                likes: raw.likes,
                lastModified: lastModified,
                license: license,
                pipelineTag: raw.pipeline_tag,
                modelType: modelType,
                tags: tags,
                isVLM: isVLM
            )
        } catch {
            return nil
        }
    }

    /// Extract license identifier from HF tags
    private func extractLicenseFromTags(_ tags: [String]) -> String? {
        // HF tags often include license: prefix
        for tag in tags {
            let lower = tag.lowercased()
            if lower.hasPrefix("license:") {
                return String(tag.dropFirst("license:".count))
            }
        }
        // Check for common license identifiers directly in tags
        let knownLicenses = ["mit", "apache-2.0", "gpl-3.0", "cc-by-4.0", "cc-by-nc-4.0", "llama2", "llama3", "gemma"]
        for tag in tags {
            if knownLicenses.contains(tag.lowercased()) {
                return tag
            }
        }
        return nil
    }

    // MARK: - Private helpers
    /// Hugging Face tree paths are network input but later become local
    /// destination paths, so keep only simple slash-separated relative paths.
    static func normalizedRemoteFilePath(_ path: String) -> String? {
        guard !path.isEmpty,
            !path.contains("\\"),
            !path.contains("\0"),
            !(path as NSString).isAbsolutePath
        else {
            return nil
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        var normalized: [String] = []
        for component in components {
            guard !component.isEmpty,
                component != ".",
                component != ".."
            else {
                return nil
            }
            normalized.append(String(component))
        }
        return normalized.joined(separator: "/")
    }

    static func destinationURL(forRemotePath path: String, under directory: URL) -> URL? {
        guard let safePath = normalizedRemoteFilePath(path) else { return nil }
        let base = directory.standardizedFileURL
        let destination =
            safePath
            .split(separator: "/")
            .reduce(base) { partial, component in
                partial.appendingPathComponent(String(component))
            }
            .standardizedFileURL

        guard isContained(destination, in: base),
            existingParentChainIsContained(for: destination, under: base)
        else {
            return nil
        }
        return destination
    }

    private static func existingParentChainIsContained(for destination: URL, under base: URL) -> Bool {
        let fileManager = FileManager.default
        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        let baseComponents = base.pathComponents
        let parentComponents = parent.pathComponents
        guard parentComponents.count >= baseComponents.count,
            Array(parentComponents.prefix(baseComponents.count)) == baseComponents
        else {
            return false
        }

        var current = base
        for component in parentComponents.dropFirst(baseComponents.count) {
            current = current.appendingPathComponent(component, isDirectory: true)
            guard isContained(current.standardizedFileURL, in: base) else { return false }
            guard fileManager.fileExists(atPath: current.path) else { break }
            guard (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) == nil else {
                return false
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                isContained(current.resolvingSymlinksInPath().standardizedFileURL, in: resolvedBase)
            else {
                return false
            }
        }
        return true
    }

    private static func isContained(_ url: URL, in directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }

    private func fetchModelMeta(repoId: String) async -> ModelMeta? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models/\(repoId)"
        comps.queryItems = [URLQueryItem(name: "full", value: "1")]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await GlobalProxySettings.makeSession().data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(ModelMeta.self, from: data)
        } catch {
            return nil
        }
    }

    private func hasRequiredFiles(meta: ModelMeta) -> Bool {
        guard let siblings = meta.siblings else { return false }
        var hasConfig = false
        var hasWeights = false
        var hasTokenizer = false
        for s in siblings {
            let f = s.rfilename.lowercased()
            if f == "config.json" { hasConfig = true }
            if f.hasSuffix(".safetensors") { hasWeights = true }
            if f == "tokenizer.json" || f == "tokenizer.model" || f == "spiece.model" || f == "vocab.json"
                || f == "vocab.txt"
            {
                hasTokenizer = true
            }
        }
        return hasConfig && hasWeights && hasTokenizer
    }

    private static func repoIdHasMLXArtifactHint(_ lowerRepoId: String) -> Bool {
        lowerRepoId.contains("mlx")
            || lowerRepoId.contains("-mxfp") || lowerRepoId.contains("_mxfp")
            || lowerRepoId.contains("-jang") || lowerRepoId.contains("_jang")
            || lowerRepoId.contains("-jangtq") || lowerRepoId.contains("_jangtq")
            || lowerRepoId.contains("turboquant")
    }
}

// MARK: - Simple glob matcher
struct Glob {
    private let regex: NSRegularExpression

    init?(_ pattern: String) {
        // Escape regex metacharacters except * and ? which we will translate
        var escaped = ""
        for ch in pattern {
            switch ch {
            case "*": escaped += ".*"
            case "?": escaped += "."
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
                escaped += "\\\(ch)"
            default:
                escaped += String(ch)
            }
        }
        do {
            regex = try NSRegularExpression(pattern: "^\(escaped)$")
        } catch {
            return nil
        }
    }

    func matches(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
