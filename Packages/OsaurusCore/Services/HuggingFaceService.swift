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
        /// Base model(s) this repo was derived from, when the card declares
        /// them (e.g. a quantized repo pointing at the upstream weights).
        let baseModels: [String]
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
            /// `base_model` may be a single string or an array in HF cards.
            let base_model: StringOrArray?
        }
    }

    /// Decodes a JSON field that HF sometimes serializes as a single
    /// string and sometimes as an array of strings (e.g. `base_model`).
    enum StringOrArray: Decodable {
        case single(String)
        case many([String])

        var values: [String] {
            switch self {
            case .single(let s): return s.isEmpty ? [] : [s]
            case .many(let a): return a.filter { !$0.isEmpty }
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .single(s)
            } else if let a = try? container.decode([String].self) {
                self = .many(a)
            } else {
                self = .many([])
            }
        }
    }

    struct MatchedFile {
        let path: String
        let size: Int64
        /// True when this file matches Osaurus's download patterns — i.e.
        /// it's part of what actually gets written to disk on download.
        /// `false` for repo extras (READMEs, alternate formats, etc.).
        var isDownloaded: Bool = true
    }

    private init() {}

    /// A single file node from the HF repo tree.
    private struct TreeNode: Decodable {
        let path: String
        let type: String?
        let size: Int64?
        let lfs: LFS?
        struct LFS: Decodable { let size: Int64? }

        /// Best-known byte size (`lfs.size` for large weights).
        var bestSize: Int64 { size ?? lfs?.size ?? 0 }
    }

    /// Fetch the full recursive file tree for a repo. Returns `nil` on any
    /// failure (network, decode, empty tree). Shared by the download-set
    /// and full-listing helpers below.
    private func fetchTree(repoId: String) async -> [TreeNode]? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models/\(repoId)/tree/main"
        comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await GlobalProxySettings.sharedSession().data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            let nodes = try JSONDecoder().decode([TreeNode].self, from: data)
            return nodes.isEmpty ? nil : nodes
        } catch {
            return nil
        }
    }

    /// Fetch files from a Hugging Face repo that match the given glob patterns.
    /// Files whose last path component appears in `excludedFiles` are skipped.
    func fetchMatchingFiles(
        repoId: String,
        patterns: [String],
        excludedFiles: Set<String> = []
    ) async -> [MatchedFile]? {
        guard let nodes = await fetchTree(repoId: repoId) else { return nil }
        let matchers = patterns.compactMap { Glob($0) }
        let files = nodes.compactMap { node -> MatchedFile? in
            if node.type == "directory" { return nil }
            guard let safePath = Self.normalizedRemoteFilePath(node.path) else { return nil }
            let filename = (safePath as NSString).lastPathComponent
            if excludedFiles.contains(filename) { return nil }
            let matched = matchers.contains { $0.matches(filename) }
            guard matched else { return nil }
            let sz = node.bestSize
            guard sz > 0 else { return nil }
            return MatchedFile(path: safePath, size: sz)
        }
        return files.isEmpty ? nil : files
    }

    /// Fetch every file in a repo (not just the download set), each marked
    /// with whether Osaurus would download it. Used by the detail modal's
    /// "Files" section. Sorted largest-first so weights lead.
    func fetchAllFiles(
        repoId: String,
        downloadPatterns: [String],
        excludedFiles: Set<String> = []
    ) async -> [MatchedFile]? {
        guard let nodes = await fetchTree(repoId: repoId) else { return nil }
        let matchers = downloadPatterns.compactMap { Glob($0) }
        let files = nodes.compactMap { node -> MatchedFile? in
            if node.type == "directory" { return nil }
            guard let safePath = Self.normalizedRemoteFilePath(node.path) else { return nil }
            let filename = (safePath as NSString).lastPathComponent
            let matched =
                !excludedFiles.contains(filename) && matchers.contains { $0.matches(filename) }
            return MatchedFile(path: safePath, size: node.bestSize, isDownloaded: matched)
        }
        let sorted = files.sorted { $0.size > $1.size }
        return sorted.isEmpty ? nil : sorted
    }

    /// Fetch a repo's README (model card) markdown from
    /// `https://huggingface.co/<repoId>/raw/main/README.md`, with the
    /// leading YAML front-matter block stripped so only the human-readable
    /// card body renders. Returns `nil` when the repo has no README or the
    /// request fails.
    func fetchReadme(repoId: String) async -> String? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/\(repoId)/raw/main/README.md"
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("text/plain", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await GlobalProxySettings.sharedSession().data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
                let raw = String(data: data, encoding: .utf8)
            else { return nil }
            let stripped = Self.strippingFrontMatter(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            // Normalize HTML to markdown first (turning `<img>` into `![](…)`),
            // then resolve every relative image path in one pass.
            let normalized = Self.normalizingModelCardHTML(stripped)
            return Self.resolvingRelativeImageURLs(in: normalized, repoId: repoId)
        } catch {
            return nil
        }
    }

    /// Converts the common HTML constructs HF model cards use into markdown
    /// so they render instead of showing as raw tags. The chat markdown
    /// engine has no HTML renderer, so cards that wrap their banner in
    /// `<p align="center"><img .../></p>` (or use `<a>`, `<br>`, `<picture>`)
    /// otherwise leak literal HTML into the rendered body.
    ///
    /// Only transforms text *outside* fenced code blocks so HTML shown as a
    /// code sample is left intact.
    static func normalizingModelCardHTML(_ markdown: String) -> String {
        // Split on ``` fences: even indices are prose, odd indices are inside
        // a fenced block. Rejoin with the same delimiter afterwards.
        let segments = markdown.components(separatedBy: "```")
        let transformed = segments.enumerated().map { index, segment -> String in
            index.isMultiple(of: 2) ? normalizeHTMLProse(segment) : segment
        }
        return transformed.joined(separator: "```")
    }

    private static func normalizeHTMLProse(_ input: String) -> String {
        var s = input

        // `<img ... src="X" ... alt="Y">` -> standalone markdown image.
        s = replacingMatches(in: s, pattern: #"<img\b[^>]*>"#) { tag in
            let raw = htmlAttribute("src", in: tag) ?? htmlAttribute("data-src", in: tag)
            guard let raw, !raw.isEmpty else { return "" }
            // Markdown image URLs can't contain raw spaces, so encode them.
            let url = raw.replacingOccurrences(of: " ", with: "%20")
            let alt = htmlAttribute("alt", in: tag) ?? ""
            return "\n\n![\(alt)](\(url))\n\n"
        }

        // `<a href="url">text</a>` -> `[text](url)`.
        s = replacingMatches(
            in: s,
            pattern: #"<a\b[^>]*?\bhref\s*=\s*["'][^"']*["'][^>]*>[\s\S]*?</a>"#
        ) { anchor in
            let href = htmlAttribute("href", in: anchor) ?? ""
            // Inner text = the anchor with every tag (open/close/nested)
            // stripped, so we never re-emit HTML.
            let inner =
                anchor
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if href.isEmpty { return inner }
            return inner.isEmpty ? href : "[\(inner)](\(href))"
        }

        // Line breaks.
        s = s.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        // Strip layout/inline wrapper tags that otherwise render as text.
        s = s.replacingOccurrences(
            of:
                #"</?(?:p|div|center|span|picture|source|figure|figcaption|small|font|sub|sup|u|a)\b[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Collapse the blank-line runs the substitutions can introduce.
        s = s.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return s
    }

    /// Extracts an HTML attribute value (`name="value"` / `name='value'`)
    /// from a single tag string. Case-insensitive on the attribute name.
    private static func htmlAttribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(
                in: tag,
                range: NSRange(tag.startIndex..., in: tag)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[range])
    }

    /// Replaces every whole-match of `pattern` using `transform`, which
    /// receives the matched substring. Matches run in reverse so earlier
    /// ranges stay valid as later ones are rewritten.
    private static func replacingMatches(
        in input: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            )
        else { return input }
        var output = input
        let matches = regex.matches(
            in: input,
            range: NSRange(input.startIndex..., in: input)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: transform(String(output[range])))
        }
        return output
    }

    /// Rewrites repo-relative markdown image references (`![alt](path)`) in a
    /// model card to absolute Hugging Face `resolve/main/` URLs so they
    /// actually load. HF READMEs routinely use relative paths (e.g.
    /// `assets/banner.png`, `./fig.png`) that carry no scheme/host and can't
    /// be fetched directly. Absolute or protocol-relative/data URLs are left
    /// untouched. (HTML `<img>` is converted to markdown first by
    /// `normalizingModelCardHTML`, so this only handles markdown.)
    static func resolvingRelativeImageURLs(in markdown: String, repoId: String) -> String {
        let base = "https://huggingface.co/\(repoId)/resolve/main/"

        func absolutize(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return raw }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://")
                || lower.hasPrefix("data:") || lower.hasPrefix("mailto:")
                || trimmed.hasPrefix("//")
            {
                return trimmed
            }
            // Drop a leading `./` or `/` so we don't double the base path.
            var path = trimmed
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasPrefix("/") { path.removeFirst() }
            return base + path
        }

        // Markdown images: `![alt](url "optional title")`.
        return rewriteCaptureGroup(
            in: markdown,
            pattern: #"(!\[[^\]]*\]\()([^)\s]+)"#,
            group: 2,
            transform: absolutize
        )
    }

    /// Replaces capture `group` of every `pattern` match in `input` using
    /// `transform`. Matches are applied in reverse so earlier ranges stay
    /// valid as later ones are rewritten.
    private static func rewriteCaptureGroup(
        in input: String,
        pattern: String,
        group: Int,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return input }
        var output = input
        let matches = regex.matches(
            in: input,
            options: [],
            range: NSRange(input.startIndex..., in: input)
        )
        for match in matches.reversed() {
            guard match.numberOfRanges > group,
                let range = Range(match.range(at: group), in: output)
            else { continue }
            output.replaceSubrange(range, with: transform(String(output[range])))
        }
        return output
    }

    /// Removes a leading YAML front-matter block (`---` ... `---`) from a
    /// model card. HF cards open with metadata (license, tags, base_model)
    /// that we already surface as structured fields, so it's noise in the
    /// rendered body. Leaves the text untouched when there's no front-matter.
    static func strippingFrontMatter(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard let first = lines.first,
            first.trimmingCharacters(in: .whitespaces) == "---"
        else { return markdown }
        // Find the closing delimiter after the opening one.
        for index in 1 ..< lines.count
        where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(index + 1)...].joined(separator: "\n")
        }
        // Unterminated front-matter: return as-is rather than eating the file.
        return markdown
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
            let (data, response) = try await GlobalProxySettings.sharedSession().data(for: req)
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
                baseModels: raw.cardData?.base_model?.values ?? [],
                isVLM: isVLM
            )
        } catch {
            return nil
        }
    }

    // MARK: - Org / author model listing

    /// One row from the `/api/models?author=…` listing endpoint. Lightweight
    /// (no file sizes — the listing endpoint omits them); callers resolve
    /// sizes lazily via the tree API when needed.
    struct OrgModelListing: Sendable {
        let id: String
        let pipelineTag: String?
        let tags: [String]
        let downloads: Int?
        let lastModified: String?
    }

    private struct OrgModelRow: Decodable {
        let id: String
        let pipeline_tag: String?
        let tags: [String]?
        let downloads: Int?
        let lastModified: String?
    }

    /// List public models published by an HF org/author, sorted by downloads
    /// (most-popular first). Returns `[]` on any failure (network, non-2xx,
    /// decode) so callers can treat it as "nothing found". `full=1` includes
    /// `pipeline_tag` + `tags`, which callers use to classify repos (image vs
    /// LLM).
    func fetchModels(author: String, limit: Int = 200) async -> [OrgModelListing] {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models"
        comps.queryItems = [
            URLQueryItem(name: "author", value: trimmed),
            URLQueryItem(name: "full", value: "1"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await GlobalProxySettings.sharedSession().data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return []
            }
            let rows = try JSONDecoder().decode([OrgModelRow].self, from: data)
            return rows.map {
                OrgModelListing(
                    id: $0.id,
                    pipelineTag: $0.pipeline_tag,
                    tags: $0.tags ?? [],
                    downloads: $0.downloads,
                    lastModified: $0.lastModified
                )
            }
        } catch {
            return []
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
            let (data, response) = try await GlobalProxySettings.sharedSession().data(for: req)
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
