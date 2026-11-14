//
//  SignInSessionActions.swift
//  osaurus
//
//  What the Vault's Accounts tab does to a session, per backend: read
//  whether it is signed in, sign it out (drop its tokens, keep the record),
//  and remove it.
//

import Foundation

public enum SignInSessionStatus: String, Sendable, Equatable {
    case signedIn
    case expired
    case signedOut
}

@MainActor
public enum SignInSessionActions {
    /// Whether the session can be used now. Reads the Keychain: call it
    /// off the main actor through `statuses(of:)`.
    nonisolated static func status(of session: SignInSession, connection: WorkflowConnection?) -> SignInSessionStatus {
        switch session.service {
        case .connection:
            guard let connection else { return .signedOut }
            switch connection.kind {
            case .value:
                return WorkflowSecretsKeychain.hasValue(
                    account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "value"))
                    ? .signedIn : .signedOut
            case .oauth2:
                guard
                    WorkflowSecretsKeychain.hasValue(
                        account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "access"))
                else { return .signedOut }
                return connection.needsSignIn() ? .expired : .signedIn
            }
        case .mcp(let id):
            guard let tokens = MCPProviderKeychain.getOAuthTokens(for: id, session: session.keychainSession) else {
                return .signedOut
            }
            return tokens.isExpired && (tokens.refreshToken ?? "").isEmpty ? .expired : .signedIn
        case .modelProvider(let id):
            guard let tokens = RemoteProviderKeychain.getOAuthTokens(for: id, session: session.keychainSession) else {
                return .signedOut
            }
            return tokens.isExpired && tokens.refreshToken.isEmpty ? .expired : .signedIn
        case .channel(let kind):
            return ChannelSessions.botToken(kind, session: session) == nil ? .signedOut : .signedIn
        }
    }

    /// The status of each session, read off the main actor.
    public static func statuses(of sessions: [SignInSession]) async -> [UUID: SignInSessionStatus] {
        let connections = Dictionary(
            uniqueKeysWithValues: WorkflowConnectionStore.shared.connections.map { ($0.id, $0) })
        return await Task.detached(priority: .userInitiated) {
            var out: [UUID: SignInSessionStatus] = [:]
            for session in sessions { out[session.id] = status(of: session, connection: connections[session.id]) }
            return out
        }.value
    }

    /// Drops the session's tokens; the session stays so it can sign in again.
    public static func signOut(_ session: SignInSession) {
        switch session.service {
        case .connection:
            for field in ["access", "refresh", "value"] {
                WorkflowSecretsKeychain.delete(
                    account: WorkflowSecretsKeychain.connectionAccount(id: session.id, field: field))
            }
        case .mcp(let id):
            if session.isPrimary { MCPProviderManager.shared.disconnect(providerId: id) }
            MCPProviderKeychain.deleteOAuthTokens(for: id, session: session.keychainSession)
        case .modelProvider(let id):
            RemoteProviderKeychain.deleteOAuthTokens(for: id, session: session.keychainSession)
        case .channel(let kind):
            ChannelSessions.deleteBotToken(kind, session: session)
        }
        NotificationCenter.default.post(name: .signInSessionsDidChange, object: nil)
    }

    /// Signs the session out and removes it. A workflow connection is
    /// deleted with it.
    public static func forget(_ session: SignInSession) {
        switch session.service {
        case .connection:
            WorkflowConnectionStore.shared.delete(id: session.id)
        case .channel(.slack) where session.reference != nil:
            ChannelAccountRemoval.remove(connectionId: ChannelAccounts.connectionId(slackTeamId: session.reference ?? ""))
        case .channel(let kind) where !session.isPrimary && ChannelAccounts.botKinds.contains(kind):
            signOut(session)
            if let connectionId = ChannelAccounts.connectionId(botSession: session) {
                ChannelAccountRemoval.remove(connectionId: connectionId)
            }
        default:
            signOut(session)
        }
        SignInSessionStore.shared.remove(session.id)
    }
}
