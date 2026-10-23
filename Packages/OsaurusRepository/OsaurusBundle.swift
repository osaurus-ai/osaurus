//
//  OsaurusBundle.swift
//  osaurus
//
//  An Osaurus bundle is a folder a third-party installer ships: a manifest
//  (`osaurus-bundle.json`) naming agents, skills, MCP servers and harness
//  runtimes, plus the
//  files they live in. `osaurus import` checks it here, copies it into the
//  import queue, and the app applies it through the declarative config
//  engine. Shared by the CLI and the app so both read the same format.
//
//  Not to be confused with `.mcpb` MCP bundles (`osaurus bundle load`).
//

import Foundation

public enum OsaurusBundleFormat {
    public static let manifestFileName = "osaurus-bundle.json"
    public static let format = "osaurus.bundle"
    public static let formatVersion = 1
    /// Same cap as declarative config documents.
    public static let maxDocumentBytes = 512 * 1024
    /// Mirrors `SkillImportPolicy.default` so a bundle that passes here
    /// passes the app's skill import too.
    public static let maxSkillBytes: Int64 = 50 * 1024 * 1024
    public static let maxSkillFileBytes: Int64 = 10 * 1024 * 1024
    public static let maxSkillFiles = 512
    public static let maxSkillPathDepth = 16
}

/// What a bundle item is. `mcp` is an MCP server.
public enum BundleItemKind: String, Codable, Sendable, CaseIterable, Comparable {
    case skill
    case mcp
    case harnessRuntime = "harness_runtime"
    case agent

    /// Accepts the spellings people type on the command line.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "agent", "agents": self = .agent
        case "skill", "skills": self = .skill
        case "mcp", "mcp-server", "mcp_server", "mcp-servers", "mcp_servers", "server", "servers":
            self = .mcp
        case "runtime", "runtimes", "harness", "harnesses", "harness-runtime", "harness_runtime",
            "harness-runtimes", "harness_runtimes":
            self = .harnessRuntime
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .agent: return "agent"
        case .skill: return "skill"
        case .mcp: return "MCP server"
        case .harnessRuntime: return "harness runtime"
        }
    }

    /// Install order: skills, servers and runtimes exist before the agents
    /// that use them.
    private var order: Int {
        switch self {
        case .skill: return 0
        case .mcp: return 1
        case .harnessRuntime: return 2
        case .agent: return 3
        }
    }

    public static func < (lhs: BundleItemKind, rhs: BundleItemKind) -> Bool { lhs.order < rhs.order }
}

// MARK: - Manifest

public struct OsaurusBundleManifest: Codable, Sendable, Equatable {
    public struct Publisher: Codable, Sendable, Equatable {
        public var name: String
        public var url: String?
        public var email: String?
    }

    public struct SkillReference: Codable, Sendable, Equatable {
        public var name: String
        public var path: String
    }

    public struct AgentReference: Codable, Sendable, Equatable {
        public var path: String
    }

    /// The keys of an MCP server entry the CLI needs for checks and risk
    /// reporting. The full entry travels verbatim to the app, which runs the
    /// strict schema check on it.
    public struct MCPServerReference: Codable, Sendable, Equatable {
        public var name: String
        public var transport: String?
        public var url: String?
        public var auth: String?
        public var command: String?
        public var args: [String]?
        public var executionHost: String?
        public var tokenRef: String?
        public var secretEnvRefs: [String: String]?
        public var secretHeaderRefs: [String: String]?

        enum CodingKeys: String, CodingKey {
            case name, transport, url, auth, command, args
            case executionHost = "execution_host"
            case tokenRef = "token_ref"
            case secretEnvRefs = "secret_env_refs"
            case secretHeaderRefs = "secret_header_refs"
        }

        public var isStdio: Bool { transport?.lowercased() == "stdio" }

        /// Every secret reference with a label naming where it is used.
        public var secretRefs: [(label: String, ref: String)] {
            var out: [(String, String)] = []
            if let tokenRef { out.append(("mcp_servers[\(name)].token_ref", tokenRef)) }
            for (key, ref) in (secretEnvRefs ?? [:]).sorted(by: { $0.key < $1.key }) {
                out.append(("mcp_servers[\(name)].secret_env_refs[\(key)]", ref))
            }
            for (key, ref) in (secretHeaderRefs ?? [:]).sorted(by: { $0.key < $1.key }) {
                out.append(("mcp_servers[\(name)].secret_header_refs[\(key)]", ref))
            }
            return out
        }
    }

