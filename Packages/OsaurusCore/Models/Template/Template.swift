//
//  Template.swift
//  osaurus
//
//  One portable, versioned template format. The envelope (identity,
//  version, changelog, author, requirements, content hash) is shared by
//  every kind; kinds differ only in payload. Templates live on the Mac and
//  travel as files; Osaurus hosts none of them.
//
//  Identity is `id` (stable across versions and machines) plus `version`
//  (increments on every save). Versions are immutable once written; the
//  store never rewrites one. `contentHash` covers everything but itself and
//  the author signature, so two copies of the same id and version can be
//  told apart on import.
//
//  Portability rules:
//   - References are names / stable string ids, never machine UUIDs.
//   - Working folders are path hints; bookmarks never leave the Mac.
//   - Secret values, saved dialog answers, install bindings, and run
//     history never appear. Only secret KEYS travel, as requirements.
//

import CryptoKit
import Foundation
import Yams

public enum TemplateKind: String, Codable, Sendable, CaseIterable {
    case agent
}

/// Optional authorship. `address` is the author agent's secp256k1 address;
/// `signature` signs `contentHash` with that key (see `TemplateSigner`).
public struct TemplateAuthor: Codable, Equatable, Sendable {
    public var name: String?
    public var address: String?
    public var signature: String?

    public init(name: String? = nil, address: String? = nil, signature: String? = nil) {
        self.name = name
        self.address = address
        self.signature = signature
    }

    public var isSigned: Bool { !(signature ?? "").isEmpty && !(address ?? "").isEmpty }
}

/// The agent payload: one declarative `AgentEntry` (the shape
/// `osaurus_config` plans and applies) plus its chat quick actions.
public struct AgentTemplatePayload: Equatable, Sendable {
    public var agent: AgentEntry
    /// nil leaves the new agent on built-in quick actions; empty hides them.
    public var actions: [TemplateAction]?

    public init(agent: AgentEntry, actions: [TemplateAction]? = nil) {
        self.agent = agent
        self.actions = actions
    }
}

public enum TemplatePayload: Equatable, Sendable {
    case agent(AgentTemplatePayload)

    public var kind: TemplateKind {
        switch self {
        case .agent: return .agent
        }
    }
}

public struct Template: Codable, Equatable, Sendable, Identifiable {
    public static let formatIdentifier = "osaurus.template"
    /// The newest format this build reads.
    public static let currentFormatVersion = 3
    /// The format every build understands.
    public static let baselineFormatVersion = 1

    /// The lowest format that can carry this payload and every bundled
    /// template. Keeping old-style templates at the lowest format lets
    /// older builds keep importing them.
    public static func requiredFormatVersion(payload: TemplatePayload, bundled: [Template]) -> Int {
        max(baselineFormatVersion, bundled.map(\.formatVersion).max() ?? baselineFormatVersion)
    }

    public var formatVersion: Int = Template.baselineFormatVersion
    public let id: UUID
    public var version: Int
    public var changelog: String
    /// Library display name.
    public var name: String
    public var summary: String?
    public var author: TemplateAuthor?
    public var createdAt: Date
    /// When true the Orchestrator may list and apply this template.
    public var availableToOrchestrator: Bool
    /// Derived from the payload; see `derivedRequirements()`.
    public var requirements: TemplateRequirements
    public var payload: TemplatePayload
    /// Other templates this one carries with it.
    public var bundled: [Template]
    /// Setup for the MCP servers the payload names; see `MCPServerHint`.
    public var serverHints: [MCPServerHint]
    public var contentHash: String

    public var kind: TemplateKind { payload.kind }

