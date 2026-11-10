//
//  ChatImportFastPaths.swift
//  osaurus
//
//  Deterministic import for the formats that are real standards: Agent
//  Skills folders (`SKILL.md`), the MCP server config shape
//  (`mcpServers` / `servers`), Claude plugin marketplaces, and agent /
//  command markdown with frontmatter. Anything else goes to the reader.
//

import Foundation

enum ChatImportFastPaths {
    struct Outcome: Sendable {
        var items: [ChatImportItem] = []
        /// Documents fully understood here, so the reader can skip them.
        var consumedDocumentIds: Set<String> = []
    }

    static func run(_ bundle: ChatImportBundle) -> Outcome {
        var outcome = Outcome()
        var ids = ChatImportItemIds()

        for repo in bundle.pluginRepos {
            outcome.items.append(
                ChatImportItem(
                    id: ids.make("plugin", repo.name), kind: .plugin, name: "\(repo.owner)/\(repo.name)",
                    detail: L("Claude plugin marketplace: its skills, agents, commands, and MCP servers"),
                    origin: repo.url, payload: .plugin(repo), contentHash: ChatImportHash.of(repo.url)))
        }

        for package in bundle.skillPackages {
            if let item = skillItem(from: package, ids: &ids) { outcome.items.append(item) }
        }

        for document in bundle.documents {
            let path = location(of: document)
            let servers = ChatImportMCPShape.servers(in: document.text)
            if !servers.isEmpty {
                for server in servers {
                    let item = ChatImportMCPBuilder.item(from: server, origin: document.label, ids: &ids)
                    outcome.items.append(item)
                }
                if ChatImportMCPShape.isWholeConfig(document.text) { outcome.consumedDocumentIds.insert(document.id) }
                continue
            }
            if isAgentFile(path) || pastedKind(document) == .agent, let item = agentItem(from: document, ids: &ids) {
                outcome.items.append(item)
                outcome.consumedDocumentIds.insert(document.id)
                continue
            }
            if isCommandFile(path), let item = commandItem(from: document, ids: &ids) {
                outcome.items.append(item)
                outcome.consumedDocumentIds.insert(document.id)
                continue
            }
            if isSkillMarkdown(document), let item = skillItem(from: document, ids: &ids) {
                outcome.items.append(item)
                outcome.consumedDocumentIds.insert(document.id)
            }
        }
        return outcome
    }

    // MARK: - Skills

    static func skillItem(from package: ChatImportSkillPackage, ids: inout ChatImportItemIds) -> ChatImportItem? {
        let fallbackName = (package.relativePath as NSString).lastPathComponent
        let parsed = try? Skill.parseAnyFormat(from: package.markdown)
        let name = cleanName(parsed?.name ?? displayName(fromSlug: fallbackName))
        guard !name.isEmpty else { return nil }
        let instructions = parsed?.instructions ?? package.markdown
        var hashInput = package.markdown
        for file in packageFiles(package.directory) { hashInput += "\n\(file.path):\(file.size)" }
        let spec = ChatImportInstructionsSpec(
            name: name, description: parsed?.description ?? "", instructions: instructions,
            packageDirectory: package.directory)
        var item = ChatImportItem(
            id: ids.make("skill", name), kind: .skill, name: name, detail: parsed?.description ?? "",
            origin: package.origin + (package.relativePath == "." ? "" : " — \(package.relativePath)"),
            payload: .instructions(spec), contentHash: ChatImportHash.of(hashInput))
        let extras = packageFiles(package.directory).filter { $0.path.hasPrefix("scripts/") }
        if !extras.isEmpty {
            item.warnings.append(L("Includes \(extras.count) script file(s); they run only inside the sandbox when an agent uses them."))
        }
        return item
    }