    /// An external agent harness (Claude Code, Pi, or a Pi-based CLI) the
    /// bundle registers. Same keys as the config document's
    /// `harness_runtimes` entries; the environment holds plain values only.
    public struct HarnessRuntimeReference: Codable, Sendable, Equatable {
        public var name: String
        /// `claude_code` | `pi_rpc`.
        public var kind: String
        public var executable: String?
        public var arguments: [String]?
        public var environment: [String: String]?

        /// The program and arguments it launches, for risk lines.
        public var commandLine: String {
            let program =
                executable?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (kind == "claude_code" ? "claude" : "pi")
            let args = arguments ?? (kind == "pi_rpc" ? ["--mode", "rpc"] : [])
            return ([program] + args).joined(separator: " ")
        }
    }

    public var format: String
    public var formatVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var publisher: Publisher?
    public var minOsaurusVersion: String?
    public var skills: [SkillReference]
    public var mcpServers: [MCPServerReference]
    public var harnessRuntimes: [HarnessRuntimeReference]
    public var agents: [AgentReference]

    enum CodingKeys: String, CodingKey {
        case format
        case formatVersion = "format_version"
        case id, name, version, description, publisher
        case minOsaurusVersion = "min_osaurus_version"
        case skills
        case mcpServers = "mcp_servers"
        case harnessRuntimes = "harness_runtimes"
        case agents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        publisher = try c.decodeIfPresent(Publisher.self, forKey: .publisher)
        minOsaurusVersion = try c.decodeIfPresent(String.self, forKey: .minOsaurusVersion)
        skills = try c.decodeIfPresent([SkillReference].self, forKey: .skills) ?? []
        mcpServers = try c.decodeIfPresent([MCPServerReference].self, forKey: .mcpServers) ?? []
        harnessRuntimes = try c.decodeIfPresent([HarnessRuntimeReference].self, forKey: .harnessRuntimes) ?? []
        agents = try c.decodeIfPresent([AgentReference].self, forKey: .agents) ?? []
    }

    static let allowedKeys: Set<String> = [
        "format", "format_version", "id", "name", "version", "description", "publisher",
        "min_osaurus_version", "skills", "mcp_servers", "harness_runtimes", "agents",
    ]
    static let allowedPublisherKeys: Set<String> = ["name", "url", "email"]
    static let allowedSkillKeys: Set<String> = ["name", "path"]
    static let allowedAgentKeys: Set<String> = ["path"]
    static let allowedHarnessRuntimeKeys: Set<String> = ["name", "kind", "executable", "arguments", "environment"]
    static let harnessKinds = ["claude_code", "pi_rpc"]
}

// MARK: - Loaded bundle

/// A checked bundle on disk.
public struct OsaurusBundle: Sendable {
    public struct Skill: Sendable, Equatable {
        public var name: String
        public var path: String
        public var directory: URL
    }

    public struct Agent: Sendable, Equatable {
        public var name: String
        public var path: String
        public var file: URL
        /// The agent's skill allow-list, when it declares one.
        public var skills: [String]?
        /// MCP servers the agent uses: the groups it turns on
        /// (`mcp_servers.enabled`) plus this bundle's servers whose tools it
        /// lists by exact name in `tools.enabled`.
        public var mcpServers: [String]
        /// High-risk capability switches it turns on.
        public var highRiskCapabilities: [String]
        /// The agent's `runtime` (`builtin` or a harness runtime's name).
        public var runtime: String?

        /// The harness runtime it runs on, when it names one.
        public var harnessRuntime: String? {
            guard let name = runtime?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                name.lowercased() != "builtin"
            else { return nil }
            return name
        }
    }

    public let rootURL: URL
    public let manifest: OsaurusBundleManifest
    public let skills: [Skill]
    public let agents: [Agent]
    /// Advisory notes that do not stop an install.
    public let warnings: [String]

