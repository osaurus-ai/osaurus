//
//  WorkflowConnections.swift
//  osaurus
//
//  Shared credentials for workflows. A connection is a named login to a
//  service ("GitHub (tpae)") that any workflow's secret can be bound to,
//  instead of pasting the same key into each workflow: a pasted key or
//  token, or an OAuth 2.0 sign-in whose access token is refreshed before
//  each run. The record (name, service, kind, OAuth endpoints, expiry)
//  lives in `connections.json` under the workflows directory; every value
//  is in the Keychain under `connection:<id>:<field>`
//  (`WorkflowSecretsKeychain`). Nothing here ever travels with a template.
//

import AppKit
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "workflow.connections")

public struct WorkflowConnection: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A key or token the person pasted.
        case value
        /// An OAuth 2.0 authorization-code sign-in with refresh.
        case oauth2
    }

    public let id: UUID
    public var name: String
    /// The service host it logs into, e.g. "api.github.com".
    public var service: String?
    public var kind: Kind
    public var oauth2: OAuth2Spec?
    /// When the stored access token stops working; nil for pasted values
    /// and tokens without an expiry.
    public var expiresAt: Date?
    /// A refresh token is stored, so an expired access token renews itself.
    public var canRefresh: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, service: String? = nil, kind: Kind, oauth2: OAuth2Spec? = nil,
        expiresAt: Date? = nil, canRefresh: Bool = false
    ) {
        self.id = id
        self.name = name
        self.service = service
        self.kind = kind
        self.oauth2 = oauth2
        self.expiresAt = expiresAt
        self.canRefresh = canRefresh
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// The binding a workflow secret uses to read this connection.
    public var binding: String { WorkflowSecretsKeychain.connectionBinding(id: id) }

    /// Expired, or about to, and no refresh token to renew it with.
    public func needsSignIn(now: Date = Date()) -> Bool {
        guard kind == .oauth2, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60) && !canRefresh
    }

    enum CodingKeys: String, CodingKey {
        case id, name, service, kind, oauth2
        case expiresAt = "expires_at"
        case canRefresh = "can_refresh"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        service = try c.decodeIfPresent(String.self, forKey: .service)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .value
        oauth2 = try c.decodeIfPresent(OAuth2Spec.self, forKey: .oauth2)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        canRefresh = try c.decodeIfPresent(Bool.self, forKey: .canRefresh) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

@MainActor
public final class WorkflowConnectionStore: ObservableObject {
    public static let shared = WorkflowConnectionStore()

    @Published public private(set) var connections: [WorkflowConnection] = []
    private var loaded = false

    nonisolated static var fileURL: URL { OsaurusPaths.workflows().appendingPathComponent("connections.json") }

    public init() {}

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    public func reload() {
        loaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.fileURL),
            let list = try? decoder.decode([WorkflowConnection].self, from: data)
        else {
            connections = []
            return
        }
        let repaired = list.map(Self.clearingDefaultExpiry)
        connections = repaired.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if repaired != list {
            persist()
        } else {
            SignInSessionStore.shared.syncConnections(connections)
        }
    }

    /// Sign-ins saved before the token parser told a missing `expires_in`
    /// apart from a stated one got exactly one hour, from when they were
    /// created or last stored, and no refresh token. Those tokens (Slack,
    /// GitHub, Notion) do not expire.
    nonisolated static func clearingDefaultExpiry(_ connection: WorkflowConnection) -> WorkflowConnection {
        guard connection.kind == .oauth2, !connection.canRefresh, let expiresAt = connection.expiresAt else {
            return connection
        }
        let fromDefault = [connection.createdAt, connection.updatedAt].contains {
            abs(expiresAt.timeIntervalSince($0) - 3600) < 5
        }
        guard fromDefault else { return connection }
        var copy = connection
        copy.expiresAt = nil
        return copy
    }

    public func connection(id: UUID) -> WorkflowConnection? {
        loadIfNeeded()
        return connections.first { $0.id == id }
    }

    /// The connection a secret binding names, when it still exists.
    public func connection(binding: String) -> WorkflowConnection? {
        WorkflowSecretsKeychain.connectionID(of: binding).flatMap(connection(id:))
    }

    /// Connections worth offering for a secret: all of them, those for the
    /// same service first.
    public func candidates(for secret: SecretRequirement) -> [WorkflowConnection] {
        loadIfNeeded()
        let host = secret.serviceHost
        return connections.sorted { a, b in
            let aMatch = host != nil && a.service == host
            let bMatch = host != nil && b.service == host
            if aMatch != bMatch { return aMatch }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Saves a pasted key or token as a connection. Returns nil when the
    /// Keychain refused the value.
    @discardableResult
    public func addValue(name: String, service: String?, value: String) -> WorkflowConnection? {
        let connection = WorkflowConnection(name: name, service: service, kind: .value)
        guard WorkflowSecretsKeychain.save(value, account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "value"))
        else { return nil }
        upsert(connection)
        return connection
    }

    public func upsert(_ connection: WorkflowConnection) {
        loadIfNeeded()
        var copy = connection
        copy.updatedAt = Date()
        connections.removeAll { $0.id == copy.id }
        connections.append(copy)
        connections.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    public func rename(_ id: UUID, to name: String) {
        guard var connection = connection(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != connection.name else { return }
        connection.name = trimmed
        upsert(connection)
    }

    /// Removes the connection and its Keychain values. Workflows bound to
    /// it show the secret as missing in setup.
    public func delete(id: UUID) {
        loadIfNeeded()
        connections.removeAll { $0.id == id }
        WorkflowSecretsKeychain.deleteConnection(id: id)
        persist()
    }

    /// Installed workflows with a secret bound to the connection.
    public func users(of id: UUID) -> [InstalledWorkflow] {
        let binding = WorkflowSecretsKeychain.connectionBinding(id: id)
        return InstalledWorkflowStore.shared.workflows.filter { $0.bindings.secrets.values.contains(binding) }
    }

    /// Whether the connection has a value a run can use right now (a
    /// pasted value, or an access token that is live or refreshable).
    public func hasValue(_ connection: WorkflowConnection) -> Bool {
        switch connection.kind {
        case .value:
            return WorkflowSecretsKeychain.hasValue(account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "value"))
        case .oauth2:
            guard WorkflowSecretsKeychain.hasValue(account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "access"))
            else { return false }
            return !connection.needsSignIn()
        }
    }

    private func persist() {
        do {
            try OsaurusPaths.ensureExists(OsaurusPaths.workflows())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(connections).write(to: Self.fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save connections: \(error.localizedDescription, privacy: .public)")
        }
        SignInSessionStore.shared.syncConnections(connections)
    }

    func resetForTesting() {
        connections = []
        loaded = false
        try? FileManager.default.removeItem(at: Self.fileURL)
    }
}

// MARK: - Resolving at run time

/// The connection a run actually reads for a secret bound to one: the
/// caller agent's session for that service, else the workflow's own pick.
public enum WorkflowConnectionSessions {
    public static func binding(for bound: String, agentId: UUID?) -> String {
        guard let id = WorkflowSecretsKeychain.connectionID(of: bound),
            let picked = SignInSessionResolver.state.session(id: id),
            let session = SignInSessionResolver.session(for: picked.service, agentId: agentId, preferred: id)
        else { return bound }
        return WorkflowSecretsKeychain.connectionBinding(id: session.id)
    }
}

/// What a run reads for a secret bound to a connection: the pasted value,
/// or a live OAuth access token, refreshed first when it has expired.
public enum WorkflowConnectionResolver {
    public enum Failure: Error, LocalizedError, Equatable {
        case missing(UUID)
        case noValue(String)
        case signInNeeded(String)
        case refreshFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .missing: return L("The connection this secret used was removed. Open Set Up and choose another.")
            case .noValue(let name): return L("The connection \"\(name)\" has no value. Open Set Up and enter it again.")
            case .signInNeeded(let name): return L("The sign-in for \"\(name)\" has expired. Open Set Up and sign in again.")
            case .refreshFailed(let name, let why): return L("Renewing the sign-in for \"\(name)\" failed: \(why)")
            }
        }
    }

    /// Test seam for the token refresh.
    nonisolated(unsafe) static var refreshOverride: (@Sendable (WorkflowConnection) async throws -> OAuth2ConnectionFlow.Tokens)?

    @MainActor
    public static func resolve(binding: String) async throws -> String? {
        guard let id = WorkflowSecretsKeychain.connectionID(of: binding) else { return nil }
        guard let connection = WorkflowConnectionStore.shared.connection(id: id) else { throw Failure.missing(id) }
        switch connection.kind {
        case .value:
            guard let value = WorkflowSecretsKeychain.read(account: WorkflowSecretsKeychain.connectionAccount(id: id, field: "value")),
                !value.isEmpty
            else { throw Failure.noValue(connection.name) }
            return value
        case .oauth2:
            let accessAccount = WorkflowSecretsKeychain.connectionAccount(id: id, field: "access")
            let live = connection.expiresAt.map { $0 > Date().addingTimeInterval(60) } ?? true
            if live, let token = WorkflowSecretsKeychain.read(account: accessAccount), !token.isEmpty { return token }
            guard connection.canRefresh else { throw Failure.signInNeeded(connection.name) }
            do {
                let tokens =
                    try await (refreshOverride ?? { try await OAuth2ConnectionFlow.refresh($0) })(connection)
                OAuth2ConnectionFlow.store(tokens, in: connection)
                return tokens.accessToken
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.refreshFailed(connection.name, error.localizedDescription)
            }
        }
    }
}

