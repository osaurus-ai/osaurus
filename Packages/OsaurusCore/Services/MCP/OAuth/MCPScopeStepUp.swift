//
//  MCPScopeStepUp.swift
//  osaurus
//
//  Scope bookkeeping for MCP `insufficient_scope` step-up authorization
//  (MCP 2025-11-25 authorization §Scope Challenge Handling).
//

import Foundation

enum MCPScopeStepUp {
    static func split(_ scope: String) -> [String] {
        scope.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Union of the scopes already granted and the scopes the server asked
    /// for, in first-seen order. Keeping the granted set avoids a step-up
    /// that silently drops access the user already approved.
    static func merged(current: [String], required: [String]) -> [String] {
        var seen = Set<String>()
        return (current + required).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static let providerMessage =
        "A tool call was refused for missing permissions. Sign in again to grant access."

    static func toolMessage(providerName: String) -> String {
        "\(providerName) refused this tool call (HTTP 403). The connection may need additional "
            + "permissions: ask the user to sign in to \(providerName) again from Tools & MCP → Services."
    }
}
