//
//  MCPOAuthRefreshGate.swift
//  OsaurusCore
//
//  Per-provider single-flight around OAuth refresh. Prevents concurrent
//  refresh_token rotations (Notion-style) from invalidating each other.
//

import Foundation

actor MCPOAuthRefreshGate {
    static let shared = MCPOAuthRefreshGate()

    private var inflight: [UUID: Task<MCPOAuthTokens, Error>] = [:]

    func refresh(
        provider: MCPProvider,
        tokens: MCPOAuthTokens,
        persist: Bool
    ) async throws -> MCPOAuthTokens {
        if let existing = inflight[provider.id] {
            return try await existing.value
        }

        let task = Task {
            try await MCPOAuthService.performRefresh(provider: provider, tokens: tokens, persist: persist)
        }
        inflight[provider.id] = task
        defer { inflight.removeValue(forKey: provider.id) }
        return try await task.value
    }
}