    public var mcpServers: [OsaurusBundleManifest.MCPServerReference] { manifest.mcpServers }
    public var harnessRuntimes: [OsaurusBundleManifest.HarnessRuntimeReference] { manifest.harnessRuntimes }
    public var id: String { manifest.id }
    public var version: SemanticVersion? { SemanticVersion.parse(manifest.version) }
    public var manifestURL: URL { rootURL.appendingPathComponent(OsaurusBundleFormat.manifestFileName) }

    public func skill(named name: String) -> Skill? {
        let slug = OsaurusBundle.skillSlug(for: name)
        return skills.first { OsaurusBundle.skillSlug(for: $0.name) == slug }
    }

    public func agent(named name: String) -> Agent? {
        agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func mcpServer(named name: String) -> OsaurusBundleManifest.MCPServerReference? {
        mcpServers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func harnessRuntime(named name: String) -> OsaurusBundleManifest.HarnessRuntimeReference? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return harnessRuntimes.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(key) == .orderedSame
        }
    }

    /// The raw JSON object of each MCP server entry, for the app's strict
    /// schema check. Keyed by lowercased name.
    public func rawMCPServerEntries() throws -> [String: [String: Any]] {
        try rawEntries("mcp_servers")
    }

    /// The raw JSON object of each harness runtime entry. Keyed by
    /// lowercased name.
    public func rawHarnessRuntimeEntries() throws -> [String: [String: Any]] {
        try rawEntries("harness_runtimes")
    }

    private func rawEntries(_ key: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for case let entry as [String: Any] in (root[key] as? [Any]) ?? [] {
            if let name = entry["name"] as? String {
                out[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = entry
            }
        }
        return out
    }
}

public struct OsaurusBundleError: Error, Sendable, Equatable, CustomStringConvertible {
    public var issues: [String]
    public init(issues: [String]) { self.issues = issues }
    public var description: String { issues.joined(separator: "\n") }
}

extension OsaurusBundle {

    /// The Agent Skills slug (lowercase, hyphens). Must match
    /// `Skill.agentSkillsSlug(for:)` in the app: skill names compare by slug.
    public static func skillSlug(for name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The prefix Osaurus puts on an MCP server's tool names
    /// (`Acme Tickets` → `acme_tickets`, so `acme_tickets_search`). Must
    /// match `MCPProviderTool.sanitizedProviderPrefix(from:)` in the app.
    public static func mcpToolPrefix(for serverName: String) -> String {
        let prefix = serverName.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return prefix.isEmpty ? "mcp" : prefix
    }

    /// Reverse-DNS, e.g. `com.acme.starter`.
    public static func isValidBundleId(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isASCII, first.isLetter || first.isNumber else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Load and check a bundle. `url` is the bundle folder or its manifest.
    public static func load(from url: URL) throws -> OsaurusBundle {
        var issues: [String] = []
        var warnings: [String] = []
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw OsaurusBundleError(issues: ["No bundle at \(url.path)."])
        }
        let root = (isDirectory.boolValue ? url : url.deletingLastPathComponent()).standardizedFileURL
        let manifestURL = root.appendingPathComponent(OsaurusBundleFormat.manifestFileName)
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw OsaurusBundleError(issues: [
                "\(root.path) has no \(OsaurusBundleFormat.manifestFileName)."
            ])
        }

        let data: Data
        do {
            try checkSize(manifestURL, label: OsaurusBundleFormat.manifestFileName)
            data = try Data(contentsOf: manifestURL)
        } catch let error as OsaurusBundleError {
            throw error
        } catch {
            throw OsaurusBundleError(issues: ["Could not read the manifest: \(error.localizedDescription)"])
        }

        guard let rawRoot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OsaurusBundleError(issues: [
                "\(OsaurusBundleFormat.manifestFileName) is not a JSON object."
            ])
        }
        issues += unknownKeys(in: rawRoot, allowed: OsaurusBundleManifest.allowedKeys, at: "manifest")
        if let publisher = rawRoot["publisher"] as? [String: Any] {
            issues += unknownKeys(
                in: publisher, allowed: OsaurusBundleManifest.allowedPublisherKeys, at: "publisher")
        }
        for (index, item) in ((rawRoot["skills"] as? [Any]) ?? []).enumerated() {
            if let object = item as? [String: Any] {
                issues += unknownKeys(
                    in: object, allowed: OsaurusBundleManifest.allowedSkillKeys, at: "skills[\(index)]")
            }
        }
        for (index, item) in ((rawRoot["agents"] as? [Any]) ?? []).enumerated() {
            if let object = item as? [String: Any] {
                issues += unknownKeys(
                    in: object, allowed: OsaurusBundleManifest.allowedAgentKeys, at: "agents[\(index)]")
            }
        }
        for (index, item) in ((rawRoot["harness_runtimes"] as? [Any]) ?? []).enumerated() {
            if let object = item as? [String: Any] {
                issues += unknownKeys(
                    in: object, allowed: OsaurusBundleManifest.allowedHarnessRuntimeKeys,
                    at: "harness_runtimes[\(index)]")
            }
        }

