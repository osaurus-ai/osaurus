//
//  SubagentSession.swift
//  OsaurusCore — Subagent framework
//
//  The shared host every nested subagent funnels through. Generalized from
//  computer_use's scaffolding so spawn / image / computer_use
//  share ONE lifecycle:
//
//    recursion guard → scope ids → resolve model (reject-before-evict)
//      → permission → register feed + interrupt → process-wide admission
//      (local runs serialize, remote fan out) → [optional handoff]
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

/// Lightweight run-outcome telemetry for the subagent family. Kept as a log
/// hook so the host stays dependency-free; richer `FeatureTelemetry` rows are
/// emitted by individual kinds where they already exist (computer_use).
enum SubagentTelemetry {
    static func record(
        kindId: String,
        success: Bool,
        elapsed: TimeInterval,
        usage: [String: Any]? = nil,
        phases: [(phase: String, seconds: Double)] = []
    ) {
        var extra = ""
        if let usage {
            let prompt = usage["prompt_tokens"] as? Int ?? 0
            let completion = usage["completion_tokens"] as? Int ?? 0
            extra += " promptTokens=\(prompt) completionTokens=\(completion)"
            if let tps = usage["tokens_per_second"] as? Double {
                extra += String(format: " tokPerSec=%.1f", tps)
            }
        }
        if !phases.isEmpty {
            let joined = phases.map { String(format: "%@=%.2fs", $0.phase, $0.seconds) }
                .joined(separator: " ")
            extra += " phases[\(joined)]"
        }
        subagentLog.info(
            "subagent run kind=\(kindId, privacy: .public) success=\(success, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s\(extra, privacy: .public)"
        )
    }
}

public enum SubagentSession {
    /// Active-kind recursion guard. Set while ANY subagent kind runs so a
    /// nested subagent call refuses (generalizes the per-tool delegation
    /// guards into one guard for the whole family). Carries the running kind's
    /// id for the message.
    @TaskLocal public static var activeKindId: String?

    /// True when a subagent kind is currently running on this task tree.
    public static var isActive: Bool { activeKindId != nil }