    public init(
        id: UUID = UUID(),
        version: Int = 1,
        changelog: String = "",
        name: String,
        summary: String? = nil,
        author: TemplateAuthor? = nil,
        createdAt: Date = Date(),
        availableToOrchestrator: Bool = true,
        requirements: TemplateRequirements = TemplateRequirements(),
        payload: TemplatePayload,
        bundled: [Template] = [],
        serverHints: [MCPServerHint] = []
    ) {
        self.id = id
        self.version = version
        self.changelog = changelog
        self.name = name
        self.summary = summary
        self.author = author
        self.createdAt = createdAt
        self.availableToOrchestrator = availableToOrchestrator
        self.requirements = requirements
        self.payload = payload
        self.bundled = bundled
        self.serverHints = serverHints
        self.contentHash = ""
        self.formatVersion = Self.requiredFormatVersion(payload: payload, bundled: bundled)
        self.requirements = derivedRequirements()
        self.serverHints = referencedHints(serverHints)
        self.contentHash = computedContentHash()
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case format, id, kind, version, changelog, name, summary, author
        case formatVersion = "format_version"
        case createdAt = "created_at"
        case availableToOrchestrator = "available_to_orchestrator"
        case requirements, agent, actions, bundled
        case contentHash = "content_hash"
        case serverHints = "mcp_server_hints"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decodeIfPresent(String.self, forKey: .format) ?? Self.formatIdentifier
        guard format == Self.formatIdentifier else {
            throw TemplateError.notATemplate("`format` is `\(format)`, expected `\(Self.formatIdentifier)`.")
        }
        let fv = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.baselineFormatVersion
        guard fv <= Self.currentFormatVersion else { throw TemplateError.unsupportedVersion(fv) }
        formatVersion = fv
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        version = max(1, try c.decodeIfPresent(Int.self, forKey: .version) ?? 1)
        changelog = try c.decodeIfPresent(String.self, forKey: .changelog) ?? ""
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        author = try c.decodeIfPresent(TemplateAuthor.self, forKey: .author)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        availableToOrchestrator = try c.decodeIfPresent(Bool.self, forKey: .availableToOrchestrator) ?? true
        requirements = try c.decodeIfPresent(TemplateRequirements.self, forKey: .requirements) ?? TemplateRequirements()
        bundled = try c.decodeIfPresent([Template].self, forKey: .bundled) ?? []
        serverHints = try c.decodeIfPresent([MCPServerHint].self, forKey: .serverHints) ?? []
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? TemplateKind.agent.rawValue
        guard TemplateKind(rawValue: rawKind) == .agent else {
            throw TemplateError.wrongKind(expected: .agent, got: rawKind)
        }
        payload = .agent(
            AgentTemplatePayload(
                agent: try c.decode(AgentEntry.self, forKey: .agent),
                actions: try c.decodeIfPresent([TemplateAction].self, forKey: .actions)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatIdentifier, forKey: .format)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(version, forKey: .version)
        try c.encode(changelog, forKey: .changelog)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(availableToOrchestrator, forKey: .availableToOrchestrator)
        try c.encode(requirements, forKey: .requirements)
        switch payload {
        case .agent(let p):
            try c.encode(p.agent, forKey: .agent)
            try c.encodeIfPresent(p.actions, forKey: .actions)
        }
        if !bundled.isEmpty { try c.encode(bundled, forKey: .bundled) }
        if !serverHints.isEmpty { try c.encode(serverHints, forKey: .serverHints) }
        try c.encode(contentHash, forKey: .contentHash)
    }

    // MARK: Payload accessors

    public var agentPayload: AgentTemplatePayload? {
        if case .agent(let p) = payload { return p }
        return nil
    }

    /// Agent entry of an agent template. Setting it on any other kind is a
    /// programming error and is ignored.
    public var agent: AgentEntry {
        get { agentPayload?.agent ?? AgentEntry(name: name) }
        set {
            guard case .agent(var p) = payload else { return }
            p.agent = newValue
            payload = .agent(p)
        }
    }

    public var actions: [TemplateAction]? {
        get { agentPayload?.actions }
        set {
            guard case .agent(var p) = payload else { return }
            p.actions = newValue
            payload = .agent(p)
        }
    }

    /// Flat requirement rows, for checklists.
    public var requires: [TemplateRequirement] { requirements.items }

    // MARK: Hash and sealing

    /// Canonical JSON of everything except the hash and the signature.
    func canonicalData() -> Data {
        var copy = self
        copy.contentHash = ""
        copy.author?.signature = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Self.iso8601.string(from: date))
        }
        return (try? encoder.encode(copy)) ?? Data()
    }

    public func computedContentHash() -> String {
        let digest = SHA256.hash(data: canonicalData())
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public var hashIsValid: Bool { contentHash == computedContentHash() }

    /// Requirements re-derived and the hash recomputed. Every write goes
    /// through this so a stored template is always self-consistent. A
    /// change to the content drops a signature that no longer matches.
    public func sealed() -> Template {
        var copy = self
        copy.requirements = copy.derivedRequirements()
        copy.serverHints = copy.referencedHints(copy.serverHints)
        copy.bundled = copy.bundled.map { $0.sealed() }
        copy.formatVersion = Self.requiredFormatVersion(payload: copy.payload, bundled: copy.bundled)
        let newHash = copy.computedContentHash()
        if newHash != contentHash, copy.author?.signature != nil {
            copy.author?.signature = nil
        }
        copy.contentHash = newHash
        return copy
    }

    /// One hint per server the requirements name, in requirement order.
    func referencedHints(_ hints: [MCPServerHint]) -> [MCPServerHint] {
        requirements.mcpServers.compactMap { server in
            hints.first { $0.name.caseInsensitiveCompare(server) == .orderedSame }
        }
    }

    /// The hint for a server the payload names.
    public func serverHint(named name: String) -> MCPServerHint? {
        serverHints.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Requirements

    /// Requirements follow the payload. Notes and author-carried values the
    /// payload cannot express (knowledge names, the folder hint, model
    /// strictness) are preserved from the current set.
    public func derivedRequirements() -> TemplateRequirements {
        switch payload {
        case .agent(let p):
            return Self.agentRequirements(entry: p.agent, carried: requirements)
        }
    }

    static func agentRequirements(entry: AgentEntry, carried: TemplateRequirements) -> TemplateRequirements {
        var out = TemplateRequirements()
        if let model = entry.model.valueOrNil?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            let prior = carried.models.first { $0.slot == ModelRequirement.agentSlot }
            out.models = [
                ModelRequirement(
                    slot: ModelRequirement.agentSlot, preferred: model,
                    strictness: prior?.strictness ?? .preferred,
                    locality: prior?.locality ?? .cloudAllowed,
                    needsToolUse: entry.capabilities?.toolsEnabled ?? true)
            ]
        }
        out.mcpServers = entry.mcpServers?.enabled ?? []
        out.plugins = entry.plugins?.enabled ?? []
        var permissions: [String] = []
        if entry.capabilities?.computerUseEnabled == true { permissions.append(SystemPermission.accessibility.rawValue) }
        for raw in carried.permissions where !permissions.contains(raw) { permissions.append(raw) }
        out.permissions = permissions
        out.knowledge = carried.knowledge
        if let path = entry.workingFolder.valueOrNil, !path.isEmpty {
            out.workingFolder = PathHint(path: path, label: carried.workingFolder?.label)
        }
        out.secrets = carried.secrets
        out.notes = carried.notes
        return out
    }

    // MARK: Naming

    private static let slugAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")

    /// File- and tool-name-safe identifier derived from a display name.
    public static func slug(for name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if slugAllowed.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if out.count > 80 { out = String(out.prefix(80)) }
        while out.hasPrefix(".") || out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "template" : out
    }

    public var slug: String { Self.slug(for: name) }

    /// `base` when its slug is free, else "base 2", "base 3", …
    public static func availableName(for base: String, takenSlugs: Set<String>) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard takenSlugs.contains(slug(for: trimmed)) else { return trimmed }
        var n = 2
        while takenSlugs.contains(slug(for: "\(trimmed) \(n)")) { n += 1 }
        return "\(trimmed) \(n)"
    }

    /// The same content under a new name. For agent templates the agent the
    /// template creates is renamed with it.
    public func renamed(to newName: String) -> Template {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        var copy = self
        copy.name = trimmed
        if case .agent = payload { copy.agent.name = trimmed }
        return copy
    }

    /// An independent copy with a fresh identity at version 1. "Keep both"
    /// on an import conflict uses this so the two never share history.
    public func forked(named newName: String) -> Template {
        var copy = Template(
            id: UUID(), version: 1, changelog: L("Copied from \(name) v\(version)"),
            name: name, summary: summary, author: nil, createdAt: Date(),
            availableToOrchestrator: availableToOrchestrator, requirements: requirements,
            payload: payload, bundled: bundled, serverHints: serverHints)
        copy = copy.renamed(to: newName)
        return copy.sealed()
    }

    /// The same template with a new id, keeping everything else. Only the
    /// built-in loader and tests need this.
    func withID(_ id: UUID) -> Template {
        let t = Template(
            id: id, version: version, changelog: changelog, name: name, summary: summary,
            author: author, createdAt: createdAt, availableToOrchestrator: availableToOrchestrator,
            requirements: requirements, payload: payload, bundled: bundled, serverHints: serverHints)
        return t.sealed()
    }

    // MARK: Encoding

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Self.iso8601.string(from: date))
        }
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

