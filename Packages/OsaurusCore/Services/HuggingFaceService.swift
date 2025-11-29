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

    private init() {}

    /// Estimate the total size for files matching provided patterns.
    /// Uses Hugging Face REST API endpoints that return directory listings with sizes.
    func estimateTotalSize(repoId: String, patterns: [String]) async -> Int64? {
        // Use tree endpoint: /api/models/{repo}/tree/main?recursive=1
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
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            let nodes = try JSONDecoder().decode([TreeNode].self, from: data)
            if nodes.isEmpty { return nil }
            let matchers = patterns.compactMap { Glob($0) }
            let total = nodes.reduce(Int64(0)) { acc, node in
                // Only sum files, not directories
                if node.type == "directory" { return acc }
                let filename = (node.path as NSString).lastPathComponent
                let matched = matchers.contains { $0.matches(filename) }
                guard matched else { return acc }
                let sz = node.size ?? node.lfs?.size ?? 0
                return acc + sz
            }
            return total > 0 ? total : nil
        } catch {
            return nil
        }
    }

    /// Determine if a Hugging Face repo is MLX-compatible using repository metadata.
    /// Prefers explicit tags (e.g., "mlx", "apple-mlx", "library:mlx").
    /// Falls back to id hints and required file presence when tags are unavailable.
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

        // Heuristic fallback: repository naming suggests MLX and core files exist
        if lower.contains("mlx") && hasRequiredFiles(meta: meta) {
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
            let (data, response) = try await URLSession.shared.data(for: req)
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

            // Determine if VLM based on tags or pipeline
            let isVLM = detectVLMFromMetadata(tags: tags, pipelineTag: raw.pipeline_tag)

            // Extract model type from config or cardData
            let modelType = raw.config?.model_type ?? raw.cardData?.model_type

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

    /// Detect if model is a VLM based on HF metadata
    private func detectVLMFromMetadata(tags: [String], pipelineTag: String?) -> Bool {
        // Check pipeline tag
        if let pipeline = pipelineTag?.lowercased() {
            let vlmPipelines = [
                "image-to-text", "visual-question-answering", "image-text-to-text", "document-question-answering",
            ]
            if vlmPipelines.contains(pipeline) {
                return true
            }
        }

        // Check tags for VLM indicators
        let lowerTags = tags.map { $0.lowercased() }
        let vlmTags = ["vision", "multimodal", "vlm", "image-text", "llava", "vqa", "image-to-text"]
        for vlmTag in vlmTags {
            if lowerTags.contains(where: { $0.contains(vlmTag) }) {
                return true
            }
        }

        return false
    }

    // MARK: - Private helpers
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
            let (data, response) = try await URLSession.shared.data(for: req)
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
