//
//  SignInSessionTests.swift
//  OsaurusCoreTests
//
//  Sign-in sessions: which one a request gets (the agent's, then the
//  workflow's pick, then the default), what happens when one is removed or
//  an agent is deleted, workflow connections as sessions, and each extra
//  session's own Keychain account.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SignInSessionTests {

    // MARK: - Resolution

    @Test func resolve_agentThenPreferredThenDefault() {
        let service = SignInService.mcp(UUID())
        var state = SignInSessionState()
        let work = SignInSession(service: service, name: "Work", isPrimary: true)
        let personal = SignInSession(service: service, name: "Personal")
        let other = SignInSession(service: .mcp(UUID()), name: "Elsewhere")
        state.sessions = [work, personal, other]
        state.defaults[service.key] = work.id
        let scout = UUID()
        state.agentAssignments[scout.uuidString] = [service.key: personal.id]

        #expect(state.resolve(service, agentId: nil)?.id == work.id)
        #expect(state.resolve(service, agentId: UUID())?.id == work.id, "an agent with no pick gets the default")
        #expect(state.resolve(service, agentId: scout)?.id == personal.id)
        #expect(state.resolve(service, agentId: nil, preferred: personal.id)?.id == personal.id)
        #expect(state.resolve(service, agentId: nil, preferred: other.id)?.id == work.id, "another service's pick is ignored")
        #expect(state.agents(using: personal.id) == [scout])
        #expect(state.resolve(.mcp(UUID()), agentId: scout) == nil, "a service with no sessions resolves to nothing")
    }

    @Test func resolve_builtInAgentsGetTheDefault() {
        let service = SignInService.modelProvider(UUID())
        var state = SignInSessionState()
        let main = SignInSession(service: service, name: "Default", isPrimary: true)
        let alt = SignInSession(service: service, name: "Alt")
        state.sessions = [main, alt]
        state.agentAssignments[Agent.defaultId.uuidString] = [service.key: alt.id]
        #expect(SignInSessionResolver.sessionAgent(Agent.defaultId) == nil)
        #expect(SignInSessionResolver.sessionAgent(Agent.architectId) == nil)
        #expect(state.resolve(service, agentId: SignInSessionResolver.sessionAgent(Agent.defaultId))?.id == main.id)
    }

    @Test func serviceKeys_roundTrip() throws {
        let services: [SignInService] = [
            .connection("api.github.com"), .mcp(UUID()), .modelProvider(UUID()), .channel(.discord),
        ]
        for service in services { #expect(SignInService(key: service.key) == service) }
        #expect(SignInService(key: "nonsense") == nil)
        let state = SignInSessionState()
        let decoded = try JSONDecoder().decode(SignInSessionState.self, from: Data("{}".utf8))
        #expect(decoded == state)
    }

    // MARK: - Store

    @Test @MainActor func store_removingTheDefaultHandsItOn_andDropsAssignments() {
        let store = SignInSessionStore.shared
        let service = SignInService.mcp(UUID())
        let first = store.ensurePrimary(for: service)
        #expect(store.ensurePrimary(for: service).id == first.id, "repeating it adds nothing")
        let second = store.add(service: service, name: "  Work  ")
        #expect(second.name == "Work")
        #expect(store.isDefault(first))

        let agent = UUID()
        store.assign(agentId: agent, service: service, sessionId: second.id)
        #expect(SignInSessionResolver.session(for: service, agentId: agent)?.id == second.id)
        #expect(SignInSessionResolver.session(for: service, agentId: nil)?.id == first.id)

        store.makeDefault(second.id)
        #expect(SignInSessionResolver.session(for: service, agentId: nil)?.id == second.id)
        store.remove(second.id)
        #expect(store.defaultSession(for: service)?.id == first.id)
        #expect(store.assignment(agentId: agent, service: service) == nil)
        #expect(SignInSessionResolver.session(for: service, agentId: agent)?.id == first.id)
        store.remove(first.id)
        #expect(store.sessions(for: service).isEmpty)
    }

    @Test @MainActor func store_deletingAnAgentDropsItsPicks() {
        let store = SignInSessionStore.shared
        let service = SignInService.modelProvider(UUID())
        _ = store.ensurePrimary(for: service)
        let alt = store.add(service: service, name: "Alt")
        let agent = UUID()
        store.assign(agentId: agent, service: service, sessionId: alt.id)
        store.assign(agentId: agent, service: .mcp(UUID()), sessionId: alt.id)
        #expect(store.assignment(agentId: agent, service: service)?.id == alt.id)
        #expect(store.agents(using: alt.id) == [agent], "a session of another service is never assigned")
        store.removeAgent(agent)
        #expect(store.agents(using: alt.id).isEmpty)
        for session in store.sessions(for: service) { store.remove(session.id) }
    }

    @Test @MainActor func store_mirrorsWorkflowConnections() {
        let store = SignInSessionStore.shared
        let host = "api.\(UUID().uuidString.prefix(8).lowercased()).example"
        let a = WorkflowConnection(name: "GitHub (work)", service: host, kind: .value)
        let b = WorkflowConnection(name: "GitHub (home)", service: host, kind: .value)
        let existing = WorkflowConnectionStore.shared.connections
        store.syncConnections(existing + [a, b])
        let service = SignInService.connection(host)
        #expect(Set(store.sessions(for: service).map(\.id)) == [a.id, b.id])
        #expect(store.defaultSession(for: service)?.id == a.id)

        var renamed = a
        renamed.name = "GitHub (job)"
        store.syncConnections(existing + [renamed])
        #expect(store.sessions(for: service).map(\.id) == [a.id], "a deleted connection's session goes")
        #expect(store.session(id: a.id)?.name == "GitHub (job)")
        store.syncConnections(existing)
        #expect(store.sessions(for: service).isEmpty)
    }

    // MARK: - MCP

    @Test @MainActor func mcp_anAgentWithItsOwnSessionGetsItsOwnClient() {
        let provider = MCPProvider(name: "Linear", url: "https://mcp.example.com", authType: .oauth)
        let store = SignInSessionStore.shared
        let main = store.ensurePrimary(for: .mcp(provider.id))
        let second = store.add(service: .mcp(provider.id), name: "Second")
        defer {
            store.remove(main.id)
            store.remove(second.id)
        }
        let scout = UUID()
        #expect(!MCPCredentials.agentHasOverride(provider, agentId: scout))
        store.assign(agentId: scout, service: .mcp(provider.id), sessionId: second.id)
        #expect(MCPCredentials.agentHasOverride(provider, agentId: scout))
        #expect(MCPCredentials.signInSession(provider, agentId: scout)?.keychainSession == second.id)
        #expect(MCPCredentials.signInSession(provider, agentId: nil)?.keychainSession == nil, "the default is the primary")
        #expect(
            MCPCredentials.fingerprint(provider, agentId: scout) != MCPCredentials.fingerprint(provider, agentId: nil))

        store.assign(agentId: Agent.defaultId, service: .mcp(provider.id), sessionId: second.id)
        #expect(!MCPCredentials.agentHasOverride(provider, agentId: Agent.defaultId), "the Orchestrator uses the default")
        store.removeAgent(Agent.defaultId)

        var bearer = provider
        bearer.authType = .bearerToken
        #expect(MCPCredentials.signInSession(bearer, agentId: scout) == nil, "sessions are for OAuth sign-ins")
    }

    // MARK: - Model providers

    @Test @MainActor func modelProvider_requestsSignInAsTheAgentsSession() async throws {
        let provider = RemoteProvider(
            name: "xAI", host: "api.x.ai", basePath: "/v1", authType: .xaiOAuth, providerType: .openaiLegacy)
        func tokens(_ access: String) -> RemoteProviderOAuthTokens {
            RemoteProviderOAuthTokens(
                accessToken: access, refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), accountId: "a")
        }
        let service = RemoteProviderService(
            provider: provider, models: ["grok-4"], resolvedHeaders: [:], cachedOAuthTokens: tokens("main"))
        let store = SignInSessionStore.shared
        let main = store.ensurePrimary(for: .modelProvider(provider.id))
        let second = store.add(service: .modelProvider(provider.id), name: "Second")
        defer {
            store.remove(main.id)
            store.remove(second.id)
            RemoteProviderKeychain.deleteOAuthTokens(for: provider.id, session: second.id)
        }
        RemoteProviderKeychain.saveOAuthTokens(tokens("second"), for: provider.id, session: second.id)
        let scout = UUID()
        store.assign(agentId: scout, service: .modelProvider(provider.id), sessionId: second.id)

        func bearer(agent: UUID?, sharedOnly: Bool = false) async throws -> String? {
            try await ChatExecutionContext.$currentAgentId.withValue(agent) {
                try await ChatExecutionContext.$usesSharedKeysOnly.withValue(sharedOnly) {
                    let request = await service.buildChatRequest(
                        messages: [ChatMessage(role: "user", content: "hi")],
                        parameters: GenerationParameters(temperature: 0.7, maxTokens: 16),
                        model: "grok-4", stream: true, tools: nil, toolChoice: nil)
                    return try await service.buildURLRequest(for: request).value(forHTTPHeaderField: "Authorization")
                }
            }
        }
        #expect(try await bearer(agent: scout) == "Bearer second")
        #expect(try await bearer(agent: nil) == "Bearer main")
        #expect(try await bearer(agent: UUID()) == "Bearer main", "no pick: the default")
        #expect(try await bearer(agent: scout, sharedOnly: true) == "Bearer main", "a shared-keys run")
    }

    // MARK: - Keychain accounts

    @Test func extraSessions_keepTheirOwnTokens() {
        let provider = UUID()
        let session = UUID()
        let tokens = RemoteProviderOAuthTokens(
            accessToken: "alt-access", refreshToken: "alt-refresh", expiresAt: Date().addingTimeInterval(3600),
            accountId: "acct")
        #expect(RemoteProviderKeychain.saveOAuthTokens(tokens, for: provider, session: session))
        #expect(RemoteProviderKeychain.getOAuthTokens(for: provider, session: session) == tokens)
        #expect(RemoteProviderKeychain.oauthTokensAvailability(for: provider, session: session) == .present)
        #expect(RemoteProviderKeychain.getOAuthTokens(for: provider, session: UUID()) == nil)
        RemoteProviderKeychain.deleteOAuthTokens(for: provider, session: session)
        #expect(RemoteProviderKeychain.getOAuthTokens(for: provider, session: session) == nil)

        let mcp = MCPOAuthTokens(
            accessToken: "mcp-alt", refreshToken: nil, expiresAt: Date().addingTimeInterval(3600), scope: nil)
        #expect(MCPProviderKeychain.saveOAuthTokens(mcp, for: provider, session: session))
        #expect(MCPProviderKeychain.getOAuthTokens(for: provider, session: session) == mcp)
        MCPProviderKeychain.deleteOAuthTokens(for: provider, session: session)
        #expect(MCPProviderKeychain.oauthTokensAvailability(for: provider, session: session) == .absent)
    }

    @Test func channelBots_extraSessionsHoldTheirOwnToken() {
        let session = SignInSession(service: .channel(.discord), name: "Second bot")
        #expect(ChannelSessions.botToken(.discord, session: session) == nil)
        #expect(ChannelSessions.saveBotToken("  bot-two  ", kind: .discord, session: session))
        #expect(ChannelSessions.botToken(.discord, session: session) == "bot-two")
        ChannelSessions.deleteBotToken(.discord, session: session)
        #expect(ChannelSessions.botToken(.discord, session: session) == nil)
    }

    @Test @MainActor func slackWorkspaces_areSessionsFoundByTeam() {
        let store = SignInSessionStore.shared
        let acme = ChannelAccount(
            kind: .slack, connectionId: "slack-t0acme", name: "Acme", isPrimary: false, sessionId: nil,
            reference: "T0ACME")
        let beta = ChannelAccount(
            kind: .slack, connectionId: "slack-t0beta", name: "T0BETA", isPrimary: false, sessionId: nil,
            reference: "T0BETA")
        SignInSessionSync.syncSlackWorkspaces([acme, beta])
        defer { SignInSessionSync.syncSlackWorkspaces([]) }
        let sessions = store.sessions(for: .channel(.slack)).filter { $0.reference != nil }
        #expect(Set(sessions.map(\.name)) == ["Acme", "T0BETA"])
        let acmeSession = try? #require(sessions.first { $0.reference == "T0ACME" })

        store.rename(acmeSession?.id ?? UUID(), to: "Acme HQ")
        SignInSessionSync.syncSlackWorkspaces([acme])
        let left = store.sessions(for: .channel(.slack)).filter { $0.reference != nil }
        #expect(left.map(\.name) == ["Acme HQ"], "a rename stays; a removed workspace goes")
        #expect(ChannelSessions.botToken(.slack, session: left.first) == nil)
    }

    @Test func status_readsTheSessionsOwnAccount() {
        let provider = UUID()
        let session = SignInSession(service: .modelProvider(provider), name: "Alt")
        #expect(SignInSessionActions.status(of: session, connection: nil) == .signedOut)
        RemoteProviderKeychain.saveOAuthTokens(
            RemoteProviderOAuthTokens(
                accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), accountId: "x"),
            for: provider, session: session.id)
        #expect(SignInSessionActions.status(of: session, connection: nil) == .signedIn)
        RemoteProviderKeychain.deleteOAuthTokens(for: provider, session: session.id)
    }
}