// MARK: - Errors

public enum TemplateError: Error, LocalizedError, Equatable {
    case empty
    case malformed(String)
    case notATemplate(String)
    case unsupportedVersion(Int)
    case invalidAgent([String])
    case wrongAgentCount(Int)
    case wrongKind(expected: TemplateKind, got: String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return L("Nothing to import. Choose a template file.")
        case .malformed(let detail):
            return L("Could not read the template: \(detail)")
        case .notATemplate(let detail):
            return L("This is not an Osaurus template. \(detail)")
        case .unsupportedVersion(let v):
            return L("Template format \(v) is newer than this Osaurus understands. Update Osaurus to import it.")
        case .invalidAgent(let issues):
            return L("The template's agent is invalid:") + "\n" + issues.map { "• \($0)" }.joined(separator: "\n")
        case .wrongAgentCount(let n):
            return n == 0
                ? L("The document declares no agents.")
                : L("The document declares \(n) agents. A template holds exactly one.")
        case .wrongKind(let expected, let got):
            return L("Expected a \(expected.rawValue) template, got a \(got) template.")
        }
    }
}

/// Agent-template call sites read naturally with this name.
public typealias AgentTemplateError = TemplateError

// MARK: - Parsing

extension Template {

    /// Accepts, in order of preference:
    ///  1. a template envelope (JSON or YAML) with `format: osaurus.template`,
    ///  2. a full declarative config document containing exactly one agent,
    ///  3. a bare agent entry (a mapping with `name`).
    /// Agent payloads are re-validated through the strict document decoder,
    /// so unknown keys are rejected with the usual did-you-mean. Smart quotes
    /// are straightened only when the text as written fails to parse.
    public static func parse(_ text: String) throws -> Template {
        do {
            return try parseExactly(text)
        } catch let original {
            let straightened = straighteningQuotes(text)
            guard straightened != text, let template = try? parseExactly(straightened) else {
                throw original
            }
            return template
        }
    }