        let manifest: OsaurusBundleManifest
        do {
            manifest = try JSONDecoder().decode(OsaurusBundleManifest.self, from: data)
        } catch {
            throw OsaurusBundleError(issues: issues + ["Manifest: \(describe(error))"])
        }

        if manifest.format != OsaurusBundleFormat.format {
            issues.append("format must be \"\(OsaurusBundleFormat.format)\" (got \"\(manifest.format)\").")
        }
        if manifest.formatVersion > OsaurusBundleFormat.formatVersion {
            issues.append(
                "format_version \(manifest.formatVersion) needs a newer Osaurus "
                    + "(this one reads up to \(OsaurusBundleFormat.formatVersion)).")
        } else if manifest.formatVersion < 1 {
            issues.append("format_version must be 1.")
        }
        if !isValidBundleId(manifest.id) {
            issues.append("id must be reverse-DNS, like com.example.starter (got \"\(manifest.id)\").")
        }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("name must not be empty.")
        }
        if SemanticVersion.parse(manifest.version) == nil {
            issues.append("version must be a semantic version like 1.2.0 (got \"\(manifest.version)\").")
        }
        if let min = manifest.minOsaurusVersion, SemanticVersion.parse(min) == nil {
            issues.append("min_osaurus_version must be a semantic version like 0.26.0 (got \"\(min)\").")
        }
        if manifest.skills.isEmpty && manifest.mcpServers.isEmpty && manifest.agents.isEmpty
            && manifest.harnessRuntimes.isEmpty
        {
            issues.append("The bundle lists no agents, skills, MCP servers or harness runtimes.")
        }

