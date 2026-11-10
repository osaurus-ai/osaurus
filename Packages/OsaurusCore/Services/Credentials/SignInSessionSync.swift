//
//  SignInSessionSync.swift
//  osaurus
//
//  Keeps sessions in step with the sign-ins that exist: every workflow
//  connection is a session (same id), and every service already signed in
//  from Tools, Providers, or Channels gets its "Main" session, which
//  keeps the Keychain account it always had. Nothing moves in the Keychain,
//  and repeating it changes nothing. Runs at launch and when the Vault opens.
//

import Foundation

@MainActor
public enum SignInSessionSync {
    public static func run() async {
        let store = SignInSessionStore.shared
        let connections = WorkflowConnectionStore.shared
        connections.loadIfNeeded()
        store.syncConnections(connections.connections)

        let mcpIds = MCPProviderManager.shared.configuration.providers.filter { $0.authType == .oauth }.map(\.id)
        let providerIds = RemoteProviderManager.shared.configuration.providers
            .filter { $0.authType != .apiKey }.map(\.id)
        let signedIn = await Task.detached(priority: .utility) {
            (
                mcp: mcpIds.filter { MCPProviderKeychain.oauthTokensAvailability(for: $0) == .present },
                providers: providerIds.filter { RemoteProviderKeychain.oauthTokensAvailability(for: $0) == .present },
                channels: ChannelSessions.signedInKinds(),
                slack: ChannelAccounts.accounts(kind: .slack).filter { !$0.isPrimary }
            )
        }.value
        for id in signedIn.mcp { store.ensurePrimary(for: .mcp(id)) }
        for id in signedIn.providers { store.ensurePrimary(for: .modelProvider(id)) }
        for kind in signedIn.channels { store.ensurePrimary(for: .channel(kind)) }
        syncSlackWorkspaces(signedIn.slack)

        // A removed server or provider takes its sessions with it.
        let liveMCP = Set(MCPProviderManager.shared.configuration.providers.map(\.id))
        let liveProviders = Set(RemoteProviderManager.shared.configuration.providers.map(\.id))
        for session in store.sessions {
            switch session.service {
            case .mcp(let id) where !liveMCP.contains(id): SignInSessionActions.forget(session)
            case .modelProvider(let id) where !liveProviders.contains(id): SignInSessionActions.forget(session)
            default: break
            }
        }
    }

    /// Each extra Slack workspace (its own `slack-<team>` connection) is a
    /// session of Slack, found by its team id.
    static func syncSlackWorkspaces(_ workspaces: [ChannelAccount]) {
        let store = SignInSessionStore.shared
        let existing = store.sessions(for: .channel(.slack)).filter { $0.reference != nil }
        let teams = Set(workspaces.compactMap(\.reference))
        for workspace in workspaces {
            guard let teamId = workspace.reference, !existing.contains(where: { $0.reference == teamId }) else {
                continue
            }
            store.add(service: .channel(.slack), name: workspace.name, reference: teamId)
        }
        for session in existing where !teams.contains(session.reference ?? "") {
            store.remove(session.id)
        }
    }
}