    private static func parseExactly(_ text: String) throws -> Template {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TemplateError.empty }

        // JSON first: code-node sources carry escapes and tabs that YAML
        // scanners treat differently. YAML is the fallback for hand-written
        // agent templates.
        let tree: Any?
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        {
            tree = json
        } else {
            do {
                tree = try Yams.load(yaml: trimmed)
            } catch {
                throw TemplateError.malformed(String(describing: error))
            }
        }
        guard let root = normalize(tree) as? [String: Any] else {
            throw TemplateError.malformed("The top level must be a JSON object / YAML mapping.")
        }

        if root["format"] != nil {
            return try parseEnvelope(root)
        }

        if let agents = root["agents"] {
            guard let list = agents as? [Any] else {
                throw TemplateError.malformed("`agents` must be a list.")
            }
            guard list.count == 1, let only = list.first as? [String: Any] else {
                throw TemplateError.wrongAgentCount(list.count)
            }
            let entry = try strictAgentEntry(from: only)
            return Template(
                name: entry.name, summary: entry.description,
                payload: .agent(AgentTemplatePayload(agent: entry)))
        }

        if root["name"] is String {
            let entry = try strictAgentEntry(from: root)
            return Template(
                name: entry.name, summary: entry.description,
                payload: .agent(AgentTemplatePayload(agent: entry)))
        }

