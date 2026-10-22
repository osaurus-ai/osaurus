//
//  TemplateRequirements.swift
//  osaurus
//
//  What a template needs from the Mac it is installed on. Requirements are
//  derived from the payload, never hand-written: a designer can annotate
//  one with a note but cannot leave one out. The setup checker and the
//  setup wizard read this one shape.
//

import Foundation

/// How strictly a model requirement binds.
public enum ModelStrictness: String, Codable, Sendable, CaseIterable {
    /// Blocks setup until the exact model is present.
    case always
    /// Falls back to the user's default model, with a notice.
    case preferred
}

/// Where a model slot's requests may go.
public enum ModelLocality: String, Codable, Sendable, CaseIterable {
    /// Only models that run on this Mac may be bound.
    case localOnly = "local_only"
    /// Local or cloud provider models may be bound.
    case cloudAllowed = "cloud_allowed"
}

public struct ModelRequirement: Codable, Equatable, Sendable, Identifiable {
    /// Slot name nodes reference, e.g. "decision". Agent templates use "main".
    public var slot: String
    public var preferred: String?
    public var strictness: ModelStrictness
    public var locality: ModelLocality
    public var needsToolUse: Bool
    public var minContext: Int?

    public var id: String { slot }

    public static let agentSlot = "main"

    /// The model an `always` slot must run on: its `preferred` model. Nil
    /// for `preferred` slots, and for an `always` slot that names none.
    public var requiredModel: String? {
        guard strictness == .always,
            let model = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty
        else { return nil }
        return model
    }

    public init(
        slot: String,
        preferred: String? = nil,
        strictness: ModelStrictness = .preferred,
        locality: ModelLocality = .cloudAllowed,
        needsToolUse: Bool = false,
        minContext: Int? = nil
    ) {
        self.slot = slot
        self.preferred = preferred
        self.strictness = strictness
        self.locality = locality
        self.needsToolUse = needsToolUse
        self.minContext = minContext
    }

    enum CodingKeys: String, CodingKey {
        case slot, preferred, strictness, locality
        case needsToolUse = "needs_tool_use"
        case minContext = "min_context"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = try c.decode(String.self, forKey: .slot)
        preferred = try c.decodeIfPresent(String.self, forKey: .preferred)
        strictness = try c.decodeIfPresent(ModelStrictness.self, forKey: .strictness) ?? .preferred
        locality = try c.decodeIfPresent(ModelLocality.self, forKey: .locality) ?? .cloudAllowed
        needsToolUse = try c.decodeIfPresent(Bool.self, forKey: .needsToolUse) ?? false
        minContext = try c.decodeIfPresent(Int.self, forKey: .minContext)
    }
}

public struct SecretRequirement: Codable, Equatable, Sendable, Identifiable {
    /// Environment-style key, e.g. "CLIO_API_KEY".
    public var key: String
    public var label: String
    public var help: String?
    /// Set when the value is an OAuth 2.0 access token: setup offers
    /// "Sign in" and the run always gets a fresh token
    /// (`OAuth2ConnectionFlow`). Without it the person pastes a value.
    public var oauth2: OAuth2Spec?
    /// The host this credential logs into (`declare_connection`): setup
    /// offers the person's existing connections to the same service
    /// first and keeps a pasted value as a shared connection.
    public var service: String?
    /// The `ConnectionProviders` entry the declaration came from.
    public var provider: String?

    public var id: String { key }

    public init(
        key: String, label: String? = nil, help: String? = nil, oauth2: OAuth2Spec? = nil, service: String? = nil,
        provider: String? = nil
    ) {
        self.key = key
        self.label = label ?? key
        self.help = help
        self.oauth2 = oauth2
        self.service = service
        self.provider = provider
    }

    /// The host connections are matched on.
    public var serviceHost: String? { service ?? oauth2?.serviceHost }

    /// Declared as a login to a service rather than a bare key: a
    /// sign-in, or a token setup keeps as a shared connection.
    public var isConnection: Bool { oauth2 != nil || service != nil || provider != nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        help = try c.decodeIfPresent(String.self, forKey: .help)
        oauth2 = try c.decodeIfPresent(OAuth2Spec.self, forKey: .oauth2)
        service = try c.decodeIfPresent(String.self, forKey: .service)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(help, forKey: .help)
        try c.encodeIfPresent(oauth2, forKey: .oauth2)
        try c.encodeIfPresent(service, forKey: .service)
        try c.encodeIfPresent(provider, forKey: .provider)
    }

    enum CodingKeys: String, CodingKey { case key, label, help, oauth2, service, provider }
}

