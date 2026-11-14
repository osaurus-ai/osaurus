//
//  ChatImportSourceResolver.swift
//  osaurus
//
//  Turns what the user pasted into an `ChatImportBundle`: links are fetched
//  safely, GitHub repo / tree / blob / raw links come down as one archive
//  (so skill scripts and plugin folders arrive intact), deep-link payloads
//  are percent- and base64-decoded, and everything readable is split into
//  numbered documents for the reader. Only stable standards are parsed
//  here; the shape of arbitrary setup pages is the reader's job.
//

import Foundation

enum ChatImportSourceResolver {
    static let maxLinks = 6
    static let maxDocuments = 24
    static let maxDocumentChars = 120_000
    static let maxSkillPackages = 60
    static let archivePolicy = SkillImportPolicy(
        maxArchiveBytes: Int64(SafeImportFetcher.archiveLimitBytes),
        maxEntryBytes: 20 * 1024 * 1024,
        maxEntryCount: 40_000,
        maxPathDepth: 40
    )

    /// Resolve `source` (the tool argument) and the user's own message.
    static func resolve(source: String, userText: String?) async -> ChatImportBundle {
        let message = userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let argument = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // The user's words win: a model may paraphrase or drop a link, but
        // values are only ever grounded in what the user actually sent. The
        // argument counts only when there is no user message (evals, API).
        let userWords = message.isEmpty ? argument : message
        let combined = [message, argument].filter { !$0.isEmpty }.joined(separator: "\n")
        var bundle = ChatImportBundle(userText: userWords)
        var counter = DocumentCounter()

        var links: [ChatImportLink] = []
        for link in ChatImportLinkScanner.links(in: combined) where !links.contains(where: { $0.raw == link.raw }) {
            links.append(link)
            if links.count >= maxLinks { break }
        }
        let snippet = ChatImportLinkScanner.removingLinks(from: userWords)
        if snippet.count >= 24, ChatImportLinkScanner.looksLikeSetupText(snippet) {
            bundle.documents.append(counter.next(origin: "your message", path: nil, text: userWords))
        }

        let configValues = ChatImportLinkScanner.serverValueLinks(in: combined)
        for link in links {
            if case .web = link.kind, configValues.contains(link.raw) { continue }
            await resolve(link: link, into: &bundle, counter: &counter)
        }
        bundle.sources = links.map(\.raw)
        return bundle
    }

    // MARK: - Links

    private static func resolve(link: ChatImportLink, into bundle: inout ChatImportBundle, counter: inout DocumentCounter) async {
        switch link.kind {
        case .ssh:
            bundle.refusals.append(.sshRemote(link.raw))
        case .deepLink:
            for (index, payload) in ChatImportDecoding.payloads(in: link.raw).enumerated() {
                bundle.documents.append(
                    counter.next(origin: link.raw, path: index == 0 ? "link payload" : "link payload \(index + 1)", text: payload))
            }
            if let templateURL = URL(string: link.raw), templateURL.scheme?.lowercased() == "osaurus",
                templateURL.host?.lowercased() == TemplateImportRouter.deepLinkHost
            {
                if TemplateImportRouter.remoteURL(from: templateURL) == nil {
                    bundle.refusals.append(.nonStoreTemplate(link.raw))
                } else {
                    bundle.storeTemplateLinks.append(templateURL)
                }
            }
        case .web(let url):
            if let refusal = refusal(for: url, raw: link.raw) {
                bundle.refusals.append(refusal)
                return
            }
            if let github = GitHubLocation.parse(url) {
                await resolveGitHub(github, raw: link.raw, into: &bundle, counter: &counter)
            } else {
                await resolvePage(url, raw: link.raw, into: &bundle, counter: &counter, followLinks: true)
            }
            for (index, payload) in ChatImportDecoding.payloads(in: link.raw).enumerated() {
                bundle.documents.append(
                    counter.next(origin: link.raw, path: "link payload \(index + 1)", text: payload))
            }
        case .insecure:
            bundle.refusals.append(.insecureURL(link.raw))
        }
    }

