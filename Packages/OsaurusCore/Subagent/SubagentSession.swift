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

/// A subagent run after target resolution and permission, but before admission,
/// handoff, or model execution. Batched spawn uses this split to validate every
/// target before the first local model can unload/load, then groups prepared
/// jobs by canonical model identity.
struct PreparedSubagentRun: Sendable {
    let kind: any SubagentKind
    let tool: String
    let scope: SubagentScope
    let resolved: ResolvedModel
    let handoff: any SubagentHandoff
    /// True when `handoff` came from `kind.makeHandoff()`. Direct text spawns
    /// refresh that kind-owned value after a queued admission; explicit test
    /// and caller overrides remain authoritative.
    let handoffIsKindOwned: Bool

    init(
        kind: any SubagentKind,
        tool: String,
        scope: SubagentScope,
        resolved: ResolvedModel,
        handoff: any SubagentHandoff,
        handoffIsKindOwned: Bool = false
    ) {
        self.kind = kind
        self.tool = tool
        self.scope = scope
        self.resolved = resolved
        self.handoff = handoff
        self.handoffIsKindOwned = handoffIsKindOwned
    }

    var admissionClass: SubagentAdmissionClass {
        kind.admissionClass(resolved)
    }

    var admissionModelKey: String? {
        SubagentSession.canonicalAdmissionModelKey(resolved)
    }

    var textResidencyPlan: ResidencyPlan? {
        (kind as? TextSubagentKind)?.preparedResidencyPlan
    }
}

enum SubagentPreparationResult: Sendable {
    case ready(PreparedSubagentRun)
    /// Already-normalized ToolEnvelope JSON.
    case failure(String)
}

/// Presentation/interrupt plumbing for one prepared run. Normal single-worker
/// calls let the host create and register these values. `spawn_batch` supplies
/// an unregistered child feed and the batch's shared interrupt token so one
/// visible parent row owns Stop while sibling runs remain isolated.
struct SubagentRunPresentation: Sendable {
    let feed: SubagentFeed
    let interrupt: InterruptToken
    let registerWithUI: Bool
    let finishFeed: Bool

    init(
        feed: SubagentFeed,
        interrupt: InterruptToken,
        registerWithUI: Bool,
        finishFeed: Bool = true
    ) {
        self.feed = feed
        self.interrupt = interrupt
        self.registerWithUI = registerWithUI
        self.finishFeed = finishFeed
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
        switch await prepare(kind, tool: tool, handoff: handoff) {
        case .failure(let envelope):
            return envelope
        case .ready(let prepared):
            return await runPrepared(prepared)
        }
    }

    /// Spawn compatibility tools need their feed + Stop token visible while
    /// target resolution and an `.ask` permission panel are still in flight.
    /// The ordinary host historically registered those only after preparation,
    /// which meant a direct spawn panel had no run-owned Stop path.
    ///
    /// This is deliberately opt-in (spawn_agent / spawn_model only) so kinds
    /// whose existing presentation contract starts after preparation do not
    /// change behavior.
    static func runWithVisiblePreparation(
        _ kind: any SubagentKind,
        tool: String
    ) async -> String {
        let scope = SubagentScope.current()
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

        feed.emitPhase("validating target")
        switch await prepare(
            kind,
            tool: tool,
            scope: scope,
            interrupt: interrupt
        ) {
        case .failure(let envelope):
            feed.finish(
                success: false,
                summary: ToolEnvelope.failureMessage(envelope)
            )
            return envelope
        case .ready(let prepared):
            return await runPrepared(
                prepared,
                presentation: SubagentRunPresentation(
                    feed: feed,
                    interrupt: interrupt,
                    registerWithUI: false
                )
            )
        }
    }

