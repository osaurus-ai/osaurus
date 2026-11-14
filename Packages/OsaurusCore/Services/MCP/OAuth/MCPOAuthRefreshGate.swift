//
//  MCPOAuthRefreshGate.swift
//  OsaurusCore
//
//  Per-provider, per-session single-flight around OAuth refresh. Prevents
//  concurrent refresh_token rotations (Notion-style) from invalidating each
//  other. Each sign-in session has its own refresh token, so sessions
//  refresh independently.
//

import Foundation

actor MCPOAuthRefreshGate {
    static let shared = MCPOAuthRefreshGate()

    private struct Key: Hashable {
        let provider: UUID
        let session: UUID?
    }

    private var inflight: [Key: Task<MCPOAuthTokens, Error>] = [:]

    /// `session` is the Keychain session (`SignInSession.keychainSession`):
    /// nil for the primary sign-in.
    func refresh(
        provider: MCPProvider,
        tokens: MCPOAuthTokens,
        persist: Bool,
        session: UUID? = nil
    ) async throws -> MCPOAuthTokens {
        let key = Key(provider: provider.id, session: session)
        if let existing = inflight[key] {
            return try await existing.value
        }

        let task = Task {
            try await MCPOAuthService.performRefresh(
                provider: provider, tokens: tokens, persist: persist, session: session)
        }
        inflight[key] = task
        defer { inflight.removeValue(forKey: key) }
        return try await task.value
    }
}