        // Skills
        var skills: [Skill] = []
        var seenSkills = Set<String>()
        for ref in manifest.skills {
            let slug = skillSlug(for: ref.name)
            guard !slug.isEmpty else {
                issues.append("skills[]: every skill needs a name.")
                continue
            }
            if !seenSkills.insert(slug).inserted {
                issues.append("skills[\(ref.name)]: listed twice.")
            }
            guard let directory = resolve(ref.path, in: root, label: "skills[\(ref.name)].path", issues: &issues)
            else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
                issues.append("skills[\(ref.name)].path: \(ref.path) is not a folder.")
                continue
            }
            let skillFile = directory.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else {
                issues.append("skills[\(ref.name)]: \(ref.path)/SKILL.md is missing.")
                continue
            }
            issues += checkSkillTree(directory, label: "skills[\(ref.name)]")
            if let text = try? String(contentsOf: skillFile, encoding: .utf8) {
                if let declared = frontmatterValue("name", in: text) {
                    if skillSlug(for: declared) != slug {
                        issues.append(
                            "skills[\(ref.name)]: SKILL.md declares name \"\(declared)\"; "
                                + "the manifest name must match it.")
                    }
                } else {
                    issues.append("skills[\(ref.name)]: SKILL.md has no `name:` in its frontmatter.")
                }
                if frontmatterValue("description", in: text) == nil {
                    warnings.append("skills[\(ref.name)]: SKILL.md has no description; agents pick skills by it.")
                }
            } else {
                issues.append("skills[\(ref.name)]: SKILL.md is not UTF-8 text.")
            }
            skills.append(Skill(name: ref.name, path: ref.path, directory: directory))
        }

        // MCP servers
        var seenServers = Set<String>()
        for server in manifest.mcpServers {
            let key = server.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else {
                issues.append("mcp_servers[]: every server needs a name.")
                continue
            }
            if !seenServers.insert(key).inserted {
                issues.append("mcp_servers[\(server.name)]: listed twice.")
            }
            let transport = server.transport?.lowercased() ?? "http"
            switch transport {
            case "http":
                if server.url == nil {
                    issues.append("mcp_servers[\(server.name)]: an HTTP server needs a url.")
                }
                if server.secretEnvRefs != nil {
                    issues.append("mcp_servers[\(server.name)]: secret_env_refs only apply to transport: stdio.")
                }
            case "stdio":
                if (server.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("mcp_servers[\(server.name)]: a stdio server needs a command.")
                }
                if server.tokenRef != nil || server.secretHeaderRefs != nil {
                    issues.append(
                        "mcp_servers[\(server.name)]: token_ref and secret_header_refs only apply to "
                            + "transport: http.")
                }
            default:
                issues.append("mcp_servers[\(server.name)].transport: must be http or stdio.")
            }
            for (label, raw) in server.secretRefs {
                if let problem = BundleSecretRef.problem(raw, label: label) { issues.append(problem) }
            }
        }

        // Harness runtimes
        var seenRuntimes = Set<String>()
        for runtime in manifest.harnessRuntimes {
            let key = runtime.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let label = "harness_runtimes[\(runtime.name)]"
            guard !key.isEmpty else {
                issues.append("harness_runtimes[]: every runtime needs a name.")
                continue
            }
            if key == "builtin" {
                issues.append("\(label): `builtin` is reserved for Osaurus's own loop.")
            }
            if !seenRuntimes.insert(key).inserted {
                issues.append("\(label): listed twice.")
            }
            if !OsaurusBundleManifest.harnessKinds.contains(runtime.kind) {
                issues.append(
                    "\(label).kind: must be one of: \(OsaurusBundleManifest.harnessKinds.joined(separator: ", ")).")
            }
            if let executable = runtime.executable,
                executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                issues.append("\(label).executable: must not be empty.")
            }
            for name in (runtime.environment ?? [:]).keys
            where name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(label).environment: variable names must not be empty.")
            }
        }

        // Agents
        var agents: [Agent] = []
        var seenAgents = Set<String>()
        for ref in manifest.agents {
            let label = "agents[\(ref.path)]"
            guard let file = resolve(ref.path, in: root, label: "\(label).path", issues: &issues) else { continue }
            guard fm.fileExists(atPath: file.path) else {
                issues.append("\(label): file not found.")
                continue
            }
            do {
                try checkSize(file, label: ref.path)
            } catch let error as OsaurusBundleError {
                issues += error.issues
                continue
            } catch {
                issues.append("\(label): \(error.localizedDescription)")
                continue
            }
            guard let fileData = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: fileData)
            else {
                issues.append("\(label): not valid JSON. Agent files must be JSON.")
                continue
            }
            guard let entry = agentEntryObject(in: object) else {
                issues.append(
                    "\(label): expected an agent template, a config document with one agent, "
                        + "or a bare agent entry.")
                continue
            }
            if let envelope = object as? [String: Any], envelope["format"] != nil {
                if envelope["format"] as? String != "osaurus.template" {
                    issues.append("\(label): `format` must be \"osaurus.template\".")
                }
                if ((envelope["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append("\(label): a template envelope needs a top-level `name` (the template's name).")
                }
            }
            guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else {
                issues.append("\(label): the agent needs a name.")
                continue
            }
            if !seenAgents.insert(name.lowercased()).inserted {
                issues.append("agents[\(name)]: two agent files use this name.")
            }
            var skillNames: [String]?
            if let raw = entry["skills"] {
                if let list = raw as? [String] {
                    skillNames = list
                } else {
                    issues.append("agents[\(name)].skills: must be a list of skill names.")
                }
            }
            let servers = ((entry["mcp_servers"] as? [String: Any])?["enabled"] as? [String]) ?? []
            var risky: [String] = []
            if let caps = entry["capabilities"] as? [String: Any] {
                for key in ["computer_use_enabled", "browser_use_enabled", "relay_enabled"]
                where caps[key] as? Bool == true {
                    risky.append(key)
                }
            }
            if (entry["claude_code"] as? [String: Any])?["allow_shell"] as? Bool == true {
                risky.append("claude_code.allow_shell")
            }
            var runtime: String?
            if let raw = entry["runtime"] {
                if let name = raw as? String {
                    runtime = name
                } else {
                    issues.append("agents[\(name)].runtime: must be \"builtin\" or a harness runtime's name.")
                }
            }
            for skill in skillNames ?? [] where !skills.contains(where: { skillSlug(for: $0.name) == skillSlug(for: skill) }) {
                warnings.append(
                    "agents[\(name)].skills: \"\(skill)\" is not in this bundle; it must be a built-in skill "
                        + "or already installed, or the agent will not see it.")
            }
            for server in servers where !manifest.mcpServers.contains(where: {
                $0.name.caseInsensitiveCompare(server) == .orderedSame
            }) {
                warnings.append(
                    "agents[\(name)].mcp_servers: \"\(server)\" is not in this bundle; it must already be set "
                        + "up on this Mac.")
            }
            var usedServers = servers
            let toolNames = ((entry["tools"] as? [String: Any])?["enabled"] as? [String]) ?? []
            for server in manifest.mcpServers
            where !usedServers.contains(where: { $0.caseInsensitiveCompare(server.name) == .orderedSame }) {
                let prefix = mcpToolPrefix(for: server.name) + "_"
                if toolNames.contains(where: { $0.lowercased().hasPrefix(prefix) }) {
                    usedServers.append(server.name)
                }
            }
            let agent = Agent(
                name: name, path: ref.path, file: file, skills: skillNames,
                mcpServers: usedServers, highRiskCapabilities: risky, runtime: runtime)
            if let harness = agent.harnessRuntime,
                !manifest.harnessRuntimes.contains(where: {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(harness)
                        == .orderedSame
                })
            {
                warnings.append(
                    "agents[\(name)].runtime: \"\(harness)\" is not in this bundle; it must already be "
                        + "registered on this Mac (Agents → Runtimes), or the agent will not install.")
            }
            agents.append(agent)
        }

        guard issues.isEmpty else { throw OsaurusBundleError(issues: issues) }
        return OsaurusBundle(rootURL: root, manifest: manifest, skills: skills, agents: agents, warnings: warnings)
    }

    /// The agent entry inside an agent file: a template envelope's `agent`,
    /// a one-agent config document's `agents[0]`, or a bare entry.
    public static func agentEntryObject(in object: Any) -> [String: Any]? {
        guard let root = object as? [String: Any] else { return nil }
        if let agent = root["agent"] as? [String: Any] { return agent }
        if let list = root["agents"] as? [Any] {
            guard list.count == 1 else { return nil }
            return list.first as? [String: Any]
        }
        return root["name"] is String ? root : nil
    }

    // MARK: - Helpers

    private static func unknownKeys(in object: [String: Any], allowed: Set<String>, at label: String) -> [String] {
        object.keys.sorted().filter { !allowed.contains($0) }.map { key in
            let hint = allowed.min { distance($0, key) < distance($1, key) }
            let suggestion = hint.flatMap { distance($0, key) <= 3 ? " Did you mean `\($0)`?" : nil } ?? ""
            return "\(label): unknown key `\(key)`.\(suggestion)"
        }
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1, current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// A relative path that stays inside the bundle.
    private static func resolve(_ path: String, in root: URL, label: String, issues: inout [String]) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(trimmed as NSString).isAbsolutePath, !trimmed.hasPrefix("~") else {
            issues.append("\(label): must be a path relative to the bundle folder.")
            return nil
        }
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard resolved.count > resolvedRoot.count, Array(resolved.prefix(resolvedRoot.count)) == resolvedRoot
        else {
            issues.append("\(label): \(path) points outside the bundle folder.")
            return nil
        }
        return candidate
    }

    private static func checkSize(_ url: URL, label: String) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > OsaurusBundleFormat.maxDocumentBytes {
            throw OsaurusBundleError(issues: [
                "\(label) is \(size / 1024) KB; files are capped at \(OsaurusBundleFormat.maxDocumentBytes / 1024) KB."
            ])
        }
    }

    private static func checkSkillTree(_ directory: URL, label: String) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return ["\(label): could not read the folder."]
        }
        let base = directory.standardizedFileURL.pathComponents.count
        var files = 0
        var total: Int64 = 0
        for case let entry as URL in enumerator {
            let relative = entry.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                return ["\(label): \(relative) is a symbolic link; skills must contain plain files."]
            }
            if entry.standardizedFileURL.pathComponents.count - base > OsaurusBundleFormat.maxSkillPathDepth {
                return ["\(label): \(relative) is nested too deep."]
            }
            guard values.isRegularFile == true else { continue }
            files += 1
            let size = Int64(values.fileSize ?? 0)
            total += size
            if size > OsaurusBundleFormat.maxSkillFileBytes {
                return ["\(label): \(relative) is larger than 10 MB."]
            }
        }
        if files > OsaurusBundleFormat.maxSkillFiles {
            return ["\(label): more than \(OsaurusBundleFormat.maxSkillFiles) files."]
        }
        if total > OsaurusBundleFormat.maxSkillBytes {
            return ["\(label): larger than 50 MB in total."]
        }
        return []
    }

    /// A top-level scalar from YAML frontmatter, without a YAML parser.
    static func frontmatterValue(_ key: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard line.hasPrefix("\(key):") else { continue }
            var value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "" : keys.joined(separator: ".").replacingOccurrences(of: ".[", with: "[") + ": "
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "\(path(context))missing required key `\(key.stringValue)`."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context))\(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

// MARK: - Secret references

/// The `keychain:SERVICE/ACCOUNT` references a bundle may carry. `env:`
/// references are refused: they resolve in the app's environment when it
/// applies the import, long after the installer's environment is gone.
public struct BundleSecretRef: Sendable, Equatable, Hashable {
    public var service: String
    public var account: String

    public var display: String { "keychain:\(service)/\(account)" }

    public static func parse(_ raw: String) -> BundleSecretRef? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("keychain:") else { return nil }
        let rest = trimmed.dropFirst("keychain:".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let service = String(rest[..<slash])
        let account = String(rest[rest.index(after: slash)...])
        guard !service.isEmpty, !account.isEmpty else { return nil }
        return BundleSecretRef(service: service, account: account)
    }

    static func problem(_ raw: String, label: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("env:") {
            return "\(label): env: references are not allowed in bundles. Osaurus applies the bundle "
                + "when it next opens, without the installer's environment. Store the secret in the "
                + "Keychain and use keychain:SERVICE/ACCOUNT."
        }
        if parse(trimmed) == nil {
            return "\(label): expected keychain:SERVICE/ACCOUNT (got \"\(raw)\")."
        }
        return nil
    }
}

extension OsaurusBundle {
    /// Every Keychain reference in the given servers, deduplicated.
    public static func keychainRefs(
        in servers: [OsaurusBundleManifest.MCPServerReference]
    ) -> [(label: String, ref: BundleSecretRef)] {
        var seen = Set<BundleSecretRef>()
        var out: [(String, BundleSecretRef)] = []
        for server in servers {
            for (label, raw) in server.secretRefs {
                guard let ref = BundleSecretRef.parse(raw), seen.insert(ref).inserted else { continue }
                out.append((label, ref))
            }
        }
        return out
    }
}

// MARK: - Selection

/// One item an import touches.
public struct BundleItemRef: Codable, Sendable, Equatable, Hashable {
    public var kind: BundleItemKind
    public var name: String
    /// Named by the caller (or the whole bundle), not pulled in as a
    /// dependency of an agent.
    public var explicit: Bool

    public init(kind: BundleItemKind, name: String, explicit: Bool) {
        self.kind = kind
        self.name = name
        self.explicit = explicit
    }
}

extension OsaurusBundle {

    /// The items to install or update for `kind` / `names`, plus the
    /// skills, MCP servers and harness runtimes selected agents need from
    /// this bundle. Ordered skills, then servers, then runtimes, then agents.
    public func select(kind: BundleItemKind?, names: [String]) throws -> [BundleItemRef] {
        var explicit: [BundleItemRef] = []
        if names.isEmpty {
            let kinds = kind.map { [$0] } ?? BundleItemKind.allCases
            for k in kinds {
                switch k {
                case .skill: explicit += skills.map { BundleItemRef(kind: .skill, name: $0.name, explicit: true) }
                case .mcp: explicit += mcpServers.map { BundleItemRef(kind: .mcp, name: $0.name, explicit: true) }
                case .harnessRuntime:
                    explicit += harnessRuntimes.map {
                        BundleItemRef(kind: .harnessRuntime, name: $0.name, explicit: true)
                    }
                case .agent: explicit += agents.map { BundleItemRef(kind: .agent, name: $0.name, explicit: true) }
                }
            }
        } else {
            var issues: [String] = []
            for name in names {
                var matches: [BundleItemRef] = []
                if kind == nil || kind == .agent, let a = agent(named: name) {
                    matches.append(BundleItemRef(kind: .agent, name: a.name, explicit: true))
                }
                if kind == nil || kind == .skill, let s = skill(named: name) {
                    matches.append(BundleItemRef(kind: .skill, name: s.name, explicit: true))
                }
                if kind == nil || kind == .mcp, let m = mcpServer(named: name) {
                    matches.append(BundleItemRef(kind: .mcp, name: m.name, explicit: true))
                }
                if kind == nil || kind == .harnessRuntime, let r = harnessRuntime(named: name) {
                    matches.append(BundleItemRef(kind: .harnessRuntime, name: r.name, explicit: true))
                }
                switch matches.count {
                case 0:
                    let what = kind?.displayName ?? "agent, skill, MCP server or harness runtime"
                    issues.append("This bundle has no \(what) named \"\(name)\".")
                case 1:
                    explicit.append(matches[0])
                default:
                    issues.append(
                        "\"\(name)\" names more than one item ("
                            + matches.map(\.kind.rawValue).joined(separator: ", ")
                            + "). Say which: osaurus import ... agent|skill|mcp|runtime \"\(name)\".")
                }
            }
            if !issues.isEmpty { throw OsaurusBundleError(issues: issues) }
        }

        var out: [BundleItemRef] = []
        func add(_ ref: BundleItemRef) {
            if let index = out.firstIndex(where: {
                $0.kind == ref.kind && $0.name.caseInsensitiveCompare(ref.name) == .orderedSame
            }) {
                if ref.explicit { out[index].explicit = true }
            } else {
                out.append(ref)
            }
        }
        for ref in explicit { add(ref) }
        for ref in explicit where ref.kind == .agent {
            guard let a = agent(named: ref.name) else { continue }
            for name in a.skills ?? [] {
                if let s = skill(named: name) { add(BundleItemRef(kind: .skill, name: s.name, explicit: false)) }
            }
            for name in a.mcpServers {
                if let m = mcpServer(named: name) { add(BundleItemRef(kind: .mcp, name: m.name, explicit: false)) }
            }
            if let name = a.harnessRuntime, let r = harnessRuntime(named: name) {
                add(BundleItemRef(kind: .harnessRuntime, name: r.name, explicit: false))
            }
        }
        return out.enumerated().sorted { lhs, rhs in
            lhs.element.kind == rhs.element.kind ? lhs.offset < rhs.offset : lhs.element.kind < rhs.element.kind
        }.map(\.element)
    }

    /// Plain-language high-risk changes the items make. Applying any of
    /// them needs `--yes`, the same rule `osaurus config apply` follows.
    public func risks(for items: [BundleItemRef]) -> [String] {
        var out: [String] = []
        for item in items {
            switch item.kind {
            case .skill:
                continue
            case .mcp:
                guard let server = mcpServer(named: item.name) else { continue }
                if server.isStdio {
                    let line = ([server.command ?? ""] + (server.args ?? [])).joined(separator: " ")
                    out.append("MCP server \"\(server.name)\" launches a local process: \(line)")
                    if server.executionHost?.lowercased() == "host" {
                        out.append("MCP server \"\(server.name)\" runs on the host, outside the sandbox")
                    }
                } else {
                    out.append("MCP server \"\(server.name)\" connects to \(server.url ?? "a new endpoint")")
                }
            case .harnessRuntime:
                guard let runtime = harnessRuntime(named: item.name) else { continue }
                out.append(
                    "Harness runtime \"\(runtime.name)\" launches a local program for every chat of an agent "
                        + "on it: \(runtime.commandLine)")
            case .agent:
                guard let a = agent(named: item.name) else { continue }
                for key in a.highRiskCapabilities {
                    out.append("Agent \"\(a.name)\" turns on \(key)")
                }
                if let runtime = a.harnessRuntime {
                    out.append(
                        "Agent \"\(a.name)\" runs on harness runtime \"\(runtime)\", outside the Osaurus "
                            + "sandbox")
                }
            }
        }
        return out
    }
}