    /// Resolve and authorize a kind without admitting it or changing model
    /// residency. This is the reject-before-load boundary used by both the
    /// compatibility tools and `spawn_batch`.
    static func prepare(
        _ kind: any SubagentKind,
        tool: String,
        handoff: (any SubagentHandoff)? = nil,
        scope explicitScope: SubagentScope? = nil,
        interrupt: InterruptToken? = nil
    ) async -> SubagentPreparationResult {
        func cancellationEnvelope(_ message: String) -> String {
            let userInterrupted = interrupt?.isInterrupted == true
            return ToolEnvelope.failure(
                kind: userInterrupted ? .userDenied : .executionError,
                message:
                    userInterrupted
                    ? "Run was stopped by the user. \(message)"
                    : message,
                tool: tool,
                retryable: false,
                metadata: ["cancelled": true]
            )
        }
        if interrupt?.isInterrupted == true || Task.isCancelled {
            return .failure(
                cancellationEnvelope(
                    "Target preparation did not complete."
                )
            )
        }

        // One recursion guard for the whole subagent family: a running
        // subagent (of any kind) cannot start another.
        if let active = activeKindId {
            return .failure(ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "\(tool) cannot be called from inside a running subagent (\(active)). "
                    + "Finish the current subagent and return its result first.",
                tool: tool,
                retryable: false
            ))
        }

        let scope = explicitScope ?? SubagentScope.current()

        // Resolve + validate the model BEFORE any residency eviction.
        let resolved: ResolvedModel
        let resolution = OwnedSubagentOperation {
            try await kind.resolveModel(scope)
        }
        do {
            resolved = try await resolution.value(
                cancellationRequested: { interrupt?.isInterrupted == true }
            )
        } catch is CancellationError {
            return .failure(
                cancellationEnvelope(
                    "Target resolution did not complete."
                )
            )
        } catch {
            return .failure(envelope(for: error, tool: tool))
        }
        if interrupt?.isInterrupted == true || Task.isCancelled {
            return .failure(
                cancellationEnvelope(
                    "Target resolution did not complete."
                )
            )
        }

        // Permission (policy gate / interactive prompt / rich gate). Own and
        // drain the operation exactly like target resolution so a visible Stop
        // during an AppKit prompt cancels/dismisses it instead of leaving an
        // unowned continuation behind.
        let permissionOperation = OwnedSubagentOperation {
            await kind.permission(scope, resolved)
        }
        let decision: SubagentDecision
        do {
            decision = try await permissionOperation.value(
                cancellationRequested: { interrupt?.isInterrupted == true }
            )
        } catch {
            return .failure(
                cancellationEnvelope(
                    "Target authorization did not complete."
                )
            )
        }
        switch decision {
        case .allow:
            break
        case .denied(let reason):
            return .failure(
                ToolEnvelope.failure(
                    kind: .rejected,
                    message: reason,
                    tool: tool,
                    retryable: false
                )
            )
        case .userDenied(let reason):
            return .failure(ToolEnvelope.failure(
                kind: .userDenied,
                message: reason,
                tool: tool,
                retryable: false
            ))
        }
        if interrupt?.isInterrupted == true || Task.isCancelled {
            return .failure(
                cancellationEnvelope(
                    "Target authorization did not complete."
                )
            )
        }

        // An interactive permission panel is an asynchronous authority
        // boundary. Kinds backed by mutable allow-lists/settings can re-read
        // those values here, still before admission or model residency changes.
        let revalidation = OwnedSubagentOperation {
            try await kind.revalidateAfterPermission(
                scope,
                approved: resolved
            )
        }
        let revalidated: ResolvedModel
        do {
            revalidated = try await revalidation.value(
                cancellationRequested: { interrupt?.isInterrupted == true }
            )
        } catch is CancellationError {
            return .failure(
                cancellationEnvelope(
                    "Post-authorization validation did not complete."
                )
            )
        } catch {
            return .failure(envelope(for: error, tool: tool))
        }
        if interrupt?.isInterrupted == true || Task.isCancelled {
            return .failure(
                cancellationEnvelope(
                    "Post-authorization validation did not complete."
                )
            )
        }