    static func skillItem(from document: ChatImportDocument, ids: inout ChatImportItemIds) -> ChatImportItem? {
        guard let parsed = try? Skill.parseAnyFormat(from: document.text) else { return nil }
        let name = cleanName(parsed.name)
        guard !name.isEmpty else { return nil }
        let spec = ChatImportInstructionsSpec(
            name: name, description: parsed.description, instructions: parsed.instructions)
        return ChatImportItem(
            id: ids.make("skill", name), kind: .skill, name: name, detail: parsed.description,
            origin: document.label, payload: .instructions(spec), contentHash: ChatImportHash.of(document.text))
    }

    /// A SKILL.md by name, or any markdown whose frontmatter has the two
    /// required Agent Skills fields.
    static func isSkillMarkdown(_ document: ChatImportDocument) -> Bool {
        if location(of: document).hasSuffix("skill.md") { return true }
        if isPasted(document) { return pastedKind(document) == .skill }
        let (frontmatter, _) = ClaudeMarkdownParser.extract(document.text)
        return hasNameAndDescription(frontmatter, document.text)
            && frontmatter.keys.allSatisfy { !agentOnlyKeys.contains($0.lowercased()) }
    }

    /// Frontmatter keys only agent files use (Claude Code, Copilot, OpenCode).
    static let agentOnlyKeys: Set<String> = ["tools", "color", "mode", "permission"]
    /// Frontmatter keys only Agent Skills files use.
    static let skillOnlyKeys: Set<String> = ["license", "allowed-tools", "metadata", "compatibility"]

    /// Pasted frontmatter with just a name and description can be a skill
    /// or an agent; only a kind-specific key decides it here. Otherwise the
    /// reader decides, with the user's own words.
    static func pastedKind(_ document: ChatImportDocument) -> ChatImportItemKind? {
        guard isPasted(document) else { return nil }
        let (frontmatter, _) = ClaudeMarkdownParser.extract(document.text)
        guard hasNameAndDescription(frontmatter, document.text) else { return nil }
        let keys = Set(frontmatter.keys.map { $0.lowercased() })
        let agent = !keys.isDisjoint(with: agentOnlyKeys)
        let skill = !keys.isDisjoint(with: skillOnlyKeys)
        if agent == skill { return nil }
        return agent ? .agent : .skill
    }

    /// Text the user wrote in chat, as opposed to a fetched page or file.
    static func isPasted(_ document: ChatImportDocument) -> Bool {
        document.path == nil && URL(string: document.origin)?.scheme == nil
    }

    /// The file path inside a repository, or the URL path of a fetched
    /// raw file, lowercased.
    static func location(of document: ChatImportDocument) -> String {
        (document.path ?? URL(string: document.origin)?.path ?? "").lowercased()
    }

    static func hasNameAndDescription(_ frontmatter: [String: String], _ text: String) -> Bool {
        !(frontmatter["name"] ?? "").isEmpty && !(frontmatter["description"] ?? "").isEmpty
            && text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---")
    }

    struct PackageFile: Sendable {
        let path: String
        let size: Int
    }

    static func packageFiles(_ directory: URL) -> [PackageFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return [] }
        let base = directory.standardizedFileURL.path
        var out: [PackageFile] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard relative.lowercased() != "skill.md" else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            out.append(PackageFile(path: relative, size: size))
            if out.count >= 500 { break }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - Agents and commands

    /// Agent files by folder: Claude Code and Copilot `agents/`, OpenCode
    /// `agent/`, Copilot `chatmodes/`, or a Copilot `.agent.md` /
    /// `.chatmode.md` anywhere.
    static let agentFolders: Set<String> = ["agents", "agent", "chatmodes"]
    /// Command files: Claude Code `commands/`, OpenCode `command/`, or a
    /// Copilot `.prompt.md` anywhere.
    static let commandFolders: Set<String> = ["commands", "command"]

