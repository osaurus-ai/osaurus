//
//  SignInSession.swift
//  osaurus
//
//  A named sign-in to one service ("Work", "Personal"). Every service with
//  a sign-in (a workflow connection's service, an MCP server, a model
//  provider, a channel's bot) can hold several; one is its default, and an
//  agent can be assigned its own. Only the record lives here; tokens stay
//  in the Keychain account of the backend that owns them.
//

import Foundation

/// What a session signs in to.
public enum SignInService: Hashable, Sendable {
    /// Workflow connections to one service host ("api.github.com"). A
    /// connection without a host is a service of its own.
    case connection(String)
    case mcp(UUID)
    case modelProvider(UUID)
    case channel(AgentChannelKind)

    /// The key sessions, defaults, and assignments are stored under.
    public var key: String {
        switch self {
        case .connection(let host): "connection:\(host)"
        case .mcp(let id): "mcp:\(id.uuidString)"
        case .modelProvider(let id): "provider:\(id.uuidString)"
        case .channel(let kind): "channel:\(kind.rawValue)"
        }
    }

    public init?(key: String) {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let kind = key[..<colon]
        let rest = String(key[key.index(after: colon)...])
        switch kind {
        case "connection" where !rest.isEmpty: self = .connection(rest)
        case "mcp": guard let id = UUID(uuidString: rest) else { return nil }; self = .mcp(id)
        case "provider": guard let id = UUID(uuidString: rest) else { return nil }; self = .modelProvider(id)
        case "channel": guard let channel = AgentChannelKind(rawValue: rest) else { return nil }; self = .channel(channel)
        default: return nil
        }
    }

    /// The service a workflow connection belongs to.
    public static func connection(_ connection: WorkflowConnection) -> SignInService {
        .connection(connection.service ?? "connection-\(connection.id.uuidString.lowercased())")
    }

    /// "Connection", "MCP server", "Model provider", "Channel".
    public var kindLabel: String {
        switch self {
        case .connection: L("Connection")
        case .mcp: L("MCP server")
        case .modelProvider: L("Model provider")
        case .channel: L("Channel")
        }
    }
}

extension SignInService: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let service = SignInService(key: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "service \(raw)"))
        }
        self = service
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

public struct SignInSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var service: SignInService
    public var name: String
    /// The account it is signed in as (an email, a team), when known.
    public var accountLabel: String?
    /// Its tokens are in the service's original Keychain account: the
    /// sign-in made from Tools, Providers, or Channels. Other sessions keep
    /// theirs in a per-session account.
    public var isPrimary: Bool
    /// The backend's own id for it, when it has one (a Slack team id).
    public var reference: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), service: SignInService, name: String, accountLabel: String? = nil,
        isPrimary: Bool = false, reference: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.service = service
        self.name = name
        self.accountLabel = accountLabel
        self.isPrimary = isPrimary
        self.reference = reference
        self.createdAt = createdAt
    }

    /// The session a backend's Keychain helpers take: nil for the primary
    /// one, whose tokens are in the service's original account.
    public var keychainSession: UUID? { isPrimary ? nil : id }

    enum CodingKeys: String, CodingKey {
        case id, service, name, reference
        case accountLabel = "account_label"
        case isPrimary = "is_primary"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        service = try c.decode(SignInService.self, forKey: .service)
        name = try c.decode(String.self, forKey: .name)
        accountLabel = try c.decodeIfPresent(String.self, forKey: .accountLabel)
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        reference = try c.decodeIfPresent(String.self, forKey: .reference)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Every session, each service's default, and each agent's assignments.
public struct SignInSessionState: Codable, Equatable, Sendable {
    public var sessions: [SignInSession] = []
    /// Service key -> default session.
    public var defaults: [String: UUID] = [:]
    /// Agent id -> service key -> the session that agent uses.
    public var agentAssignments: [String: [String: UUID]] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case sessions, defaults
        case agentAssignments = "agent_assignments"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([SignInSession].self, forKey: .sessions) ?? []
        defaults = try c.decodeIfPresent([String: UUID].self, forKey: .defaults) ?? [:]
        agentAssignments = try c.decodeIfPresent([String: [String: UUID]].self, forKey: .agentAssignments) ?? [:]
    }

    public func session(id: UUID) -> SignInSession? { sessions.first { $0.id == id } }

    /// The service's sessions, the primary one first, then oldest first.
    public func sessions(for service: SignInService) -> [SignInSession] {
        sessions.filter { $0.service == service }.sorted { a, b in
            a.isPrimary != b.isPrimary ? a.isPrimary : a.createdAt < b.createdAt
        }
    }

    public func defaultSession(for service: SignInService) -> SignInSession? {
        let own = sessions(for: service)
        if let id = defaults[service.key], let session = own.first(where: { $0.id == id }) { return session }
        return own.first
    }

    /// The session the agent was assigned for the service, when it still exists.
    public func assignment(agentId: UUID, service: SignInService) -> SignInSession? {
        guard let id = agentAssignments[agentId.uuidString]?[service.key], let session = session(id: id),
            session.service == service
        else { return nil }
        return session
    }

    /// The session a run uses: the agent's assignment, then `preferred`
    /// (a workflow's own pick), then the service's default, then its only
    /// session. nil when the service has no sessions yet.
    public func resolve(_ service: SignInService, agentId: UUID?, preferred: UUID? = nil) -> SignInSession? {
        if let agentId, let assigned = assignment(agentId: agentId, service: service) { return assigned }
        if let preferred, let session = session(id: preferred), session.service == service { return session }
        return defaultSession(for: service)
    }

    /// Each agent with its own session for the service.
    public func assignments(for service: SignInService) -> [(agentId: UUID, session: SignInSession)] {
        agentAssignments.compactMap { agent, services in
            guard let agentId = UUID(uuidString: agent), let id = services[service.key], let session = session(id: id),
                session.service == service
            else { return nil }
            return (agentId, session)
        }.sorted { $0.agentId.uuidString < $1.agentId.uuidString }
    }

    /// Agents assigned the session.
    public func agents(using sessionId: UUID) -> [UUID] {
        agentAssignments.compactMap { agent, services in
            services.values.contains(sessionId) ? UUID(uuidString: agent) : nil
        }.sorted { $0.uuidString < $1.uuidString }
    }
}