/// How to obtain an OAuth 2.0 token for a secret: the authorization-code
/// flow with PKCE against the service's endpoints. Public client ids are
/// fine to ship in a template; a client secret, when the service insists
/// on one, is entered on each Mac and never travels.
public struct OAuth2Spec: Codable, Equatable, Sendable {
    public var authorizeURL: String
    public var tokenURL: String
    public var scopes: [String]
    /// The app registration's public client id, when the author made one
    /// for the template; otherwise setup asks for it.
    public var clientID: String?
    /// The service requires a client secret even for the PKCE flow.
    public var requiresClientSecret: Bool
    /// Extra authorize-URL query items some services need (e.g. Google's
    /// `access_type=offline`).
    public var authorizeParameters: [String: String]

    public init(
        authorizeURL: String, tokenURL: String, scopes: [String] = [], clientID: String? = nil,
        requiresClientSecret: Bool = false, authorizeParameters: [String: String] = [:]
    ) {
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.clientID = clientID
        self.requiresClientSecret = requiresClientSecret
        self.authorizeParameters = authorizeParameters
    }

    enum CodingKeys: String, CodingKey {
        case authorizeURL = "authorize_url"
        case tokenURL = "token_url"
        case scopes
        case clientID = "client_id"
        case requiresClientSecret = "requires_client_secret"
        case authorizeParameters = "authorize_parameters"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authorizeURL = try c.decode(String.self, forKey: .authorizeURL)
        tokenURL = try c.decode(String.self, forKey: .tokenURL)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID)
        requiresClientSecret = try c.decodeIfPresent(Bool.self, forKey: .requiresClientSecret) ?? false
        authorizeParameters = try c.decodeIfPresent([String: String].self, forKey: .authorizeParameters) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(authorizeURL, forKey: .authorizeURL)
        try c.encode(tokenURL, forKey: .tokenURL)
        if !scopes.isEmpty { try c.encode(scopes, forKey: .scopes) }
        try c.encodeIfPresent(clientID, forKey: .clientID)
        if requiresClientSecret { try c.encode(true, forKey: .requiresClientSecret) }
        if !authorizeParameters.isEmpty { try c.encode(authorizeParameters, forKey: .authorizeParameters) }
    }

    /// The service the token is for, from the authorize URL's host.
    public var serviceHost: String? { URL(string: authorizeURL)?.host?.lowercased() }

    /// Both endpoints must be https.
    public var problems: [String] {
        var out: [String] = []
        for (label, raw) in [("authorize_url", authorizeURL), ("token_url", tokenURL)] {
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else {
                out.append("\(label) must be an https URL")
                continue
            }
        }
        return out
    }
}

/// A folder path the author used. Only the hint travels; access (the
/// security-scoped bookmark) is granted again on every Mac.
public struct PathHint: Codable, Equatable, Sendable {
    public var path: String
    public var label: String?

    public init(path: String, label: String? = nil) {
        self.path = path
        self.label = label
    }
}

public struct TemplateRequirements: Codable, Equatable, Sendable {
    public var models: [ModelRequirement]
    public var secrets: [SecretRequirement]
    public var mcpServers: [String]
    public var plugins: [String]
    /// `SystemPermission` raw values.
    public var permissions: [String]
    /// Hosts any code node may reach.
    public var network: [String]
    /// Built-in tools tool and agentic nodes call (MCP and plugin tools are
    /// covered by `mcpServers` / `plugins`).
    public var tools: [String]
    /// Agent only: knowledge collection names.
    public var knowledge: [String]
    /// Agent only.
    public var workingFolder: PathHint?
    /// Designer notes keyed by `TemplateRequirement.id`.
    public var notes: [String: String]

    public init(
        models: [ModelRequirement] = [],
        secrets: [SecretRequirement] = [],
        mcpServers: [String] = [],
        plugins: [String] = [],
        permissions: [String] = [],
        network: [String] = [],
        tools: [String] = [],
        knowledge: [String] = [],
        workingFolder: PathHint? = nil,
        notes: [String: String] = [:]
    ) {
        self.tools = tools
        self.models = models
        self.secrets = secrets
        self.mcpServers = mcpServers
        self.plugins = plugins
        self.permissions = permissions
        self.network = network
        self.knowledge = knowledge
        self.workingFolder = workingFolder
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case models, secrets, permissions, network, knowledge, notes, plugins, tools
        case mcpServers = "mcp_servers"
        case workingFolder = "working_folder"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decodeIfPresent([ModelRequirement].self, forKey: .models) ?? []
        secrets = try c.decodeIfPresent([SecretRequirement].self, forKey: .secrets) ?? []
        mcpServers = try c.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
        plugins = try c.decodeIfPresent([String].self, forKey: .plugins) ?? []
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        knowledge = try c.decodeIfPresent([String].self, forKey: .knowledge) ?? []
        workingFolder = try c.decodeIfPresent(PathHint.self, forKey: .workingFolder)
        notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
    }

