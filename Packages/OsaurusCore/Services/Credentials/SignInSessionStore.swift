//
//  SignInSessionStore.swift
//  osaurus
//
//  Sign-in sessions on disk (`credentials/sessions.json`): the sessions,
//  each service's default, and which session each agent uses. The store
//  is main-actor; `SignInSessionResolver` reads a lock-protected copy so
//  actors (model providers, MCP servers) resolve without hopping.
//

import Combine
import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "credentials.sessions")

extension Foundation.Notification.Name {
    /// Sessions, defaults, or an agent's assignments changed.
    public static let signInSessionsDidChange = Foundation.Notification.Name("ai.osaurus.signInSessionsDidChange")
}

/// Which session a request signs in with.
public enum SignInSessionResolver {
    private static let snapshot = OSAllocatedUnfairLock(initialState: SignInSessionStore.loadFromDisk())

    public static var state: SignInSessionState { snapshot.withLock { $0 } }

    static func publish(_ state: SignInSessionState) {
        snapshot.withLock { $0 = state }
    }

    /// The agent's assignment, then `preferred`, then the default.
    public static func session(
        for service: SignInService, agentId: UUID?, preferred: UUID? = nil
    ) -> SignInSession? {
        state.resolve(service, agentId: sessionAgent(agentId), preferred: preferred)
    }

    /// The session the current request uses for the service.
    public static func currentSession(for service: SignInService, preferred: UUID? = nil) -> SignInSession? {
        session(for: service, agentId: requestAgent, preferred: preferred)
    }

    /// The agent whose own sessions the current request uses: nil for a
    /// workflow run on shared keys and for the Orchestrator and Architect,
    /// which use each service's default. Same rule as keys.
    public static var requestAgent: UUID? {
        if ChatExecutionContext.usesSharedKeysOnly { return nil }
        return sessionAgent(ChatExecutionContext.currentAgentId)
    }

    /// nil for the built-in agents, which always use the defaults.
    public static func sessionAgent(_ id: UUID?) -> UUID? {
        guard let id, id != Agent.defaultId, id != Agent.architectId else { return nil }
        return id
    }
}

@MainActor
public final class SignInSessionStore: ObservableObject {
    public static let shared = SignInSessionStore()

    @Published public private(set) var state: SignInSessionState

    nonisolated static var fileURL: URL { OsaurusPaths.credentials().appendingPathComponent("sessions.json") }

    private init() {
        state = SignInSessionResolver.state
    }