    /// Run any subagent kind end to end and return a canonical envelope.
    /// `handoff` overrides the kind's own `makeHandoff()` (used by tests).
    public static func run(
        _ kind: any SubagentKind,
        tool: String,
        handoff: SubagentHandoff? = nil
    ) async -> String {
        // 1. One recursion guard for the whole subagent family: a running
        //    subagent (of any kind) cannot start another.
        if let active = activeKindId {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "\(tool) cannot be called from inside a running subagent (\(active)). "
                    + "Finish the current subagent and return its result first.",
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

        // 5. Process-wide admission: the TaskLocal guard above only covers one
        //    task tree; a parallel tool batch can reach here CONCURRENTLY.
        //    Local runs serialize (a queued run waits — visible in the feed);
        //    remote runs fan out. This is what makes two spawns in one batch
        //    safe instead of a concurrent-GPU handoff race.
        let admissionClass = kind.admissionClass(resolved)
        let admission = await SubagentAdmission.shared.admit(
            admissionClass,
            onWait: { [feed] active in
                feed.emitPhase("waiting for local GPU", detail: active)
            }
        )
        switch admission {
        case .admitted:
            break
        case .timedOut(let active):
            let message =
                "\(tool) is waiting on \(active) that did not finish in time. "
                + "Retry when the running subagent completes."
            feed.finish(success: false, summary: message)
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: message,
                tool: tool,
                retryable: true
            )
        case .cancelled:
            let message = "Run cancelled while waiting for another subagent to finish."
            feed.finish(success: false, summary: message)
            return ToolEnvelope.failure(
                kind: .executionError,
                message: message,
                tool: tool,
                retryable: false
            )
        }

        let effectiveHandoff = handoff ?? kind.makeHandoff()
        let started = Date()

        // 6. Run under the recursion guard, wrapped by the optional handoff.
        //    The admission slot is held for the WHOLE wrapped run (handoff
        //    included) and released on every exit path below.
        do {
            // Post-run cache counters must be captured INSIDE the handoff wrap
            // (after the kind's run, BEFORE the restore leg): restoring the
            // orchestrator can evict the subagent model under a single-model
            // policy, shutting down its engine and losing the counters.
            let cacheCapture = PostRunCacheCapture()
            let result = try await SubagentSession.$activeKindId.withValue(kind.capability.id) {
                try await effectiveHandoff.around(
                    scope: scope,
                    resolved: resolved,
                    feed: feed
                ) {
                    let r = try await kind.run(scope, resolved, feed: feed, interrupt: interrupt)
                    if resolved.isLocal {
                        cacheCapture.value = await ModelRuntime.batchDiagnosticsSnapshot()
                    }
                    return r
                }
            }
            await SubagentAdmission.shared.release(admissionClass)

            // Residency telemetry: phase durations derived from the feed's own
            // event timeline (the handoff emits its phases there), plus the
            // post-run cache counters for local runs (prefix/L2 state at run
            // end — the resume prefix-hit / L2 disk-cache mitigation signal).
            var payload = result.payload
            var residency: [String: Any] = [:]
            let phases = Self.residencyPhaseTimings(
                events: feed.currentEvents(),
                endedAt: Date()
            )
            if !phases.isEmpty {
                residency["phases"] = Dictionary(
                    uniqueKeysWithValues: phases.map { ($0.phase, ($0.seconds * 100).rounded() / 100) }
                )
                residency["phase_order"] = phases.map(\.phase)
                let summary = phases.map { String(format: "%@ %.1fs", $0.phase, $0.seconds) }
                    .joined(separator: " · ")
                feed.emit(
                    SubagentActivityEvent(kind: .narrate, title: "handoff timings", detail: summary)
                )
            }
            if let snapshot = cacheCapture.value {
                residency["post_run_cache"] = [
                    "prefix_hits": snapshot.prefixHits,
                    "prefix_misses": snapshot.prefixMisses,
                    "disk_l2_hits": snapshot.diskL2Hits,
                    "disk_l2_misses": snapshot.diskL2Misses,
                    "disk_l2_stores": snapshot.diskL2Stores,
                ]
            }
            if !residency.isEmpty {
                payload["residency"] = residency
            }

            feed.finish(success: true, summary: result.summary ?? "")
            SubagentTelemetry.record(
                kindId: kind.capability.id,
                success: true,
                elapsed: Date().timeIntervalSince(started),
                usage: payload["usage"] as? [String: Any],
                phases: phases
            )
            return ToolEnvelope.success(tool: tool, result: payload)
        } catch {
            await SubagentAdmission.shared.release(admissionClass)
            let env = envelope(for: error, tool: tool)
            feed.finish(success: false, summary: ToolEnvelope.failureMessage(env))
            SubagentTelemetry.record(
                kindId: kind.capability.id,
                success: false,
                elapsed: Date().timeIntervalSince(started),
                phases: Self.residencyPhaseTimings(
                    events: feed.currentEvents(),
                    endedAt: Date()
                )
            )
            return env
        }
    }

    /// Residency-relevant phase titles whose durations are worth reporting:
    /// the admission queue wait, the single-residency handoff legs, and the
    /// coexistence idle drain. `running`/`generating` and kind-specific
    /// phases are excluded — the payload already carries `elapsed_seconds`.
    static let timedPhaseTitles: Set<String> = [
        "waiting for local GPU",
        "waiting_for_chat_idle",
        "unloading_chat_models",
        "restoring_chat_models",
        "restoring_chat_models_retry",
        "coexisting",
    ]

    /// Derive phase durations from a feed's event timeline: a timed phase
    /// lasts until the NEXT event of any kind (or `endedAt` for the last
    /// event). Pure — unit-testable with synthetic events.
    static func residencyPhaseTimings(
        events: [SubagentActivityEvent],
        endedAt: Date
    ) -> [(phase: String, seconds: Double)] {
        var timings: [(phase: String, seconds: Double)] = []
        for (index, event) in events.enumerated() {
            guard event.kind == .phase, timedPhaseTitles.contains(event.title) else { continue }
            let end = index + 1 < events.count ? events[index + 1].timestamp : endedAt
            let seconds = max(0, end.timeIntervalSince(event.timestamp))
            timings.append((phase: event.title, seconds: seconds))
        }
        return timings
    }

    /// Map a thrown error to the canonical failure envelope. `SubagentError`
    /// carries its own kind/retryable; anything else falls back to
    /// `ToolEnvelope.fromError`.
    static func envelope(for error: Error, tool: String) -> String {
        if let se = error as? SubagentError { return se.envelope(tool: tool) }
        return ToolEnvelope.fromError(error, tool: tool)
    }
}

/// Reference box carrying the run-end cache snapshot out of the handoff
/// closure (written once inside the wrap, read after it returns — a
/// happens-before ordering, so a plain box is sufficient).
private final class PostRunCacheCapture: @unchecked Sendable {
    var value: BatchDiagnosticsSnapshot?
}
