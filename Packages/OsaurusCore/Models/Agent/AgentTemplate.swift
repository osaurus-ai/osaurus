//
//  AgentTemplate.swift
//  osaurus
//
//  A portable, shareable agent definition. The payload is exactly one
//  declarative `AgentEntry` (the same shape `osaurus_config` plans and
//  applies), wrapped in a small envelope that carries what the config
//  document cannot: who wrote it, whether the orchestrator may base new
//  agents on it, and the machine-local things the author relied on
//  (`requires`) so the receiving side can be walked through setting them up.
//
//  Portability rules:
//   - References are names / stable string ids, never UUIDs. Knowledge
//     collections travel as names inside `requires`, not as ids.
//   - Working folder is a PATH HINT. The bookmark never leaves the Mac.
//   - Relay exposure is stripped: reachable-from-outside is a per-Mac choice.
//   - Secrets never appear (the underlying schema has no secret fields).
//

import Foundation
import Yams

/// One machine-local dependency the template's author had configured.
public struct TemplateRequirement: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case workingFolder = "working_folder"
        case knowledgeCollection = "knowledge_collection"
        case plugin
        case mcpServer = "mcp_server"
        case systemPermission = "system_permission"
        case model
    }

    /// How strictly a `model` requirement binds. `always` blocks setup
    /// until the exact model is available; `preferred` falls back to the
    /// user's default with a notice.
    public enum ModelPolicy: String, Codable, Sendable {
        case always
        case preferred
    }

    public var kind: Kind
    /// Human label shown in the setup checklist ("Folder with invoice examples").
    public var label: String?
    /// Author-side value: a folder path, a collection / server name, a
    /// plugin or model id, or a `SystemPermission` raw value.
    public var value: String
    public var policy: ModelPolicy?

    public var id: String { "\(kind.rawValue):\(value.lowercased())" }

    public init(kind: Kind, value: String, label: String? = nil, policy: ModelPolicy? = nil) {
        self.kind = kind
        self.value = value
        self.label = label
        self.policy = policy
    }
}

public struct AgentTemplate: Codable, Equatable, Sendable, Identifiable {
    public static let formatIdentifier = "osaurus.agent-template"
    public static let currentVersion = 1

    public var format: String = AgentTemplate.formatIdentifier
    public var version: Int = AgentTemplate.currentVersion
    /// Library display name. Also the basis of the on-disk slug.
    public var name: String
    public var summary: String?
    public var author: String?
    public var createdAt: Date
    /// When true the orchestrator's `osaurus_config templates` action lists
    /// this template and may base new agents on it.
    public var availableToOrchestrator: Bool
    public var agent: AgentEntry
    public var requires: [TemplateRequirement]

    public var id: String { AgentTemplate.slug(for: name) }

    public init(
        name: String,
        agent: AgentEntry,
        summary: String? = nil,
        author: String? = nil,
        createdAt: Date = Date(),
        availableToOrchestrator: Bool = true,
        requires: [TemplateRequirement] = []
    ) {
        self.name = name
        self.agent = agent
        self.summary = summary
        self.author = author
        self.createdAt = createdAt
        self.availableToOrchestrator = availableToOrchestrator
        self.requires = requires
    }

    enum CodingKeys: String, CodingKey {
        case format, version, name, summary, author
        case createdAt = "created_at"
        case availableToOrchestrator = "available_to_orchestrator"
        case agent, requires
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decodeIfPresent(String.self, forKey: .format) ?? Self.formatIdentifier
        guard format == Self.formatIdentifier else {
            throw AgentTemplateError.notATemplate(
                "`format` is `\(format)`, expected `\(Self.formatIdentifier)`.")
        }
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        guard version == Self.currentVersion else {
            throw AgentTemplateError.unsupportedVersion(version)
        }
        self.format = format
        self.version = version
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        availableToOrchestrator = try c.decodeIfPresent(Bool.self, forKey: .availableToOrchestrator) ?? true
        agent = try c.decode(AgentEntry.self, forKey: .agent)
        requires = try c.decodeIfPresent([TemplateRequirement].self, forKey: .requires) ?? []
    }