    static func refusal(for url: URL, raw: String) -> ChatImportRefusal? {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        if host == "dev.azure.com" || host.hasSuffix(".visualstudio.com") { return .azureDevOps(raw) }
        if path.hasSuffix("/.well-known/agent.json") || path.hasSuffix("/.well-known/agent-card.json")
            || path.hasSuffix("/agent-card.json")
        {
            return .a2aAgentCard(raw)
        }
        if path.hasSuffix("." + TemplateFileExport.fileExtension.lowercased()),
            !WorkflowsRegistryAPIClient.isRegistryTemplateURL(url)
        {
            return .nonStoreTemplate(raw)
        }
        return nil
    }

    /// One web page or raw file. `followLinks` allows a single extra hop to
    /// setup files the page links to (a SKILL.md, an MCP config, a repo).
    private static func resolvePage(
        _ url: URL, raw: String, into bundle: inout ChatImportBundle, counter: inout DocumentCounter, followLinks: Bool
    ) async {
        guard bundle.documents.count < maxDocuments else { return }
        do {
            let fetched = try await SafeImportFetcher.fetchText(url)
            let text = String(fetched.text.prefix(maxDocumentChars))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            bundle.documents.append(counter.next(origin: raw, path: nil, text: text))
            guard followLinks else { return }
            var followed = 0
            for next in ChatImportLinkScanner.links(in: text) where followed < 3 {
                guard case .web(let nextURL) = next.kind, nextURL != url, isSetupFileLink(nextURL) else { continue }
                followed += 1
                if let github = GitHubLocation.parse(nextURL) {
                    await resolveGitHub(github, raw: next.raw, into: &bundle, counter: &counter)
                } else {
                    await resolvePage(nextURL, raw: next.raw, into: &bundle, counter: &counter, followLinks: false)
                }
            }
        } catch let error as SafeImportFetcher.FetchError {
            bundle.refusals.append(refusal(from: error, raw: raw))
        } catch {
            bundle.refusals.append(.fetchFailed(raw, reason: error.localizedDescription))
        }
    }

    /// Links on a page worth one more hop: agent setup files by name.
    static func isSetupFileLink(_ url: URL) -> Bool {
        let last = url.lastPathComponent.lowercased()
        if ["skill.md", "llms.txt", ".mcp.json", "mcp.json", "agents.md", "claude.md"].contains(last) { return true }
        if url.host?.lowercased() == "raw.githubusercontent.com" { return last.hasSuffix(".md") || last.hasSuffix(".json") }
        if let gh = GitHubLocation.parse(url), gh.tail.isEmpty || gh.kind == .tree { return true }
        return false
    }

    private static func refusal(from error: SafeImportFetcher.FetchError, raw: String) -> ChatImportRefusal {
        switch error {
        case .insecure, .redirectRefused: return .insecureURL(raw)
        case .tooLarge: return .tooLarge(raw)
        case .http(_, let status): return .fetchFailed(raw, reason: "HTTP \(status)")
        case .network(_, let reason): return .fetchFailed(raw, reason: reason)
        }
    }

    // MARK: - GitHub

    private static func resolveGitHub(
        _ location: GitHubLocation, raw: String, into bundle: inout ChatImportBundle, counter: inout DocumentCounter
    ) async {
        guard bundle.workDirectories.count < 3 else { return }
        var lastStatus = 0
        for candidate in location.candidates {
            let archive = "https://github.com/\(location.owner)/\(location.repo)/archive/\(candidate.ref ?? "HEAD").zip"
            guard let archiveURL = URL(string: archive) else { continue }
            let downloaded: (file: URL, status: Int)
            do {
                downloaded = try await SafeImportFetcher.download(archiveURL)
            } catch let error as SafeImportFetcher.FetchError {
                bundle.refusals.append(refusal(from: error, raw: raw))
                return
            } catch {
                bundle.refusals.append(.fetchFailed(raw, reason: error.localizedDescription))
                return
            }
            lastStatus = downloaded.status
            guard (200..<300).contains(downloaded.status) else {
                try? FileManager.default.removeItem(at: downloaded.file)
                continue
            }
            defer { try? FileManager.default.removeItem(at: downloaded.file) }
            do {
                let root = try await extract(downloaded.file)
                bundle.workDirectories.append(root)
                let scope = try scopeDirectory(in: root, path: candidate.path)
                ChatImportRepoWalker.collect(
                    scope: scope.url, isFile: scope.isFile, origin: raw,
                    repo: ChatImportPluginRepo(
                        url: "https://github.com/\(location.owner)/\(location.repo)", owner: location.owner,
                        name: location.repo),
                    into: &bundle, counter: &counter)
            } catch {
                bundle.refusals.append(.fetchFailed(raw, reason: error.localizedDescription))
            }
            return
        }
        bundle.refusals.append(lastStatus == 404 || lastStatus == 0 ? .privateOrMissingRepo(raw) : .fetchFailed(raw, reason: "HTTP \(lastStatus)"))
    }

