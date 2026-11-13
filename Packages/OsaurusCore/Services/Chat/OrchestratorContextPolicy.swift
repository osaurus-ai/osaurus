//
//  OrchestratorContextPolicy.swift
//  osaurus
//
//  The Orchestrator's context is bounded: the system prompt, the session
//  state (on the latest user message only), the last three exchanges, and the
//  current exchange with its results. The ceiling is 8k tokens or 25% of the
//  model window, whichever is smaller. Older exchanges are dropped, never
//  summarized; anything that must survive lives in the session state.
//

import Foundation

enum OrchestratorContextPolicy {
    /// Completed exchanges kept before the current one.
    static let keptExchanges = 3
    static let maxTokens = 8000
    static let windowFraction = 0.25

    static func ceiling(contextWindow: Int) -> Int {
        min(maxTokens, Int(Double(max(contextWindow, 0)) * windowFraction))
    }

    /// `messages` cut to the policy: leading system messages, then at most
    /// `keptExchanges` earlier exchanges (an exchange runs from one user
    /// message to the next, so tool calls stay paired with their results),
    /// then the current exchange. Earlier exchanges drop oldest-first until
    /// the whole array fits the ceiling; the current exchange always stays.
    static func apply(_ messages: [ChatMessage], contextWindow: Int) -> [ChatMessage] {
        let systemCount = messages.prefix { $0.role == "system" }.count
        let system = Array(messages.prefix(systemCount))
        let rest = Array(messages.dropFirst(systemCount))
        let userStarts = rest.indices.filter { rest[$0].role == "user" }
        guard let currentStart = userStarts.last else { return messages }

        var exchanges: [[ChatMessage]] = []
        let earlierStarts = userStarts.dropLast().suffix(keptExchanges)
        for (offset, start) in earlierStarts.enumerated() {
            let nextStart = offset + 1 < earlierStarts.count
                ? earlierStarts[earlierStarts.index(earlierStarts.startIndex, offsetBy: offset + 1)]
                : currentStart
            exchanges.append(Array(rest[start..<nextStart]))
        }
        let current = Array(rest[currentStart...])

        let limit = ceiling(contextWindow: contextWindow)
        func assembled() -> [ChatMessage] { system + exchanges.flatMap { $0 } + current }
        var result = assembled()
        while !exchanges.isEmpty, ContextBudgetManager.estimateTokens(for: result) > limit {
            exchanges.removeFirst()
            result = assembled()
        }
        return result
    }
}