    static func isAgentFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.hasSuffix(".md") else { return false }
        if lower.hasSuffix(".agent.md") || lower.hasSuffix(".chatmode.md") { return true }
        let parent = ((lower as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return agentFolders.contains(parent)
    }

    static func isCommandFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.hasSuffix(".md") else { return false }
        if lower.hasSuffix(".prompt.md") { return true }
        let parent = ((lower as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return commandFolders.contains(parent)
    }

    /// The file name without `.md` and the Copilot `.agent` / `.chatmode` /
    /// `.prompt` infix.
    static func baseFileName(_ path: String?) -> String {
        var name = ((path ?? "") as NSString).lastPathComponent
        for suffix in [".agent.md", ".chatmode.md", ".prompt.md", ".md"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }

    static func agentItem(from document: ChatImportDocument, ids: inout ChatImportItemIds) -> ChatImportItem? {
        let (frontmatter, body) = ClaudeMarkdownParser.extract(document.text)
        let fileName = baseFileName(document.path)
        let name = cleanName(frontmatter["name"].flatMap { $0.isEmpty ? nil : displayName(fromSlug: $0) }
            ?? displayName(fromSlug: fileName))
        let prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { return nil }
        let denies = ChatImportAgentPermissions.denies(frontmatter: frontmatter)
        let spec = ChatImportInstructionsSpec(
            name: name, description: frontmatter["description"] ?? "", instructions: prompt,
            model: frontmatter["model"], deniesShell: denies.shell, deniesNetwork: denies.network)
        return ChatImportItem(
            id: ids.make("agent", name), kind: .agent, name: name, detail: frontmatter["description"] ?? "",
            origin: document.label, payload: .instructions(spec), contentHash: ChatImportHash.of(document.text))
    }

    static func commandItem(from document: ChatImportDocument, ids: inout ChatImportItemIds) -> ChatImportItem? {
        let (frontmatter, body) = ClaudeMarkdownParser.extract(document.text)
        let fileName = baseFileName(document.path)
        let name = commandName(frontmatter["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fileName)
        let template = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !template.isEmpty else { return nil }
        var entry = CommandEntry(name: name)
        entry.description = frontmatter["description"]
        entry.template = template
        entry.icon = "text.bubble"
        return ChatImportItem(
            id: ids.make("command", name), kind: .command, name: "/\(name)", detail: frontmatter["description"] ?? "",
            origin: document.label, payload: .command(entry), contentHash: ChatImportHash.of(document.text))
    }

    // MARK: - Names

    static func cleanName(_ raw: String) -> String {
        let collapsed = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(64))
    }

    static func displayName(fromSlug slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func commandName(_ raw: String) -> String {
        let lowered = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.whitespacesAndNewlines))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:"))
        let mapped = lowered.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return String(mapped.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Unique, stable row ids within one review.
struct ChatImportItemIds {
    private var used = Set<String>()

    mutating func reserve(_ id: String) { used.insert(id) }

    mutating func make(_ kind: String, _ name: String) -> String {
        let base = "\(kind):" + Skill.agentSkillsSlug(for: name)
        var id = base
        var n = 2
        while used.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        used.insert(id)
        return id
    }
}

/// Maps Claude-style agent frontmatter (`tools`, `disallowedTools`) to the
/// two sandbox switches Osaurus has. Only explicit denials are honored.
enum ChatImportAgentPermissions {
    static let shellTools: Set<String> = ["bash", "shell", "terminal", "exec", "run_command"]
    static let networkTools: Set<String> = ["webfetch", "websearch", "fetch", "browser", "web_fetch", "web_search"]

    static func denies(frontmatter: [String: String]) -> (shell: Bool, network: Bool) {
        let disallowed = list(frontmatter["disallowedTools"] ?? frontmatter["disallowed_tools"])
        var shell = !disallowed.isDisjoint(with: shellTools)
        var network = !disallowed.isDisjoint(with: networkTools)
        if let raw = frontmatter["tools"], !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let allowed = list(raw)
            if allowed.isDisjoint(with: shellTools) { shell = true }
            if allowed.isDisjoint(with: networkTools) && allowed.isDisjoint(with: shellTools) { network = true }
        }
        return (shell, network)
    }

    private static func list(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return Set(
            cleaned.split(whereSeparator: { $0 == "," || $0 == " " })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() }
                .map { $0.split(separator: "(").first.map(String.init) ?? $0 }
                .filter { !$0.isEmpty })
    }
}

// MARK: - MCP config shape

/// The MCP server config shape shared by Claude Desktop, Claude Code,
/// Cursor, VS Code, and most READMEs: `{ "mcpServers": { name: {...} } }`
/// or `{ "servers": {...} }`, or one server object with a `name`.
enum ChatImportMCPShape {
    static func servers(in text: String) -> [MCPJSONParser.Parsed.Server] {
        var out: [MCPJSONParser.Parsed.Server] = []
        for candidate in jsonCandidates(in: text) {
            out += parse(candidate)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.name.lowercased()).inserted }
    }

    static func isWholeConfig(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && !parse(trimmed).isEmpty
    }

    private static func parse(_ json: String) -> [MCPJSONParser.Parsed.Server] {
        let parsed = MCPJSONParser.parse(json)
        if !parsed.servers.isEmpty { return parsed.servers }
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let nested = object["mcp"] as? [String: Any], let servers = nested["servers"] {
            return wrapped(["servers": servers])
        }
        if let name = object["name"] as? String, object["command"] != nil || object["url"] != nil {
            var server = object
            server.removeValue(forKey: "name")
            return wrapped(["mcpServers": [name: server]])
        }
        return []
    }

    private static func wrapped(_ object: [String: Any]) -> [MCPJSONParser.Parsed.Server] {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        return MCPJSONParser.parse(text).servers
    }

    /// The whole text when it is JSON, else each fenced code block.
    static func jsonCandidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return [trimmed] }
        guard trimmed.contains("mcpServers") || trimmed.contains("\"servers\"") || trimmed.contains("\"command\"")
        else { return [] }
        guard let regex = try? NSRegularExpression(pattern: "```[a-zA-Z0-9_-]*\\n([\\s\\S]*?)```") else { return [] }
        let ns = trimmed as NSString
        return regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let block = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return block.hasPrefix("{") ? stripJSONComments(block) : nil
        }
    }