    private static func extract(_ zip: URL) async throws -> URL {
        try archivePolicy.validateArchiveBeforeExtraction(zip)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try await FileManager.default.unzipItem(at: zip, to: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }

    /// The archive's single top folder, narrowed to `path` when the link
    /// named a folder or file inside the repo.
    private static func scopeDirectory(in root: URL, path: String) throws -> (url: URL, isFile: Bool) {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__MACOSX") }
        let top = entries.count == 1 ? entries[0] : root
        guard !path.isEmpty else { return (top, false) }
        let target = top.appendingPathComponent(path).standardizedFileURL
        let base = top.standardizedFileURL.path
        guard target.path.hasPrefix(base) else { return (top, false) }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else { return (top, false) }
        return (target, !isDir.boolValue)
    }

    struct DocumentCounter {
        private var n = 0
        mutating func next(origin: String, path: String?, text: String) -> ChatImportDocument {
            n += 1
            return ChatImportDocument(
                id: "d\(n)", origin: origin, path: path, text: String(text.prefix(ChatImportSourceResolver.maxDocumentChars)))
        }
    }
}

// MARK: - GitHub links

struct GitHubLocation: Equatable, Sendable {
    enum Kind: Sendable { case repo, tree, blob, raw }

    let owner: String
    let repo: String
    let kind: Kind
    /// Path segments after `tree` / `blob` (raw: after the repo). The ref
    /// may itself contain slashes, so splits are tried in order.
    let tail: [String]

    struct Candidate: Equatable, Sendable {
        let ref: String?
        let path: String
    }

    var candidates: [Candidate] {
        guard !tail.isEmpty else { return [Candidate(ref: nil, path: "")] }
        return (1...min(3, tail.count)).map { split in
            Candidate(ref: tail.prefix(split).joined(separator: "/"), path: tail.dropFirst(split).joined(separator: "/"))
        }
    }

    static func parse(_ url: URL) -> GitHubLocation? {
        let host = (url.host ?? "").lowercased()
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if host == "raw.githubusercontent.com" {
            guard parts.count >= 3 else { return nil }
            return GitHubLocation(owner: parts[0], repo: parts[1], kind: .raw, tail: Array(parts.dropFirst(2)))
        }
        guard host == "github.com" || host == "www.github.com", parts.count >= 2 else { return nil }
        let reserved: Set<String> = [
            "settings", "orgs", "marketplace", "explore", "topics", "features", "login", "sponsors", "apps",
        ]
        guard !reserved.contains(parts[0].lowercased()) else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
            return GitHubLocation(
                owner: parts[0], repo: repo, kind: parts[2] == "tree" ? .tree : .blob, tail: Array(parts.dropFirst(3)))
        }
        guard parts.count == 2 else { return nil }
        return GitHubLocation(owner: parts[0], repo: repo, kind: .repo, tail: [])
    }
}

// MARK: - Repository walk

/// Collects the standard files from an extracted repository: skill
/// folders, plugin marketplaces, MCP configs, agent and command markdown,
/// and the top-level docs a reader may need.
enum ChatImportRepoWalker {
    static let mcpConfigNames: Set<String> = [
        ".mcp.json", "mcp.json", "claude_desktop_config.json", "mcp_config.json",
    ]
    static let rootDocNames = [
        "readme.md", "agents.md", "claude.md", "gemini.md", "llms.txt", "install.md", "setup.md",
    ]

