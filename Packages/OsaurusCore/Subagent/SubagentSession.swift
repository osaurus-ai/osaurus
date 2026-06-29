//
//  SubagentSession.swift
//  OsaurusCore — Subagent framework
//
//  The shared host every nested sub-agent funnels through. Generalized from
//  computer_use's scaffolding so spawn / image / computer_use
//  share ONE lifecycle:
//
//    recursion guard → scope ids → resolve model (reject-before-evict)
//      → permission → register feed + interrupt → [optional handoff]
//      → run kind → normalize to a compact ToolEnvelope → defer cleanup
//      → telemetry
//
//  The host is driven entirely through `any SubagentKind`, which is also the
//  deterministic test seam: a scripted kind exercises the full control flow
//  model-free (no tokens) in CI.
//

import Foundation
import os

private let subagentLog = Logger(subsystem: "ai.osaurus", category: "Subagent")

/// Lightweight run-outcome telemetry for the sub-agent family. Kept as a log
/// hook so the host stays dependency-free; richer `FeatureTelemetry` rows are
/// emitted by individual kinds where they already exist (computer_use).
enum SubagentTelemetry {
    static func record(kindId: String, success: Bool, elapsed: TimeInterval) {
        subagentLog.info(
            "subagent run kind=\(kindId, privacy: .public) success=\(success, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s"
        )
    }
}

public enum SubagentSession {
    /// Active-kind recursion guard. Set while ANY sub-agent kind runs so a
    /// nested sub-agent call refuses (generalizes the per-tool delegation
    /// guards into one guard for the whole family). Carries the running kind's
    /// id for the message.
    @TaskLocal public static var activeKindId: String?

    /// True when a sub-agent kind is currently running on this task tree.
    public static var isActive: Bool { activeKindId != nil }

    /// Run any sub-agent kind end to end and return a canonical envelope.
    /// `handoff` overrides the kind's own `makeHandoff()` (used by tests).
    public static func run(
        _ kind: any SubagentKind,
        tool: String,
        handoff: SubagentHandoff? = nil
    ) async -> String {
        // 1. One recursion guard for the whole sub-agent family: a running
        //    sub-agent (of any kind) cannot start another.
        if let active = activeKindId {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "\(tool) cannot be called from inside a running sub-agent (\(active)). "
                    + "Finish the current sub-agent and return its result first.",
                tool: tool,
                retryable: false
            )
        }

        let scope = SubagentScope.current()

        // 2. Resolve + validate the model BEFORE any residency eviction.
        let resolved: ResolvedModel
        do {
            resolved = try await kind.resolveModel(scope)
        } catch {
            return envelope(for: error, tool: tool)
        }

        // 3. Permission (policy gate / interactive prompt / rich gate).
        switch await kind.permission(scope, resolved) {
        case .allow:
            break
        case .denied(let reason):
            return ToolEnvelope.failure(kind: .rejected, message: reason, tool: tool, retryable: false)
        case .userDenied(let reason):
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: reason,
                tool: tool,
                retryable: false
            )
        }

        // 4. Live feed + interrupt registered for the chat row + stop button.
        let feed = SubagentFeed(
            toolCallId: scope.toolCallId,
            kindId: kind.capability.id,
            title: kind.feedTitle
        )
        let interrupt = InterruptToken()
        SubagentFeedRegistry.shared.register(feed)
        SubagentInterruptCenter.shared.register(interrupt, for: scope.toolCallId)
        defer {
            SubagentInterruptCenter.shared.unregister(scope.toolCallId)
            SubagentFeedRegistry.shared.unregister(toolCallId: scope.toolCallId)
        }

        let effectiveHandoff = handoff ?? kind.makeHandoff()
        let started = Date()

        // 5. Run under the recursion guard, wrapped by the optional handoff.
        do {
            let result = try await SubagentSession.$activeKindId.withValue(kind.capability.id) {
                try await effectiveHandoff.around(
                    scope: scope,
                    resolved: resolved,
                    feed: feed
                ) {
                    try await kind.run(scope, resolved, feed: feed, interrupt: interrupt)
                }
            }
            feed.finish(success: true, summary: result.summary ?? "")
            SubagentTelemetry.record(
                kindId: kind.capability.id,
                success: true,
                elapsed: Date().timeIntervalSince(started)
            )
            return ToolEnvelope.success(tool: tool, result: result.payload)
        } catch {
            let env = envelope(for: error, tool: tool)
            feed.finish(success: false, summary: ToolEnvelope.failureMessage(env))
            SubagentTelemetry.record(
                kindId: kind.capability.id,
                success: false,
                elapsed: Date().timeIntervalSince(started)
            )
            return env
        }
    }

    /// Map a thrown error to the canonical failure envelope. `SubagentError`
    /// carries its own kind/retryable; anything else falls back to
    /// `ToolEnvelope.fromError`.
    static func envelope(for error: Error, tool: String) -> String {
        if let se = error as? SubagentError { return se.envelope(tool: tool) }
        return ToolEnvelope.fromError(error, tool: tool)
    }
}