    // MARK: - Slug

    private static let slugAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")

    /// File-safe identifier derived from the display name: lowercase, spaces
    /// and runs of other characters collapse to `-`, confined to a strict
    /// character set so it can never carry a path separator.
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
        while out.hasPrefix(".") || out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 80 { out = String(out.prefix(80)) }
        return out.isEmpty ? "template" : out
    }

    // MARK: - Encoding

    /// Pretty JSON for the clipboard, files, and the website library.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// The template as a one-agent declarative document, ready for
    /// `ConfigPlanner` / `ConfigApplier`. `overrides` (typically a new name
    /// or prompt supplied by the orchestrator) are merged on top.
    public func document(overrides: AgentEntry? = nil) -> OsaurusConfigDocument {
        var entry = agent
        if let overrides {
            entry.name = overrides.name.isEmpty ? entry.name : overrides.name
            if let v = overrides.description { entry.description = v }
            if let v = overrides.systemPrompt { entry.systemPrompt = v }
            if overrides.model.isSpecified { entry.model = overrides.model }
            if overrides.temperature.isSpecified { entry.temperature = overrides.temperature }
            if overrides.maxTokens.isSpecified { entry.maxTokens = overrides.maxTokens }
            if overrides.workingFolder.isSpecified { entry.workingFolder = overrides.workingFolder }
            if let v = overrides.capabilities { entry.capabilities = merge(entry.capabilities, v) }
            if let v = overrides.tools { entry.tools = v }
            if let v = overrides.mcpServers { entry.mcpServers = v }
            if let v = overrides.plugins { entry.plugins = v }
            if let v = overrides.sandbox { entry.sandbox = v }
            if let v = overrides.subagents { entry.subagents = v }
        }
        var doc = OsaurusConfigDocument()
        doc.version = 1
        doc.agents = [entry]
        return doc
    }

    private func merge(_ base: AgentCapabilitiesEntry?, _ over: AgentCapabilitiesEntry)
        -> AgentCapabilitiesEntry
    {
        var out = base ?? AgentCapabilitiesEntry()
        if let v = over.toolsEnabled { out.toolsEnabled = v }
        if let v = over.memoryEnabled { out.memoryEnabled = v }
        if let v = over.searchMemoryEnabled { out.searchMemoryEnabled = v }
        if let v = over.webSearchEnabled { out.webSearchEnabled = v }
        if let v = over.knowledgeEnabled { out.knowledgeEnabled = v }
        if let v = over.knowledgeCollectionIds { out.knowledgeCollectionIds = v }
        if let v = over.dbEnabled { out.dbEnabled = v }
        if let v = over.selfSchedulingEnabled { out.selfSchedulingEnabled = v }
        if let v = over.computerUseEnabled { out.computerUseEnabled = v }
        if let v = over.browserUseEnabled { out.browserUseEnabled = v }
        if let v = over.speakEnabled { out.speakEnabled = v }
        if let v = over.renderChartEnabled { out.renderChartEnabled = v }
        if let v = over.relayEnabled { out.relayEnabled = v }
        return out
    }

    // MARK: - Requirements helpers

    public func requirements(of kind: TemplateRequirement.Kind) -> [TemplateRequirement] {
        requires.filter { $0.kind == kind }
    }

    /// Knowledge collection NAMES the author granted. Stored in `requires`
    /// because collection ids are machine-local.
    public var knowledgeCollectionNames: [String] {
        requirements(of: .knowledgeCollection).map(\.value)
    }

    public var modelPolicy: TemplateRequirement.ModelPolicy {
        requirements(of: .model).first?.policy ?? .preferred
    }
}

// MARK: - Errors