    /// VS Code's `mcp.json` allows `//` comments; drop whole-line ones.
    private static func stripJSONComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

// MARK: - MCP entry builder

/// Builds the `mcp_servers` entry for one server. Secret values are never
/// copied: secret-looking or placeholder env vars and headers become
/// pending Keychain slots the user fills in Settings.
enum ChatImportMCPBuilder {
    struct Input: Sendable {
        var name: String
        var url: String?
        var auth: String?
        var command: String?
        var args: [String] = []
        /// Values from a config file; nil when only names are known.
        var env: [String: String]?
        var envNames: [String] = []
        var headers: [String: String]?
        var headerNames: [String] = []
        var hasOAuth = false
    }

    static func item(
        from server: MCPJSONParser.Parsed.Server, origin: String, ids: inout ChatImportItemIds
    ) -> ChatImportItem {
        var input = Input(name: server.name)
        input.url = server.url
        input.command = server.command
        input.args = server.args
        input.env = server.env
        input.headers = server.headers
        input.hasOAuth = server.kind == .oauth
        if server.token != nil || server.tokenIsPlaceholder { input.auth = "bearer" }
        return item(from: input, origin: origin, ids: &ids)
    }

    static func item(from input: Input, origin: String, ids: inout ChatImportItemIds) -> ChatImportItem {
        let name = ChatImportFastPaths.cleanName(input.name)
        var entry = MCPServerEntry(name: name)
        var pending: [String] = []
        var warnings: [String] = []
        var runsDocker = false
        let detail: String

        if let url = input.url, !url.isEmpty {
            entry.transport = "http"
            entry.url = url
            var secretHeaders: [String: String] = [:]
            for key in (input.headers.map { Array($0.keys) } ?? []) + input.headerNames {
                let lower = key.lowercased()
                if lower == "authorization" {
                    entry.auth = "bearer"
                    if !pending.contains("bearer token") { pending.append("bearer token") }
                    continue
                }
                guard looksSecret(key) else {
                    warnings.append(L("Header \(key) isn't copied; add it in Settings if the server needs it."))
                    continue
                }
                secretHeaders[key] = "env:\(envRefName(key))"
                if !pending.contains(key) { pending.append(key) }
            }
            if !secretHeaders.isEmpty { entry.secretHeaderRefs = secretHeaders }
            if input.hasOAuth || input.auth?.lowercased() == "oauth" {
                entry.auth = "oauth"
                pending.append("sign in")
            } else if input.auth?.lowercased() == "bearer", entry.auth == nil {
                entry.auth = "bearer"
                if !pending.contains("bearer token") { pending.append("bearer token") }
            }
            detail = url
        } else {
            entry.transport = "stdio"
            let command = (input.command ?? "").trimmingCharacters(in: .whitespaces)
            entry.command = command
            entry.args = input.args
            var plain: [String: String] = [:]
            var secretRefs: [String: String] = [:]
            for (key, value) in input.env ?? [:] {
                if looksSecret(key) || MCPJSONParser.isPlaceholder(value) || looksLikeSecretValue(value) {
                    secretRefs[key] = "env:\(key)"
                } else {
                    plain[key] = value
                }
            }
            for key in input.envNames where input.env?[key] == nil {
                secretRefs[key] = "env:\(key)"
            }
            if !plain.isEmpty { entry.env = plain }
            if !secretRefs.isEmpty {
                entry.secretEnvRefs = secretRefs
                pending += secretRefs.keys.sorted()
            }
            runsDocker = (command as NSString).lastPathComponent == "docker" && input.args.first == "run"
            entry.executionHost = runsDocker ? "host" : "sandbox"
            if input.args.contains(where: isPlaceholderArg) {
                pending.append(L("edit the placeholder arguments"))
                entry.enabled = false
                warnings.append(L("Some arguments are placeholders; the server stays off until you edit them."))
            }
            detail = ([command] + input.args).joined(separator: " ")
        }
        if !pending.isEmpty, entry.enabled == nil, entry.transport == "stdio" {
            entry.enabled = false
        }
        let spec = ChatImportMCPSpec(entry: entry, pendingSecrets: pending, runsDocker: runsDocker)
        var item = ChatImportItem(
            id: ids.make("mcp", name), kind: .mcpServer, name: name, detail: String(detail.prefix(200)),
            origin: origin, payload: .mcpServer(spec), contentHash: ChatImportHash.of(detail))
        item.needsSetup = pending
        item.warnings = warnings
        return item
    }

    static func looksSecret(_ key: String) -> Bool {
        let k = key.uppercased()
        return ["TOKEN", "KEY", "SECRET", "PASSWORD", "PASS", "AUTH", "CREDENTIAL"].contains { k.contains($0) }
    }

    /// A long opaque value pasted in place of a placeholder.
    static func looksLikeSecretValue(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        let prefixes = ["sk-", "sk_", "ghp_", "gho_", "xoxb-", "xoxp-", "pk_", "rk_", "AKIA", "eyJ"]
        if prefixes.contains(where: { v.hasPrefix($0) }) && v.count >= 16 { return true }
        return false
    }

    static func isPlaceholderArg(_ arg: String) -> Bool {
        let trimmed = arg.trimmingCharacters(in: .whitespaces)
        if MCPJSONParser.isPlaceholder(trimmed) && !trimmed.isEmpty { return true }
        if trimmed.contains("<") && trimmed.contains(">") { return true }
        let upper = trimmed.uppercased()
        return upper.contains("YOUR_") || upper.contains("YOUR-") || upper.hasPrefix("REPLACE")
    }

    static func envRefName(_ header: String) -> String {
        header.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }
}