        return .ready(
            PreparedSubagentRun(
                kind: kind,
                tool: tool,
                scope: scope,
                resolved: revalidated,
                handoff: handoff ?? kind.makeHandoff(),
                handoffIsKindOwned: handoff == nil
            )
        )
    }

    /// Execute a previously resolved/authorized run. Batch scheduling can
    /// suppress per-child UI registration, share one interrupt token, skip a
    /// group-owned admission slot, and replace per-child residency handoff with
    /// passthrough after the group wrapper has performed it once.
    static func runPrepared(
        _ prepared: PreparedSubagentRun,
        presentation suppliedPresentation: SubagentRunPresentation? = nil,
        skipAdmission: Bool = false,
        handoffOverride: (any SubagentHandoff)? = nil,
        captureProcessCacheSnapshot: Bool = true,
        admissionController: SubagentAdmission = .shared,
        postAdmissionLocalCapacityOverride:
            (@Sendable (PreparedSubagentRun, ResidencyPlan) async -> Int)? = nil
    ) async -> String {
        if let active = activeKindId {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "\(prepared.tool) cannot be called from inside a running subagent (\(active)). "
                    + "Finish the current subagent and return its result first.",
                tool: prepared.tool,
                retryable: false
            )
        }

        let presentation =
            suppliedPresentation
            ?? SubagentRunPresentation(
                feed: SubagentFeed(
                    toolCallId: prepared.scope.toolCallId,
                    kindId: prepared.kind.capability.id,
                    title: prepared.kind.feedTitle
                ),
                interrupt: InterruptToken(),
                registerWithUI: true
            )
        let feed = presentation.feed
        let interrupt = presentation.interrupt

        if presentation.registerWithUI {
            SubagentFeedRegistry.shared.register(feed)
            SubagentInterruptCenter.shared.register(interrupt, for: prepared.scope.toolCallId)
        }
        defer {
            if presentation.registerWithUI {
                SubagentInterruptCenter.shared.unregister(prepared.scope.toolCallId)
                SubagentFeedRegistry.shared.unregister(toolCallId: prepared.scope.toolCallId)
            }
        }

        // Close the prepare→admission race for kinds whose run authority is
        // mutable. This is deliberately before any admission slot, unload, or
        // model load; unrelated kinds use the protocol's no-op default.
        do {
            try await prepared.kind.validateExecutionAuthority(
                prepared.scope,
                resolved: prepared.resolved
            )
        } catch {
            let envelope = envelope(for: error, tool: prepared.tool)
            if presentation.finishFeed {
                feed.finish(
                    success: false,
                    summary: ToolEnvelope.failureMessage(envelope)
                )
            }
            return envelope
        }
        if interrupt.isInterrupted || Task.isCancelled {
            let envelope = ToolEnvelope.failure(
                kind: interrupt.isInterrupted ? .userDenied : .executionError,
                message: interrupt.isInterrupted
                    ? "Run was stopped by the user before execution began."
                    : "Run was cancelled before execution began.",
                tool: prepared.tool,
                retryable: false,
                metadata: ["cancelled": true]
            )
            if presentation.finishFeed {
                feed.finish(
                    success: false,
                    summary: ToolEnvelope.failureMessage(envelope)
                )
            }
            return envelope
        }

        var admissionClass = prepared.admissionClass
        let admissionModelKey = prepared.admissionModelKey
        var admissionHeld = false
        var admissionHeldSlots = 0
        if !skipAdmission {
            // Process-wide admission: the TaskLocal guard above only covers one
            // task tree; parallel tool calls can reach here concurrently.
            if admissionClass == .localInPlace {
                let capacity = await localInPlaceSlotCapacity(for: prepared)
                let reservation = await admissionController.reserveLocalInPlace(
                    modelKey: admissionModelKey,
                    requestedSlots: 1,
                    slotCapacity: capacity,
                    onWait: { [feed] active in
                        feed.emitPhase("waiting for local GPU", detail: active)
                    },
                    cancellationRequested: { interrupt.isInterrupted }
                )
                switch reservation {
                case .admitted(let slots):
                    admissionHeld = true
                    admissionHeldSlots = slots
                case .timedOut(let active):
                    let message =
                        "\(prepared.tool) is waiting on \(active) that did not finish in time. "
                        + "Retry when the running subagent completes."
                    if presentation.finishFeed {
                        feed.finish(success: false, summary: message)
                    }
                    return ToolEnvelope.failure(
                        kind: .unavailable,
                        message: message,
                        tool: prepared.tool,
                        retryable: true
                    )
                case .cancelled:
                    let message =
                        "Run stopped by the user while waiting for another subagent to finish."
                    if presentation.finishFeed {
                        feed.finish(success: false, summary: message)
                    }
                    return ToolEnvelope.failure(
                        kind: .userDenied,
                        message: message,
                        tool: prepared.tool,
                        retryable: false
                    )
                }
            } else {
                let admission = await admissionController.admit(
                    admissionClass,
                    modelKey: admissionModelKey,
                    onWait: { [feed] active in
                        feed.emitPhase("waiting for local GPU", detail: active)
                    },
                    cancellationRequested: { interrupt.isInterrupted }
                )
                switch admission {
                case .admitted:
                    admissionHeld = true
                case .timedOut(let active):
                    let message =
                        "\(prepared.tool) is waiting on \(active) that did not finish in time. "
                        + "Retry when the running subagent completes."
                    if presentation.finishFeed {
                        feed.finish(success: false, summary: message)
                    }
                    return ToolEnvelope.failure(
                        kind: .unavailable,
                        message: message,
                        tool: prepared.tool,
                        retryable: true
                    )
                case .cancelled:
                    let message =
                        "Run stopped by the user while waiting for another subagent to finish."
                    if presentation.finishFeed {
                        feed.finish(success: false, summary: message)
                    }
                    return ToolEnvelope.failure(
                        kind: .userDenied,
                        message: message,
                        tool: prepared.tool,
                        retryable: false
                    )
                }
            }
        }

        // Admission can wait for minutes. Revalidate once more after the slot
        // is held and immediately before any handoff/model side effect so a
        // launcher disablement, target edit, permission revocation, or pool
        // change during that wait cannot execute stale prepared authority.
        do {
            try await prepared.kind.validateExecutionAuthority(
                prepared.scope,
                resolved: prepared.resolved
            )
        } catch {
            if admissionHeld {
                if admissionHeldSlots > 0 {
                    await admissionController.releaseLocalInPlace(
                        modelKey: admissionModelKey,
                        slots: admissionHeldSlots
                    )
                } else {
                    await admissionController.release(
                        admissionClass,
                        modelKey: admissionModelKey
                    )
                }
            }
            let envelope = envelope(for: error, tool: prepared.tool)
            if presentation.finishFeed {
                feed.finish(
                    success: false,
                    summary: ToolEnvelope.failureMessage(envelope)
                )
            }
            return envelope
        }
        if interrupt.isInterrupted || Task.isCancelled {
            if admissionHeld {
                if admissionHeldSlots > 0 {
                    await admissionController.releaseLocalInPlace(
                        modelKey: admissionModelKey,
                        slots: admissionHeldSlots
                    )
                } else {
                    await admissionController.release(
                        admissionClass,
                        modelKey: admissionModelKey
                    )
                }
            }
            let envelope = ToolEnvelope.failure(
                kind: interrupt.isInterrupted ? .userDenied : .executionError,
                message: interrupt.isInterrupted
                    ? "Run was stopped by the user before execution began."
                    : "Run was cancelled before execution began.",
                tool: prepared.tool,
                retryable: false,
                metadata: ["cancelled": true]
            )
            if presentation.finishFeed {
                feed.finish(
                    success: false,
                    summary: ToolEnvelope.failureMessage(envelope)
                )
            }
            return envelope
        }

        var effectiveHandoff = handoffOverride ?? prepared.handoff
        if !skipAdmission,
            let replanningKind =
                prepared.kind as? any SubagentPostAdmissionResidencyPlanning
        {
            let refreshedPlan: ResidencyPlan
            do {
                refreshedPlan = try await replanningKind
                    .refreshedResidencyPlanAfterAdmission(
                        for: prepared.resolved
                    )
            } catch {
                if admissionHeld {
                    if admissionHeldSlots > 0 {
                        await admissionController.releaseLocalInPlace(
                            modelKey: admissionModelKey,
                            slots: admissionHeldSlots
                        )
                    } else {
                        await admissionController.release(
                            admissionClass,
                            modelKey: admissionModelKey
                        )
                    }
                }
                let envelope = envelope(for: error, tool: prepared.tool)
                if presentation.finishFeed {
                    feed.finish(
                        success: false,
                        summary: ToolEnvelope.failureMessage(envelope)
                    )
                }
                return envelope
            }
            if interrupt.isInterrupted || Task.isCancelled {
                if admissionHeld {
                    if admissionHeldSlots > 0 {
                        await admissionController.releaseLocalInPlace(
                            modelKey: admissionModelKey,
                            slots: admissionHeldSlots
                        )
                    } else {
                        await admissionController.release(
                            admissionClass,
                            modelKey: admissionModelKey
                        )
                    }
                    admissionHeld = false
                }
                let envelope = ToolEnvelope.failure(
                    kind: interrupt.isInterrupted
                        ? .userDenied : .executionError,
                    message: interrupt.isInterrupted
                        ? "Run was stopped by the user before execution began."
                        : "Run was cancelled before execution began.",
                    tool: prepared.tool,
                    retryable: false,
                    metadata: ["cancelled": true]
                )
                if presentation.finishFeed {
                    feed.finish(
                        success: false,
                        summary: ToolEnvelope.failureMessage(envelope)
                    )
                }
                return envelope
            }

            var currentPlan = refreshedPlan
            var refreshedClass = prepared.kind.admissionClass(
                prepared.resolved
            )
            // A localInPlace -> localExclusive upgrade releases the shared
            // slots before waiting for the writer lease. The opposite refresh
            // (exclusive -> in-place) intentionally keeps the already-held
            // stronger writer lease for this one direct run: releasing it would
            // let a later exclusive waiter jump ahead and force a second queue.
            // The refreshed kind-owned handoff below still prevents a stale
            // unload/restore, and the writer lease is released normally as soon
            // as this direct child finishes.
            if admissionHeld,
                admissionClass == .localInPlace,
                refreshedClass == .localExclusive
            {
                await admissionController.releaseLocalInPlace(
                    modelKey: admissionModelKey,
                    slots: admissionHeldSlots
                )
                admissionHeld = false
                admissionHeldSlots = 0

                let upgradedAdmission = await admissionController.admit(
                    .localExclusive,
                    modelKey: admissionModelKey,
                    onWait: { [feed] active in
                        feed.emitPhase(
                            "waiting for local GPU",
                            detail: active
                        )
                    },
                    cancellationRequested: { interrupt.isInterrupted }
                )
                switch upgradedAdmission {
                case .admitted:
                    admissionClass = .localExclusive
                    admissionHeld = true
                case .timedOut(let active):
                    let message =
                        "\(prepared.tool) is waiting on \(active) that did not finish in time. "
                        + "Retry when the running subagent completes."
                    if presentation.finishFeed {
                        feed.finish(success: false, summary: message)
                    }
                    return ToolEnvelope.failure(
                        kind: .unavailable,
                        message: message,
                        tool: prepared.tool,
                        retryable: true
                    )
                case .cancelled:
                    let message =
                        "Run stopped by the user while waiting for another subagent to finish."
                    if presentation.finishFeed {
                        feed.finish(success: false, summary: message)
                    }
                    return ToolEnvelope.failure(
                        kind: .userDenied,
                        message: message,
                        tool: prepared.tool,
                        retryable: false
                    )
                }

                // Switching from a shared in-place lease to the exclusive
                // handoff can itself wait. Revalidate both mutable authority
                // and residency one final time under the lease actually used
                // for execution.
                do {
                    try await prepared.kind.validateExecutionAuthority(
                        prepared.scope,
                        resolved: prepared.resolved
                    )
                    currentPlan = try await replanningKind
                        .refreshedResidencyPlanAfterAdmission(
                            for: prepared.resolved
                        )
                    refreshedClass = prepared.kind.admissionClass(
                        prepared.resolved
                    )
                } catch {
                    await admissionController.release(
                        admissionClass,
                        modelKey: admissionModelKey
                    )
                    admissionHeld = false
                    let envelope = envelope(for: error, tool: prepared.tool)
                    if presentation.finishFeed {
                        feed.finish(
                            success: false,
                            summary: ToolEnvelope.failureMessage(envelope)
                        )
                    }
                    return envelope
                }
                if interrupt.isInterrupted || Task.isCancelled {
                    await admissionController.release(
                        admissionClass,
                        modelKey: admissionModelKey
                    )
                    admissionHeld = false
                    let envelope = ToolEnvelope.failure(
                        kind: interrupt.isInterrupted
                            ? .userDenied : .executionError,
                        message: interrupt.isInterrupted
                            ? "Run was stopped by the user before execution began."
                            : "Run was cancelled before execution began.",
                        tool: prepared.tool,
                        retryable: false,
                        metadata: ["cancelled": true]
                    )
                    if presentation.finishFeed {
                        feed.finish(
                            success: false,
                            summary: ToolEnvelope.failureMessage(envelope)
                        )
                    }
                    return envelope
                }
            }

            if refreshedClass == .localInPlace {
                let refreshedCapacity: Int
                if let postAdmissionLocalCapacityOverride {
                    refreshedCapacity =
                        await postAdmissionLocalCapacityOverride(
                            prepared,
                            currentPlan
                        )
                } else {
                    refreshedCapacity = await localInPlaceSlotCapacity(
                        for: prepared,
                        residencyPlan: currentPlan,
                        rejectUnsafeSingleRun: true
                    )
                }

                if admissionHeldSlots > 0 {
                    admissionHeldSlots =
                        await admissionController.resizeLocalInPlace(
                            modelKey: admissionModelKey,
                            heldSlots: admissionHeldSlots,
                            requestedSlots: 1,
                            slotCapacity: refreshedCapacity
                        )
                    admissionHeld = admissionHeldSlots > 0
                }
                if refreshedCapacity == 0 || !admissionHeld {
                    if admissionHeld {
                        await admissionController.release(
                            admissionClass,
                            modelKey: admissionModelKey
                        )
                        admissionHeld = false
                    }
                    let message =
                        "\(prepared.tool) no longer fits the current local RAM-safety "
                        + "and batching limits after waiting for admission."
                    if presentation.finishFeed {
                        feed.finish(success: false, summary: message)
                    }
                    return ToolEnvelope.failure(
                        kind: .unavailable,
                        message: message,
                        tool: prepared.tool,
                        retryable: true
                    )
                }
            }

            if handoffOverride == nil, prepared.handoffIsKindOwned {
                effectiveHandoff = prepared.kind.makeHandoff()
            }
        }
        let started = Date()

        // Run under the recursion guard, wrapped by the optional handoff. Bind
        // the prepared child scope explicitly: batch children have distinct
        // tool-call ids even though one visible parent call owns the feed.
        do {
            let cacheCapture = PostRunCacheCapture()
            let result = try await ChatExecutionContext.$currentSessionId.withValue(
                prepared.scope.sessionId
            ) {
                try await ChatExecutionContext.$currentAgentId.withValue(prepared.scope.agentId) {
                    try await ChatExecutionContext.$currentEnableThinking.withValue(
                        prepared.scope.enableThinking
                    ) {
                        try await ChatExecutionContext.$currentToolCallId.withValue(
                            prepared.scope.toolCallId
                        ) {
                            try await SubagentSession.$activeKindId.withValue(
                                prepared.kind.capability.id
                            ) {
                                try await effectiveHandoff.around(
                                    scope: prepared.scope,
                                    resolved: prepared.resolved,
                                    feed: feed
                                ) {
                                    let result = try await prepared.kind.run(
                                        prepared.scope,
                                        prepared.resolved,
                                        feed: feed,
                                        interrupt: interrupt
                                    )
                                    if captureProcessCacheSnapshot,
                                        prepared.resolved.isLocal
                                    {
                                        cacheCapture.value =
                                            await ModelRuntime.batchDiagnosticsSnapshot()
                                    }
                                    return result
                                }
                            }
                        }
                    }
                }
            }
            if admissionHeld {
                if admissionHeldSlots > 0 {
                    await admissionController.releaseLocalInPlace(
                        modelKey: admissionModelKey,
                        slots: admissionHeldSlots
                    )
                } else {
                    await admissionController.release(
                        admissionClass,
                        modelKey: admissionModelKey
                    )
                }
                admissionHeld = false
            }

            // Residency telemetry: phase durations derived from the feed's own
            // event timeline (the handoff emits its phases there), plus a
            // process cache snapshot for an isolated local run. Batched
            // siblings disable this child-local field because one process-wide
            // snapshot cannot be attributed to one concurrent child;
            // SpawnBatchTool records one aggregate before/after delta instead.
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

            if presentation.finishFeed {
                feed.finish(success: true, summary: result.summary ?? "")
            }
            SubagentTelemetry.record(
                kindId: prepared.kind.capability.id,
                success: true,
                elapsed: Date().timeIntervalSince(started),
                usage: payload["usage"] as? [String: Any],
                phases: phases
            )
            return ToolEnvelope.success(tool: prepared.tool, result: payload)
        } catch {
            if admissionHeld {
                if admissionHeldSlots > 0 {
                    await admissionController.releaseLocalInPlace(
                        modelKey: admissionModelKey,
                        slots: admissionHeldSlots
                    )
                } else {
                    await admissionController.release(
                        admissionClass,
                        modelKey: admissionModelKey
                    )
                }
            }
            let env: String
            if error is CancellationError {
                env = ToolEnvelope.failure(
                    kind: interrupt.isInterrupted ? .userDenied : .executionError,
                    message:
                        interrupt.isInterrupted
                        ? "Run was stopped by the user."
                        : "Run was cancelled.",
                    tool: prepared.tool,
                    retryable: false,
                    metadata: ["cancelled": true]
                )
            } else {
                env = envelope(for: error, tool: prepared.tool)
            }
            if presentation.finishFeed {
                feed.finish(success: false, summary: ToolEnvelope.failureMessage(env))
            }
            SubagentTelemetry.record(
                kindId: prepared.kind.capability.id,
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

    /// Process-wide same-model callers share the active BatchEngine, so their
    /// aggregate width must honor the same server/agent/RAM ceiling as
    /// `spawn_batch`. This computes that ceiling for an ordinary one-child
    /// spawn; the admission actor accounts for already-reserved sibling slots.
    private static func localInPlaceSlotCapacity(
        for prepared: PreparedSubagentRun,
        residencyPlan suppliedResidencyPlan: ResidencyPlan? = nil,
        rejectUnsafeSingleRun: Bool = false
    ) async -> Int {
        let runtime = ServerRuntimeSettingsStore.snapshot()
        let engineSlots = InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: .standard,
            runtime: runtime
        )
        let maxParallel = await SpawnBatchTool.effectiveMaxParallel(
            scope: prepared.scope
        )
        let requested = max(
            1,
            min(
                maxParallel,
                runtime.concurrency.continuousBatching ? engineSlots : 1
            )
        )
        guard
            let residencyPlan =
                suppliedResidencyPlan ?? prepared.textResidencyPlan
        else {
            return 1
        }
        if requested == 1, !rejectUnsafeSingleRun { return 1 }

        let memoryFacts = await ModelRuntime.shared.subagentBatchMemoryFacts(
            for: prepared.resolved.name,
            residencyPlan: residencyPlan
        )
        let plan = SpawnBatchTool.makeLocalAdmissionPlan(
            localJobCount: requested,
            remoteJobCount: 0,
            maxParallel: maxParallel,
            engineParallelLimit: engineSlots,
            continuousBatchingEnabled: runtime.concurrency.continuousBatching,
            residencyPlan: residencyPlan,
            memoryFacts: memoryFacts,
            failClosedWhenEstimateUnknown: true
        )
        if case .admitted = plan.verdict {
            return max(1, plan.localCapacity)
        }
        guard rejectUnsafeSingleRun, requested > 1 else {
            return rejectUnsafeSingleRun ? 0 : 1
        }

        // A wider batch can be unsafe while the one already-reserved direct
        // child still fits. Re-evaluate exactly that child before refusing.
        let singleRunPlan = SpawnBatchTool.makeLocalAdmissionPlan(
            localJobCount: 1,
            remoteJobCount: 0,
            maxParallel: maxParallel,
            engineParallelLimit: engineSlots,
            continuousBatchingEnabled:
                runtime.concurrency.continuousBatching,
            residencyPlan: residencyPlan,
            memoryFacts: memoryFacts,
            failClosedWhenEstimateUnknown: true
        )
        guard case .admitted = singleRunPlan.verdict else { return 0 }
        return 1
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

    /// Canonical local identity for the admission gate. This path runs for
    /// every spawned/tool worker and therefore must remain pure: model
    /// discovery can synchronously scan every configured model root and would
    /// starve unrelated actor work (including Stop delivery) when many workers
    /// start together. A known stable id wins. An id-less fallback keeps the
    /// complete model string instead of truncating it to a basename: two
    /// installed bundles from different organizations must never share
    /// admission or a handoff.
    ///
    /// Production local Text workers carry the canonical installed id from
    /// resolution, so full and short spellings of the same bundle still group
    /// together without filesystem discovery in this pure hot path.
    static func canonicalAdmissionModelKey(_ resolved: ResolvedModel) -> String? {
        guard resolved.isLocal else { return nil }
        let identity = resolved.id ?? resolved.name
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

/// Reference box carrying the run-end cache snapshot out of the handoff
/// closure (written once inside the wrap, read after it returns — a
/// happens-before ordering, so a plain box is sufficient).
private final class PostRunCacheCapture: @unchecked Sendable {
    var value: BatchDiagnosticsSnapshot?
}