public enum AgentTemplateError: Error, LocalizedError, Equatable {
    case empty
    case malformed(String)
    case notATemplate(String)
    case unsupportedVersion(Int)
    case invalidAgent([String])
    case wrongAgentCount(Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Nothing to import. Paste a template JSON or choose a file."
        case .malformed(let detail):
            return "Could not read the template: \(detail)"
        case .notATemplate(let detail):
            return "This is not an Osaurus agent template. \(detail)"
        case .unsupportedVersion(let v):
            return "Template version \(v) is newer than this Osaurus understands. Update Osaurus to import it."
        case .invalidAgent(let issues):
            return "The template's agent is invalid:\n" + issues.map { "• \($0)" }.joined(separator: "\n")
        case .wrongAgentCount(let n):
            return n == 0
                ? "The document declares no agents."
                : "The document declares \(n) agents. A template holds exactly one."
        }
    }
}

// MARK: - Parsing

extension AgentTemplate {

    /// Accepts, in order of preference:
    ///  1. a template envelope (JSON or YAML) with `format: osaurus.agent-template`,
    ///  2. a full declarative config document containing exactly one agent,
    ///  3. a bare agent entry (a mapping with `name`).
    /// The agent payload is always re-validated through the strict document
    /// decoder, so unknown keys are rejected with the usual did-you-mean.
    public static func parse(_ text: String) throws -> AgentTemplate {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentTemplateError.empty }

        let tree: Any?
        do {
            tree = try Yams.load(yaml: trimmed)
        } catch {
            throw AgentTemplateError.malformed(String(describing: error))
        }
        guard let root = normalize(tree) as? [String: Any] else {
            throw AgentTemplateError.malformed("The top level must be a JSON object / YAML mapping.")
        }

        if let format = root["format"] as? String {
            guard format == formatIdentifier else {
                throw AgentTemplateError.notATemplate("`format` is `\(format)`.")
            }
            guard let agentNode = root["agent"] as? [String: Any] else {
                throw AgentTemplateError.malformed("Template is missing its `agent` object.")
            }
            let entry = try strictAgentEntry(from: agentNode)
            var envelope = root
            envelope["agent"] = ["name": entry.name]  // placeholder; replaced below
            let data = try JSONSerialization.data(withJSONObject: envelope)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(Self.lenientDate)
            var template: AgentTemplate
            do {
                template = try decoder.decode(AgentTemplate.self, from: data)
            } catch let error as AgentTemplateError {
                throw error
            } catch {
                throw AgentTemplateError.malformed(String(describing: error))
            }
            template.agent = entry
            return template
        }

        if let agents = root["agents"] {
            guard let list = agents as? [Any] else {
                throw AgentTemplateError.malformed("`agents` must be a list.")
            }
            guard list.count == 1, let only = list.first as? [String: Any] else {
                throw AgentTemplateError.wrongAgentCount(list.count)
            }
            let entry = try strictAgentEntry(from: only)
            return AgentTemplate(name: entry.name, agent: entry, summary: entry.description)
        }

        if root["name"] is String {
            let entry = try strictAgentEntry(from: root)
            return AgentTemplate(name: entry.name, agent: entry, summary: entry.description)
        }

        throw AgentTemplateError.notATemplate(
            "Expected a `format` key, an `agents` list, or an agent with a `name`.")
    }

    /// Runs one agent mapping through the strict document decoder.
    private static func strictAgentEntry(from node: [String: Any]) throws -> AgentEntry {
        let wrapped: [String: Any] = ["version": 1, "agents": [node]]
        let yaml: String
        do {
            yaml = try Yams.dump(object: wrapped)
        } catch {
            throw AgentTemplateError.malformed(String(describing: error))
        }
        do {
            let document = try ConfigYAML.decode(yaml)
            guard let entry = document.agents?.first else {
                throw AgentTemplateError.wrongAgentCount(0)
            }
            return entry
        } catch let error as ConfigYAMLError {
            throw AgentTemplateError.invalidAgent(error.messages)
        }
    }

    /// Yams yields `[AnyHashable: Any]` mappings and typed scalars;
    /// JSONSerialization wants `[String: Any]` and Foundation scalars.
    private static func normalize(_ value: Any?) -> Any? {
        switch value {
        case nil:
            return nil
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
        default:
            return value
        }
    }

    private static func lenientDate(_ decoder: Decoder) throws -> Date {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        if let d = ISO8601DateFormatter().date(from: raw) { return d }
        return Date()
    }
}