    nonisolated static func loadFromDisk() -> SignInSessionState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL) else { return SignInSessionState() }
        do {
            return try decoder.decode(SignInSessionState.self, from: data)
        } catch {
            logger.error("Unreadable sessions.json: \(error.localizedDescription, privacy: .public)")
            return SignInSessionState()
        }
    }

    // MARK: - Reading

    public var sessions: [SignInSession] { state.sessions }

    public func session(id: UUID) -> SignInSession? { state.session(id: id) }

    public func sessions(for service: SignInService) -> [SignInSession] { state.sessions(for: service) }

    public func defaultSession(for service: SignInService) -> SignInSession? { state.defaultSession(for: service) }

    public func isDefault(_ session: SignInSession) -> Bool {
        state.defaultSession(for: session.service)?.id == session.id
    }

    /// The session the agent was assigned, nil when it uses the default.
    public func assignment(agentId: UUID, service: SignInService) -> SignInSession? {
        state.assignment(agentId: agentId, service: service)
    }

    public func agents(using sessionId: UUID) -> [UUID] { state.agents(using: sessionId) }

    /// Every service with a session, in a stable order.
    public var services: [SignInService] {
        var seen = Set<String>()
        return state.sessions.compactMap { seen.insert($0.service.key).inserted ? $0.service : nil }
    }

    // MARK: - Changing

    /// Adds a session. The first one of a service becomes its default.
    @discardableResult
    public func add(
        service: SignInService, name: String, accountLabel: String? = nil, isPrimary: Bool = false,
        reference: String? = nil, id: UUID = UUID()
    ) -> SignInSession {
        if let existing = state.session(id: id) { return existing }
        let session = SignInSession(
            id: id, service: service, name: Self.cleanName(name, fallback: L("Session")),
            accountLabel: accountLabel, isPrimary: isPrimary, reference: reference)
        mutate { state in
            state.sessions.append(session)
            if state.defaults[service.key] == nil { state.defaults[service.key] = session.id }
        }
        return session
    }

    /// The service's primary session, added as "Main" when missing.
    @discardableResult
    public func ensurePrimary(for service: SignInService, accountLabel: String? = nil) -> SignInSession {
        if var primary = state.sessions(for: service).first(where: \.isPrimary) {
            if let accountLabel, !accountLabel.isEmpty, primary.accountLabel != accountLabel {
                primary.accountLabel = accountLabel
                replace(primary)
            }
            return primary
        }
        return add(service: service, name: L("Main"), accountLabel: accountLabel, isPrimary: true)
    }

    public func rename(_ id: UUID, to name: String) {
        guard var session = state.session(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.name else { return }
        session.name = trimmed
        replace(session)
    }

    public func setAccountLabel(_ label: String?, id: UUID) {
        guard var session = state.session(id: id), session.accountLabel != label else { return }
        session.accountLabel = label
        replace(session)
    }

    public func makeDefault(_ id: UUID) {
        guard let session = state.session(id: id), state.defaults[session.service.key] != id else { return }
        mutate { $0.defaults[session.service.key] = id }
    }

    /// Removes the record only; the owner deletes its tokens. The default
    /// moves to the next session, and agents assigned it use the default.
    public func remove(_ id: UUID) {
        guard let session = state.session(id: id) else { return }
        mutate { state in
            state.sessions.removeAll { $0.id == id }
            if state.defaults[session.service.key] == id {
                state.defaults[session.service.key] = state.sessions(for: session.service).first?.id
            }
            for agent in state.agentAssignments.keys {
                state.agentAssignments[agent] = state.agentAssignments[agent]?.filter { $0.value != id }
                if state.agentAssignments[agent]?.isEmpty == true { state.agentAssignments[agent] = nil }
            }
        }
    }

    /// Gives the agent its own session for the service; nil returns it to the default.
    public func assign(agentId: UUID, service: SignInService, sessionId: UUID?) {
        if let sessionId, state.session(id: sessionId)?.service != service { return }
        guard state.agentAssignments[agentId.uuidString]?[service.key] != sessionId else { return }
        mutate { state in
            var services = state.agentAssignments[agentId.uuidString] ?? [:]
            services[service.key] = sessionId
            state.agentAssignments[agentId.uuidString] = services.isEmpty ? nil : services
        }
    }

    /// Drops a deleted agent's assignments.
    public func removeAgent(_ agentId: UUID) {
        guard state.agentAssignments[agentId.uuidString] != nil else { return }
        mutate { $0.agentAssignments[agentId.uuidString] = nil }
    }

    /// Mirrors workflow connections: one session per connection, same id.
    public func syncConnections(_ connections: [WorkflowConnection]) {
        let ids = Set(connections.map(\.id))
        var next = state
        for connection in connections {
            let service = SignInService.connection(connection)
            if var session = next.session(id: connection.id) {
                guard session.name != connection.name || session.service != service else { continue }
                session.name = connection.name
                session.service = service
                next.sessions = next.sessions.map { $0.id == session.id ? session : $0 }
            } else {
                next.sessions.append(
                    SignInSession(
                        id: connection.id, service: service, name: connection.name, createdAt: connection.createdAt))
            }
            if next.defaults[service.key] == nil { next.defaults[service.key] = connection.id }
        }
        let gone = next.sessions.filter {
            if case .connection = $0.service { return !ids.contains($0.id) }
            return false
        }
        guard next != state || !gone.isEmpty else { return }
        state = next
        persistAndPublish()
        for session in gone { remove(session.id) }
    }

    func resetForTesting() {
        state = SignInSessionState()
        try? FileManager.default.removeItem(at: Self.fileURL)
        SignInSessionResolver.publish(state)
    }

    // MARK: - Private

    private func replace(_ session: SignInSession) {
        mutate { state in state.sessions = state.sessions.map { $0.id == session.id ? session : $0 } }
    }

    private func mutate(_ change: (inout SignInSessionState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        persistAndPublish()
    }

    private func persistAndPublish() {
        SignInSessionResolver.publish(state)
        do {
            try OsaurusPaths.ensureExists(OsaurusPaths.credentials())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: Self.fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save sessions: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.post(name: .signInSessionsDidChange, object: nil)
    }

    private static func cleanName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
