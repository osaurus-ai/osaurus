//
//  GenerativeGreeting.swift
//  osaurus
//
//  Result of a `GenerativeGreetingService.generate(...)` call: a freshly
//  produced greeting line, subtitle, and four `AgentQuickAction` shortcuts
//  for the empty chat state. Cached per chat session by `ChatSession`.
//

import Foundation

/// A single, fully-validated set of greeting copy + quick actions to render
/// in `ChatEmptyState` instead of the static defaults. All strings are
/// already trimmed and bounded by the time this struct is constructed,
/// and every `AgentQuickAction.icon` has been validated against the
/// allowlist in `GenerativeGreetingService`.
public struct GenerativeGreeting: Codable, Equatable, Sendable {
    /// Short delight greeting line. Replaces the time-of-day computed greeting.
    public var greeting: String
    /// Inviting one-liner shown beneath the greeting. Replaces the static
    /// "How can I help you today?" subtitle.
    public var subtitle: String
    /// Exactly four bespoke quick actions. Always non-empty after validation.
    public var actions: [AgentQuickAction]

    public init(greeting: String, subtitle: String, actions: [AgentQuickAction]) {
        self.greeting = greeting
        self.subtitle = subtitle
        self.actions = actions
    }
}