// MARK: - Building from a live agent

extension AgentTemplate {

    /// Snapshot a live agent into a template. Machine-local details are
    /// translated into `requires` entries instead of travelling as ids.
    @MainActor
    public static func make(
        from agent: Agent,
        name: String? = nil,
        summary: String? = nil,
        author: String? = nil,
        availableToOrchestrator: Bool = true
    ) -> AgentTemplate {
        var entry = ConfigExporter.exportAgent(agent)
        var requires: [TemplateRequirement] = []

        // Knowledge: ids -> names in `requires`, ids stripped from the entry.
        let grantedIds = agent.settings.knowledgeCollectionIds
        if !grantedIds.isEmpty {
            let collections = KnowledgeCollectionStore.loadAll()
            for id in grantedIds {
                if let collection = collections.first(where: { $0.id == id }) {
                    requires.append(
                        TemplateRequirement(
                            kind: .knowledgeCollection, value: collection.name,
                            label: collection.summary.isEmpty ? nil : collection.summary))
                }
            }
        }
        entry.capabilities?.knowledgeCollectionIds = nil
        // Relay exposure is a per-Mac decision, never part of a template.
        entry.capabilities?.relayEnabled = nil

        if let path = agent.workingFolderPath, !path.isEmpty {
            requires.append(
                TemplateRequirement(
                    kind: .workingFolder, value: abbreviateHome(path),
                    label: L("Working Folder")))
            entry.workingFolder = .value(abbreviateHome(path))
        }
        for server in entry.mcpServers?.enabled ?? [] {
            requires.append(TemplateRequirement(kind: .mcpServer, value: server))
        }
        for plugin in entry.plugins?.enabled ?? [] {
            requires.append(TemplateRequirement(kind: .plugin, value: plugin))
        }
        if agent.settings.computerUseEnabled {
            requires.append(
                TemplateRequirement(
                    kind: .systemPermission, value: SystemPermission.accessibility.rawValue,
                    label: L("Accessibility (Computer Use)")))
        }
        if agent.settings.appleScriptEnabled {
            requires.append(
                TemplateRequirement(
                    kind: .systemPermission, value: SystemPermission.automation.rawValue,
                    label: L("Automation (AppleScript)")))
        }
        if let model = agent.defaultModel, !model.isEmpty {
            requires.append(TemplateRequirement(kind: .model, value: model, policy: .preferred))
        }

        let displayName = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? agent.name
        return AgentTemplate(
            name: displayName,
            agent: entry,
            summary: summary ?? (agent.description.isEmpty ? nil : agent.description),
            author: author,
            availableToOrchestrator: availableToOrchestrator,
            requires: requires
        )
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Resolving on this machine

    /// The agent entry with template requirements mapped to what exists
    /// here: knowledge collection names become local ids (unmatched names
    /// are left for the setup checklist).
    @MainActor
    public func resolvedEntry(overrides: AgentEntry? = nil) -> AgentEntry {
        var entry = document(overrides: overrides).agents?.first ?? agent
        let wanted = knowledgeCollectionNames
        if !wanted.isEmpty {
            let collections = KnowledgeCollectionStore.loadAll()
            let ids = wanted.compactMap { name in
                collections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id.uuidString
            }
            if !ids.isEmpty {
                var caps = entry.capabilities ?? AgentCapabilitiesEntry()
                caps.knowledgeCollectionIds = ids
                if caps.knowledgeEnabled == nil { caps.knowledgeEnabled = true }
                entry.capabilities = caps
            }
        }
        return entry
    }
}
