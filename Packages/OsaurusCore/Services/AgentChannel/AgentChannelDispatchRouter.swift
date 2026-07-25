//
//  AgentChannelDispatchRouter.swift
//  osaurus
//
//  Provider-neutral resolution of which agent answers an inbound channel
//  message. Order: (1) a leading name alias in the message picks its route,
//  (2) a route mapped to the message's room, (3) the provider-wide default
//  agent. Alias matches also strip the alias prefix so the agent sees the
//  question, not the routing token.
//

import Foundation

struct AgentChannelDispatchResolution: Equatable, Sendable {
    let agentId: UUID
    /// Machine label of the matched rule for telemetry:
    /// "alias:<alias>", "room:<roomId>", or "default".
    let matchedRule: String
    /// Message content with a matched alias prefix removed; equals the
    /// input content for room/default matches.
    let content: String
}

enum AgentChannelDispatchRouter {
    /// Characters that may separate a leading alias from the message body.
    private static let aliasDelimiters = CharacterSet(charactersIn: ":,;-–—").union(.whitespacesAndNewlines)

    static func resolve(
        settings: AgentChannelInboundDispatchConfiguration,
        roomId: String,
        content: String
    ) -> AgentChannelDispatchResolution? {
        guard settings.enabled else { return nil }
        let room = roomId.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Alias override. Routes scoped to this room win over global
        //    (roomId == nil) alias routes; longer aliases win over shorter
        //    so "sales-eu" is not shadowed by "sales".
        let aliasCandidates = settings.routes
            .filter { $0.roomId == nil || $0.roomId == room }
            .sorted { ($0.roomId != nil ? 0 : 1) < ($1.roomId != nil ? 0 : 1) }
        var bestAlias: (route: AgentChannelDispatchRoute, alias: String, remainder: String)?
        for route in aliasCandidates {
            for alias in route.nameAliases {
                guard let remainder = stripLeadingAlias(alias, from: content) else { continue }
                if let current = bestAlias {
                    let currentScoped = current.route.roomId != nil
                    let candidateScoped = route.roomId != nil
                    let better =
                        (candidateScoped && !currentScoped)
                        || (candidateScoped == currentScoped && alias.count > current.alias.count)
                    if !better { continue }
                }
                bestAlias = (route, alias, remainder)
            }
        }
        if let bestAlias {
            return AgentChannelDispatchResolution(
                agentId: bestAlias.route.agentId,
                matchedRule: "alias:\(bestAlias.alias)",
                content: bestAlias.remainder
            )
        }

        // 2. Room mapping. Among routes bound to this room, prefer a route
        //    without aliases (the room default); alias-only routes for the
        //    room require their alias and do not claim every message.
        let roomRoutes = settings.routes.filter { $0.roomId == room }
        if let roomDefault = roomRoutes.first(where: { $0.nameAliases.isEmpty }) {
            return AgentChannelDispatchResolution(
                agentId: roomDefault.agentId,
                matchedRule: "room:\(room)",
                content: content
            )
        }

        // 3. Provider-wide default.
        if let fallback = settings.targetAgentId {
            return AgentChannelDispatchResolution(
                agentId: fallback,
                matchedRule: "default",
                content: content
            )
        }
        return nil
    }

    /// Returns the message body with the leading alias and its delimiter
    /// removed when `content` starts with `alias` (case-insensitive)
    /// followed by a delimiter or end of message; nil otherwise.
    static func stripLeadingAlias(_ alias: String, from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, trimmed.count >= alias.count else { return nil }
        // Allow an "@" prefix before the alias ("@sales: hi").
        let working = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        guard working.lowercased().hasPrefix(alias.lowercased()) else { return nil }
        let afterAlias = working.dropFirst(alias.count)
        if afterAlias.isEmpty {
            return ""
        }
        guard let first = afterAlias.unicodeScalars.first,
              aliasDelimiters.contains(first)
        else { return nil }
        return String(afterAlias.drop(while: { char in
            char.unicodeScalars.allSatisfy { aliasDelimiters.contains($0) }
        }))
    }
}