    /// `tools` is left out when empty so templates without it keep their
    /// content hash.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(models, forKey: .models)
        try c.encode(secrets, forKey: .secrets)
        try c.encode(mcpServers, forKey: .mcpServers)
        try c.encode(plugins, forKey: .plugins)
        try c.encode(permissions, forKey: .permissions)
        try c.encode(network, forKey: .network)
        if !tools.isEmpty { try c.encode(tools, forKey: .tools) }
        try c.encode(knowledge, forKey: .knowledge)
        try c.encodeIfPresent(workingFolder, forKey: .workingFolder)
        try c.encode(notes, forKey: .notes)
    }

    public var isEmpty: Bool { items.isEmpty }

    var systemPermissions: [SystemPermission] {
        permissions.compactMap(SystemPermission.init(rawValue:))
    }

    /// Union of two requirement sets, deduplicated by key, so a secret,
    /// server, or permission several templates need is asked once.
    public func merged(with other: TemplateRequirements) -> TemplateRequirements {
        func union(_ a: [String], _ b: [String]) -> [String] {
            var seen = Set<String>()
            return (a + b).filter { seen.insert($0.lowercased()).inserted }
        }
        var secretsByKey: [String: SecretRequirement] = [:]
        var secretOrder: [String] = []
        for s in secrets + other.secrets where secretsByKey[s.key] == nil {
            secretsByKey[s.key] = s
            secretOrder.append(s.key)
        }
        return TemplateRequirements(
            models: models + other.models,
            secrets: secretOrder.compactMap { secretsByKey[$0] },
            mcpServers: union(mcpServers, other.mcpServers),
            plugins: union(plugins, other.plugins),
            permissions: union(permissions, other.permissions),
            network: union(network, other.network),
            tools: union(tools, other.tools),
            knowledge: union(knowledge, other.knowledge),
            workingFolder: workingFolder ?? other.workingFolder,
            notes: notes.merging(other.notes) { a, _ in a }
        )
    }

    /// Flat, display-ordered list for checklists and review screens.
    public var items: [TemplateRequirement] {
        var out: [TemplateRequirement] = []
        func note(_ r: TemplateRequirement) -> TemplateRequirement {
            var copy = r
            if let n = notes[r.id], !n.isEmpty { copy.label = n }
            return copy
        }
        for m in models {
            out.append(
                note(
                    TemplateRequirement(
                        kind: .model, value: m.preferred ?? m.slot,
                        label: m.slot == ModelRequirement.agentSlot ? nil : m.slot,
                        policy: m.strictness == .always ? .always : .preferred,
                        slot: m.slot)))
        }
        for s in secrets {
            out.append(note(TemplateRequirement(kind: .secret, value: s.key, label: s.label)))
        }
        for name in mcpServers { out.append(note(TemplateRequirement(kind: .mcpServer, value: name))) }
        for id in plugins { out.append(note(TemplateRequirement(kind: .plugin, value: id))) }
        for raw in permissions {
            out.append(
                note(
                    TemplateRequirement(
                        kind: .systemPermission, value: raw,
                        label: SystemPermission(rawValue: raw)?.displayName)))
        }
        for host in network { out.append(note(TemplateRequirement(kind: .network, value: host))) }
        for name in tools { out.append(note(TemplateRequirement(kind: .tool, value: name))) }
        for name in knowledge {
            out.append(note(TemplateRequirement(kind: .knowledgeCollection, value: name)))
        }
        if let folder = workingFolder {
            out.append(
                note(
                    TemplateRequirement(
                        kind: .workingFolder, value: folder.path, label: folder.label)))
        }
        return out
    }
}

/// One requirement as a checklist row.
public struct TemplateRequirement: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case workingFolder = "working_folder"
        case knowledgeCollection = "knowledge_collection"
        case plugin
        case mcpServer = "mcp_server"
        case systemPermission = "system_permission"
        case model
        case secret
        case network
        case tool
    }

    /// Kept for agent-template call sites that name the policy directly.
    public typealias ModelPolicy = ModelStrictness

    public var kind: Kind
    public var label: String?
    public var value: String
    public var policy: ModelPolicy?
    /// Model rows only: the slot this row binds.
    public var slot: String?

    public var id: String {
        if kind == .model, let slot { return "model:\(slot.lowercased())" }
        return "\(kind.rawValue):\(value.lowercased())"
    }

    public init(
        kind: Kind, value: String, label: String? = nil, policy: ModelPolicy? = nil, slot: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.label = label
        self.policy = policy
        self.slot = slot
    }
}