// MARK: - OAuth 2.0 sign-in

/// The authorization-code flow with PKCE for a workflow secret's
/// `OAuth2Spec`: opens the browser, catches the redirect on a loopback
/// port, exchanges the code, and stores the tokens in a connection.
public enum OAuth2ConnectionFlow {
    public struct Tokens: Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
    }

    public enum Failure: Error, LocalizedError {
        case badEndpoints([String])
        case clientIDMissing
        case browser
        case portBusy
        case timedOut
        case loopback(String)
        case exchange(String)

        public var errorDescription: String? {
            switch self {
            case .badEndpoints(let problems): return problems.joined(separator: "; ")
            case .clientIDMissing: return L("This sign-in needs a client id from the service's developer settings.")
            case .browser: return L("The browser could not be opened for the sign-in.")
            case .portBusy:
                return L(
                    "Port \(String(OAuth2ConnectionFlow.redirectPort)) is in use by another app or another sign-in that is still waiting. Finish or cancel it and try again."
                )
            case .timedOut:
                return L(
                    "No sign-in came back from the browser. If the service showed a redirect URL error, add \(OAuth2ConnectionFlow.redirectURL) to its app settings and sign in again."
                )
            case .loopback(let why): return L("The sign-in could not finish: \(why)")
            case .exchange(let why): return L("The service refused the sign-in: \(why)")
            }
        }
    }

    public static let callbackTimeout: TimeInterval = 300

    /// Every workflow sign-in listens here, so the redirect URL a person
    /// registers with the service is the same every time. Dropbox, Notion,
    /// Linear, and Microsoft (for 127.0.0.1) match the port exactly.
    public static let redirectPort: UInt16 = 47823
    public static let redirectPath = "/callback"
    public static var redirectURL: String { "http://127.0.0.1:\(redirectPort)\(redirectPath)" }

    /// A sign-in in this app is waiting on `redirectPort`.
    @MainActor private static var listening = false

    /// Test seam: stands in for opening the browser on the authorize URL.
    nonisolated(unsafe) static var openBrowserOverride: (@MainActor (URL) async -> Bool)?

    /// The authorize URL the browser opens.
    static func authorizationURL(spec: OAuth2Spec, clientID: String, codeChallenge: String, state: String) -> URL {
        var url = MCPOAuthService.authorizationURL(
            authorizationEndpoint: URL(string: spec.authorizeURL)!, clientId: clientID, redirectURI: redirectURL,
            codeChallenge: codeChallenge, state: state, scopes: [], resource: nil)
        var extra: [URLQueryItem] = []
        if !spec.scopes.isEmpty {
            extra.append(URLQueryItem(name: "scope", value: spec.scopes.joined(separator: spec.scopeSeparator)))
        }
        extra += spec.authorizeParameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !extra.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + extra
            url = components.url ?? url
        }
        return url
    }

    /// Where the client secret goes: HTTP Basic when the spec says so,
    /// otherwise the body.
    static func tokenCredentials(
        spec: OAuth2Spec, form: [String: String], clientID: String, clientSecret: String?
    ) -> (form: [String: String], basic: (String, String)?) {
        guard let clientSecret, !clientSecret.isEmpty else { return (form, nil) }
        if spec.clientSecretBasic { return (form, (clientID, clientSecret)) }
        var form = form
        form["client_secret"] = clientSecret
        return (form, nil)
    }

    /// The token endpoint POST the spec calls for.
    static func tokenURLRequest(
        spec: OAuth2Spec, url: URL, form: [String: String], clientID: String, clientSecret: String?
    ) -> URLRequest {
        let parts = tokenCredentials(spec: spec, form: form, clientID: clientID, clientSecret: clientSecret)
        return MCPOAuthService.tokenURLRequest(url: url, form: parts.form, basicCredentials: parts.basic, json: spec.jsonTokenBody)
    }

    static func tokenRequest(
        spec: OAuth2Spec, url: URL, form: [String: String], clientID: String, clientSecret: String?
    ) async throws -> MCPOAuthService.ParsedTokenResponse {
        let parts = tokenCredentials(spec: spec, form: form, clientID: clientID, clientSecret: clientSecret)
        return try await MCPOAuthService.postTokenRequest(
            url: url, form: parts.form, basicCredentials: parts.basic, json: spec.jsonTokenBody)
    }

    /// A token response's expiry. A token that states none (Slack without
    /// rotation, GitHub OAuth Apps) does not expire.
    static func expiry(of parsed: MCPOAuthService.ParsedTokenResponse) -> Date? {
        parsed.expiresIn.map { Date().addingTimeInterval($0) }
    }

    /// Signs in and saves the result as a new connection named `name`.
    /// `clientID` and `clientSecret` fill in what the spec does not carry.
    /// With `replacing`, the tokens of that existing connection are
    /// replaced instead (its client id and secret are reused).
    @MainActor
    public static func signIn(
        spec: OAuth2Spec, name: String, clientID: String? = nil, clientSecret: String? = nil,
        replacing existing: WorkflowConnection? = nil
    ) async throws -> WorkflowConnection {
        let problems = spec.problems
        guard problems.isEmpty else { throw Failure.badEndpoints(problems) }
        guard let clientID = (clientID?.isEmpty == false ? clientID : spec.clientID), !clientID.isEmpty else {
            throw Failure.clientIDMissing
        }
        let clientSecret: String? = {
            if let clientSecret, !clientSecret.isEmpty { return clientSecret }
            guard let existing else { return nil }
            return WorkflowSecretsKeychain.read(
                account: WorkflowSecretsKeychain.connectionAccount(id: existing.id, field: "client_secret"))
        }()
        guard !listening else { throw Failure.portBusy }
        listening = true
        defer { listening = false }
        let pkce = try PKCE.makePair()
        let state = PKCE.makeState()
        let server: OAuthLoopbackServer
        do {
            server = try OAuthLoopbackServer(
                expectedState: state, port: .fixed(redirectPort), callbackPath: redirectPath, reuseAddress: true)
            try await server.start()
        } catch {
            throw Failure.portBusy
        }
        defer { server.stop() }
        try Task.checkCancellation()

        let url = authorizationURL(spec: spec, clientID: clientID, codeChallenge: pkce.challenge, state: state)
        let opened = await (openBrowserOverride ?? { await NSWorkspace.shared.openAsync($0) })(url)
        guard opened else { throw Failure.browser }

        let callback: OAuthCallbackResult
        do {
            callback = try await server.waitForCallback(timeout: callbackTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch OAuthLoopbackError.callbackTimeout {
            throw Failure.timedOut
        } catch {
            throw Failure.loopback(error.localizedDescription)
        }
        try Task.checkCancellation()
        let parsed: MCPOAuthService.ParsedTokenResponse
        do {
            parsed = try await tokenRequest(
                spec: spec, url: URL(string: spec.tokenURL)!,
                form: [
                    "grant_type": "authorization_code", "client_id": clientID, "code": callback.code,
                    "code_verifier": pkce.verifier, "redirect_uri": redirectURL,
                ],
                clientID: clientID, clientSecret: clientSecret)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.exchange(error.localizedDescription)
        }
        let tokens = Tokens(accessToken: parsed.accessToken, refreshToken: parsed.refreshToken, expiresAt: expiry(of: parsed))
        var spec = spec
        spec.clientID = clientID
        var connection =
            existing
            ?? WorkflowConnection(
                name: name, service: spec.serviceHost, kind: .oauth2, oauth2: spec,
                expiresAt: tokens.expiresAt, canRefresh: tokens.refreshToken?.isEmpty == false)
        connection.oauth2 = spec
        if let clientSecret, !clientSecret.isEmpty {
            WorkflowSecretsKeychain.save(
                clientSecret, account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "client_secret"))
        }
        store(tokens, in: connection)
        connection = WorkflowConnectionStore.shared.connection(id: connection.id) ?? connection
        return connection
    }

    /// Renews an expired access token with the stored refresh token.
    public static func refresh(_ connection: WorkflowConnection) async throws -> Tokens {
        guard let spec = connection.oauth2, let clientID = spec.clientID, let tokenURL = URL(string: spec.tokenURL) else {
            throw Failure.clientIDMissing
        }
        guard let refreshToken = WorkflowSecretsKeychain.read(account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "refresh")),
            !refreshToken.isEmpty
        else { throw WorkflowConnectionResolver.Failure.signInNeeded(connection.name) }
        var form: [String: String] = [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID,
        ]
        if !spec.scopes.isEmpty { form["scope"] = spec.scopes.joined(separator: spec.scopeSeparator) }
        let secret = WorkflowSecretsKeychain.read(
            account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "client_secret"))
        let parsed: MCPOAuthService.ParsedTokenResponse
        do {
            parsed = try await tokenRequest(spec: spec, url: tokenURL, form: form, clientID: clientID, clientSecret: secret)
        } catch {
            throw Failure.exchange(error.localizedDescription)
        }
        return Tokens(
            accessToken: parsed.accessToken, refreshToken: parsed.refreshToken ?? refreshToken, expiresAt: expiry(of: parsed))
    }

    /// Writes tokens to the Keychain and the expiry to the record.
    @MainActor
    public static func store(_ tokens: Tokens, in connection: WorkflowConnection) {
        WorkflowSecretsKeychain.save(
            tokens.accessToken, account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "access"))
        if let refresh = tokens.refreshToken, !refresh.isEmpty {
            WorkflowSecretsKeychain.save(refresh, account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "refresh"))
        }
        var updated = connection
        updated.expiresAt = tokens.expiresAt
        updated.canRefresh = connection.canRefresh || tokens.refreshToken?.isEmpty == false
        WorkflowConnectionStore.shared.upsert(updated)
    }
}
