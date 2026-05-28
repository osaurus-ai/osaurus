//
//  BuiltInAgentGuard.swift
//  osaurus
//
//  Shared helper that all external entry points (HTTP, background dispatch,
//  plugin bridge, scheduler, watcher) call before resolving an agent id.
//  The Default agent is reachable only from the in-app SwiftUI Chat UI;
//  every other surface returns a structured rejection.
//
//  Treating `nil` as a rejection is intentional: historical paths used
//  `agentId ?? Agent.defaultId` and silently routed anonymous traffic to
//  the default agent. The guard preserves that no-implicit-fallback rule.
//

import Foundation

/// Structured error emitted whenever an external surface attempts to
/// reach a built-in agent (currently just the Default agent). Callers
/// translate this to the appropriate transport-level response (HTTP 403,
/// background-task failure, tool envelope, log + skip).
public enum BuiltInAgentGuardError: Error, Equatable, Sendable {
    /// `agentId` is the offending value (or `Agent.defaultId` when `nil`
    /// was passed — implicit "no agent" defaulted to the built-in agent
    /// historically and is now treated as a rejection).
    case builtInAgentNotExposable(agentId: UUID, source: String)

    /// Stable error code suitable for transport payloads.
    public var code: String { "built_in_agent_not_exposable" }

    /// Human-readable message; safe to surface to API consumers.
    public var message: String {
        switch self {
        case .builtInAgentNotExposable(let agentId, let source):
            return "Built-in agent \(agentId.uuidString) is not reachable from \(source). "
                + "Built-in agents (including the Default agent) are only available inside the Osaurus app."
        }
    }
}

extension Agent {
    /// Return a `BuiltInAgentGuardError` when the caller-supplied agent id is
    /// `nil` or refers to a built-in agent that must not be reachable from
    /// `source`. Returns `nil` for every custom (user-created) agent id.
    ///
    /// `source` is a short, stable identifier of the surface ("http/agents/run",
    /// "background/dispatchChat", "plugin/planDispatch", "schedule/next-run",
    /// etc.) so logs and rejection payloads can pinpoint the offending site.
    public static func rejectBuiltInForExternalSurface(
        _ agentId: UUID?,
        source: String
    ) -> BuiltInAgentGuardError? {
        guard let agentId else {
            return .builtInAgentNotExposable(agentId: defaultId, source: source)
        }
        if agentId == defaultId {
            return .builtInAgentNotExposable(agentId: agentId, source: source)
        }
        return nil
    }
}