        throw TemplateError.notATemplate("Expected a `format` key, an `agents` list, or an agent with a `name`.")
    }

    private static func parseEnvelope(_ root: [String: Any]) throws -> Template {
        guard let format = root["format"] as? String, format == formatIdentifier else {
            throw TemplateError.notATemplate("`format` is `\(root["format"] ?? "")`, expected `\(formatIdentifier)`.")
        }
        var envelope = root
        let rawKind = (root["kind"] as? String) ?? TemplateKind.agent.rawValue
        guard TemplateKind(rawValue: rawKind) == .agent else {
            throw TemplateError.wrongKind(expected: .agent, got: rawKind)
        }
        guard let agentNode = root["agent"] as? [String: Any] else {
            throw TemplateError.malformed("Template is missing its `agent` object.")
        }
        let strictEntry = try strictAgentEntry(from: agentNode)
        envelope["agent"] = ["name": strictEntry.name]
        // This build does not install bundled templates; the agent itself
        // still imports.
        let bundledTemplates: [Template] = []
        envelope["bundled"] = nil
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.lenientDate)
        var template: Template
        do {
            template = try decoder.decode(Template.self, from: data)
        } catch let error as TemplateError {
            throw error
        } catch {
            throw TemplateError.malformed(String(describing: error))
        }
        template.agent = strictEntry
        template.bundled = bundledTemplates
        // Requirements always follow the payload: a hand-edited file that
        // drops one gets it back.
        let carriedHash = template.contentHash
        template.requirements = template.derivedRequirements()
        template.contentHash = carriedHash.isEmpty ? template.computedContentHash() : carriedHash
        return template
    }

    static func straighteningQuotes(_ text: String) -> String {
        var out = text
        for curly in ["\u{201C}", "\u{201D}", "\u{201E}"] {
            out = out.replacingOccurrences(of: curly, with: "\"")
        }
        return out
    }

    private static func strictAgentEntry(from node: [String: Any]) throws -> AgentEntry {
        let wrapped: [String: Any] = ["version": 1, "agents": [node]]
        let yaml: String
        do {
            yaml = try Yams.dump(object: wrapped)
        } catch {
            throw TemplateError.malformed(String(describing: error))
        }
        do {
            let document = try ConfigYAML.decode(yaml)
            guard let entry = document.agents?.first else { throw TemplateError.wrongAgentCount(0) }
            return entry
        } catch let error as ConfigYAMLError {
            throw TemplateError.invalidAgent(error.messages)
        }
    }

    private static func normalize(_ value: Any?) -> Any? {
        switch value {
        case nil:
            return nil
        case let string as String:
            // JSONSerialization yields NSString, which Yams cannot represent.
            return String(string)
        case let dict as [AnyHashable: Any]:
            var out: [String: Any] = [:]
            for (key, raw) in dict {
                let name = (key.base as? String) ?? String(describing: key.base)
                out[name] = normalize(raw) ?? NSNull()
            }
            return out
        case let list as [Any]:
            return list.map { normalize($0) ?? NSNull() }
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let number as NSNumber where !(value is String):
            // JSONSerialization numbers are NSNumber; YAML dumping needs the
            // Swift scalar or booleans turn into 1/0.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            let d = number.doubleValue
            if d.rounded() == d, abs(d) < 1e15, !String(describing: number).contains(".") {
                return number.intValue
            }
            return d
        default:
            return value
        }
    }

    static func lenientDate(_ decoder: Decoder) throws -> Date {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        if let d = ISO8601DateFormatter().date(from: raw) { return d }
        return Date()
    }
}