    static func collect(
        scope: URL, isFile: Bool, origin: String, repo: ChatImportPluginRepo,
        into bundle: inout ChatImportBundle, counter: inout ChatImportSourceResolver.DocumentCounter
    ) {
        let fm = FileManager.default
        if isFile {
            let text = (try? String(contentsOf: scope, encoding: .utf8)) ?? ""
            if scope.lastPathComponent.lowercased() == "skill.md" {
                bundle.skillPackages.append(
                    ChatImportSkillPackage(
                        directory: scope.deletingLastPathComponent(), relativePath: scope.lastPathComponent,
                        markdown: text, origin: origin))
            } else {
                bundle.documents.append(counter.next(origin: origin, path: scope.lastPathComponent, text: text))
            }
            return
        }

        if fm.fileExists(atPath: scope.appendingPathComponent(".claude-plugin/marketplace.json").path)
            || fm.fileExists(atPath: scope.appendingPathComponent(".claude-plugin/plugin.json").path)
        {
            bundle.pluginRepos.append(repo)
            return
        }

        guard
            let enumerator = fm.enumerator(
                at: scope, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants])
        else { return }
        let base = scope.standardizedFileURL.path
        var skillDirs: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let lower = name.lowercased()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if ["node_modules", ".git", "vendor", "dist", "build", ".venv", "__pycache__"].contains(lower) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
            let depth = relative.split(separator: "/").count
            if lower == "skill.md" {
                skillDirs.append(url.deletingLastPathComponent())
                continue
            }
            if mcpConfigNames.contains(lower) || relative.hasSuffix(".cursor/mcp.json") || relative.hasSuffix(".vscode/mcp.json") {
                appendDocument(url, relative: relative, origin: origin, into: &bundle, counter: &counter)
                continue
            }
            if ChatImportFastPaths.isAgentFile(relative) || ChatImportFastPaths.isCommandFile(relative)
                || (lower.hasSuffix(".mdc") && relative.lowercased().contains(".cursor/rules/"))
            {
                appendDocument(url, relative: relative, origin: origin, into: &bundle, counter: &counter)
                continue
            }
            if depth == 1, rootDocNames.contains(lower) {
                appendDocument(url, relative: relative, origin: origin, into: &bundle, counter: &counter)
            }
        }
        for dir in skillDirs.sorted(by: { $0.path < $1.path }).prefix(ChatImportSourceResolver.maxSkillPackages) {
            let file = dir.appendingPathComponent("SKILL.md")
            let alt = dir.appendingPathComponent("skill.md")
            guard let text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: alt, encoding: .utf8))
            else { continue }
            let relative = String(dir.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
            bundle.skillPackages.append(
                ChatImportSkillPackage(directory: dir, relativePath: relative.isEmpty ? "." : relative, markdown: text, origin: origin))
        }
    }

    private static func appendDocument(
        _ url: URL, relative: String, origin: String, into bundle: inout ChatImportBundle,
        counter: inout ChatImportSourceResolver.DocumentCounter
    ) {
        guard bundle.documents.count < ChatImportSourceResolver.maxDocuments,
            let text = try? String(contentsOf: url, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        bundle.documents.append(counter.next(origin: origin, path: relative, text: text))
    }
}

// MARK: - Link scanning

struct ChatImportLink: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case web(URL)
        case insecure
        case ssh
        /// A custom-scheme install link (`cursor://…`, `vscode:mcp/…`,
        /// `osaurus://…`). Only its decoded payload is read.
        case deepLink
    }

    let raw: String
    let kind: Kind
}

enum ChatImportLinkScanner {
    private static let urlPattern =
        #"(?:https?://|git@[A-Za-z0-9.-]+:|ssh://|[a-z][a-z0-9+.-]{2,}:(?://)?(?=[A-Za-z0-9%]))[^\s<>"'`\]\)]+"#

    static func links(in text: String) -> [ChatImportLink] {
        guard let regex = try? NSRegularExpression(pattern: urlPattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [ChatImportLink] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var raw = ns.substring(with: match.range)
            while let last = raw.last, ".,;:!?".contains(last) { raw.removeLast() }
            guard !raw.isEmpty, seen.insert(raw).inserted, let kind = classify(raw) else { continue }
            out.append(ChatImportLink(raw: raw, kind: kind))
        }
        for bare in bareGitHubLinks(in: text) where seen.insert(bare).inserted {
            if let url = URL(string: "https://" + bare) { out.append(ChatImportLink(raw: bare, kind: .web(url))) }
        }
        return out
    }

    static func classify(_ raw: String) -> ChatImportLink.Kind? {
        let lower = raw.lowercased()
        if lower.hasPrefix("git@") || lower.hasPrefix("ssh://") { return .ssh }
        if lower.hasPrefix("http://") { return .insecure }
        if lower.hasPrefix("https://") {
            guard let url = URL(string: raw), SafeImportFetcher.isSecure(url) else { return nil }
            return .web(url)
        }
        let scheme = lower.prefix { $0 != ":" }
        let ignored: Set<String> = ["mailto", "tel", "data", "javascript", "file", "about", "localhost", "std"]
        guard !ignored.contains(String(scheme)), lower.contains("?") || lower.contains("/") else { return nil }
        // Custom schemes only matter when they carry a payload to decode.
        guard !ChatImportDecoding.payloads(in: raw).isEmpty || scheme == "osaurus" else { return nil }
        return .deepLink
    }

    /// `github.com/owner/repo` written without a scheme.
    static func bareGitHubLinks(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![/\w.])github\.com/[\w.-]+/[\w.-]+(?:/[^\s<>"'`\]\)]*)?"#)
        else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            var raw = ns.substring(with: $0.range)
            while let last = raw.last, ".,;:!?".contains(last) { raw.removeLast() }
            return raw
        }
    }

    /// Links written inside a `{ … }` config block or an `… mcp add …`
    /// command are values to install (a server endpoint, often with a key in
    /// it), not pages to read, so they are never fetched before the user
    /// approves.
    static func serverValueLinks(in text: String) -> Set<String> {
        let commands = text.split(whereSeparator: \.isNewline).filter { $0.lowercased().contains("mcp add") }
        var blocks = commands.map(String.init)
        var depth = 0
        var start = text.startIndex
        for index in text.indices {
            switch text[index] {
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}" where depth > 0:
                depth -= 1
                if depth == 0 { blocks.append(String(text[start...index])) }
            default:
                continue
            }
        }
        return Set(blocks.flatMap { links(in: $0).map(\.raw) })
    }

    static func removingLinks(from text: String) -> String {
        var out = text
        for link in links(in: text) { out = out.replacingOccurrences(of: link.raw, with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether pasted text (links removed) carries setup content of its
    /// own — a config block, a command, frontmatter — rather than a bare
    /// request like "set this up".
    static func looksLikeSetupText(_ text: String) -> Bool {
        if text.contains("{") && text.contains("}") { return true }
        if text.contains("```") || text.hasPrefix("---") { return true }
        let markers = ["npx ", "uvx ", "docker run", "pip install", "npm install", "mcp add", "command:", "args:"]
        let lower = text.lowercased()
        if markers.contains(where: lower.contains) { return true }
        return text.split(separator: "\n").count >= 4
    }
}

// MARK: - Payload decoding

/// Generic decoding of install-link payloads: every query value is
/// percent-decoded, and values that are base64 of readable text are
/// decoded too. Nothing here knows a particular editor's link format.
enum ChatImportDecoding {
    static func payloads(in raw: String) -> [String] {
        var values: [String] = []
        if let components = URLComponents(string: raw) {
            for item in components.queryItems ?? [] {
                if let value = item.value { values.append(value) }
            }
        }
        // Schemes like `vscode:mcp/install?{json}` put a raw payload after `?`.
        if let q = raw.firstIndex(of: "?") {
            let tail = String(raw[raw.index(after: q)...])
            if !tail.contains("=") || tail.hasPrefix("%7B") || tail.hasPrefix("{") {
                values.append(tail.removingPercentEncoding ?? tail)
            }
        }
        var out: [String] = []
        var named: String?
        if let components = URLComponents(string: raw) {
            named = components.queryItems?.first { $0.name.lowercased() == "name" }?.value
        }
        for value in values {
            for decoded in decode(value) where isReadablePayload(decoded) && !out.contains(decoded) {
                out.append(decoded)
            }
        }
        if let named, !out.isEmpty {
            out = out.map { payload in
                payload.trimmingCharacters(in: .whitespaces).hasPrefix("{") && !payload.contains("\"name\"")
                    ? "{\"mcpServers\": {\"\(named)\": \(payload)}}" : payload
            }
        }
        return out
    }

    static func decode(_ value: String) -> [String] {
        var out: [String] = []
        let percent = value.removingPercentEncoding ?? value
        out.append(percent)
        if let base64 = base64Text(percent) { out.append(base64) }
        return out
    }

    static func base64Text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16, trimmed.range(of: #"^[A-Za-z0-9+/_-]+=*$"#, options: .regularExpression) != nil
        else { return nil }
        var normalized = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized += "=" }
        guard let data = Data(base64Encoded: normalized), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// JSON or multi-word text; short tokens and ids are not payloads.
    static func isReadablePayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
        }
        return false
    }
}
